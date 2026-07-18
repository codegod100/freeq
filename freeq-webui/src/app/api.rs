use topcoat::Result;
use topcoat::context::Cx;
use topcoat::router::{Html, Json, path_param, route};

use crate::app::state;
use crate::irc_render::{canonical_channel, channel_key, render_history_row, render_member_list};
use crate::session_util::ensure_session_id;
use crate::upstream::{UpstreamChannel, fetch_channels, fetch_history, spawn_upstream_if_needed};

#[path_param]
struct Channel(str);

#[path_param]
struct Hash(str);

#[route(GET "/api/channels")]
async fn api_channels(cx: &Cx) -> Result<Json<Vec<UpstreamChannel>>> {
    let app = state(cx);
    let channels = fetch_channels(&app).await.unwrap_or_default();
    Ok(Json(channels))
}

/// JSON payload for client-side channel switching.
#[derive(serde::Serialize)]
struct ChannelData {
    messages_html: String,
    members_html: String,
    topic: String,
}

/// Returns initial data for a channel (history, members, topic) as JSON.
/// Used by the client when switching channels without a full page reload.
#[route(GET "/api/channel/{channel}")]
async fn api_channel(cx: &Cx) -> Result<Json<ChannelData>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), &channel);

    // Fetch 25 messages from upstream REST API.
    let history = fetch_history(&app, &channel, 25).await.unwrap_or_default();

    // Seed dedup so JOIN chathistory replay over SSE is not appended again.
    session.note_seen_msgids(
        history
            .iter()
            .filter_map(|m| m.msgid.clone())
            .filter(|id| !id.is_empty()),
    );

    let messages_html = history.iter().map(render_history_row).collect::<String>();

    // Read cached members.
    let ch_key = channel_key(&channel);
    let members_html = {
        let members = session.channel_members.lock();
        members
            .get(&ch_key)
            .map(render_member_list)
            .unwrap_or_else(|| r#"<div class="member empty">—</div>"#.to_string())
    };

    // Request fresh NAMES so the roster updates.
    let tx = session.irc_tx.lock().clone();
    let _ = tx.try_send(format!("NAMES {channel}\r\n"));

    // Fetch topic from channels list.
    let channels = fetch_channels(&app).await.unwrap_or_default();
    let topic = channels
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&channel))
        .map(|c| c.topic.clone())
        .unwrap_or_default();

    Ok(Json(ChannelData {
        messages_html,
        members_html,
        topic,
    }))
}

/// Returns rendered sidebar HTML for client-side refresh after join/part.
#[derive(serde::Serialize)]
struct SidebarData {
    my_channels_html: String,
    all_channels_html: String,
}

#[route(GET "/api/sidebar/{channel}")]
async fn api_sidebar(cx: &Cx) -> Result<Json<SidebarData>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    let channels = fetch_channels(&app).await.unwrap_or_default();
    let joined: Vec<String> = session.joined.lock().iter().cloned().collect();

    let (my_channels, all_channels): (Vec<&UpstreamChannel>, Vec<&UpstreamChannel>) =
        channels
            .iter()
            .partition(|ch| {
                joined.iter().any(|j| j.eq_ignore_ascii_case(&ch.name))
                    || ch.name.eq_ignore_ascii_case(&channel)
            });

    let render_link = |ch: &UpstreamChannel, active: &str| -> String {
        let bare = ch.name.trim_start_matches('#');
        let is_active = ch.name.eq_ignore_ascii_case(active);
        let cls = if is_active {
            "block rounded px-2 py-1 bg-[#7ab7ff] text-[#0e1116] font-medium"
        } else {
            "block rounded px-2 py-1 text-zinc-300 hover:bg-[#151a22]"
        };
        let members = ch.members;
        let name = ch.name.clone();
        format!(
            r#"<li class="flex items-center gap-1"><a href="/chat/{bare}" class="{cls}" style="flex:1;min-width:0;overflow-wrap:anywhere" onclick="switchChannel('{bare}');return false">{name}</a><button type="button" class="rounded bg-[#1a1f28] px-1.5 py-0.5 text-[0.65rem] text-zinc-400 hover:text-white" title="Channel policy" onclick="event.stopPropagation();showPolicy('{bare}')">{members}</button></li>"#
        )
    };

    let my_channels_html = my_channels
        .iter()
        .map(|ch| render_link(ch, &channel))
        .collect::<String>();
    let all_channels_html = all_channels
        .iter()
        .map(|ch| render_link(ch, &channel))
        .collect::<String>();

    Ok(Json(SidebarData {
        my_channels_html,
        all_channels_html,
    }))
}

#[route(GET "/api/policy/{channel}")]
async fn api_policy(cx: &Cx) -> Result<Html<String>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);

    // Fetch both RULES (human text) and INFO (version / requirements / roles)
    // over IRC — never raw JSON.
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), &channel);

    let rules_lines = fetch_policy_notices(&session, &channel, "RULES").await;
    let info_lines = fetch_policy_notices(&session, &channel, "INFO").await;

    let open_join = rules_lines.is_empty()
        && info_lines
            .iter()
            .any(|l| l.contains("has no policy") || l.contains("open join"));

    if open_join || (rules_lines.is_empty() && info_lines.is_empty()) {
        return Ok(Html(no_policy_html()));
    }

    Ok(Html(render_policy_dialog(&channel, &rules_lines, &info_lines)))
}

// ─── Parsing ─────────────────────────────────────────────────────────────────

struct RulesSection {
    text: String,
    rules_hash: Option<String>,
}

struct InfoSection {
    version: Option<String>,
    policy_id: Option<String>,
    effective: Option<String>,
    validity: Option<String>,
    requirement: Option<String>,
    roles: Vec<(String, String)>, // (role name, requirement description)
}

fn parse_rules_section(lines: &[String]) -> RulesSection {
    let mut rules_hash = None;
    let mut body = Vec::new();
    for line in lines {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if t.starts_with("Rules for ") {
            if let Some(start) = t.find("rules_hash=") {
                let h = &t[start + "rules_hash=".len()..];
                let h = h.trim_end_matches(|c: char| c == ')' || c == ':');
                if !h.is_empty() {
                    rules_hash = Some(h.to_string());
                }
            }
            continue;
        }
        if t.contains("rules text isn't available")
            || t.contains("Rules text isn't available")
            || t.starts_with("Policy error")
            || t.contains("has no policy")
        {
            continue;
        }
        body.push(t);
    }
    RulesSection {
        text: body.join("\n"),
        rules_hash,
    }
}

fn parse_info_section(lines: &[String]) -> InfoSection {
    let mut info = InfoSection {
        version: None,
        policy_id: None,
        effective: None,
        validity: None,
        requirement: None,
        roles: Vec::new(),
    };
    for line in lines {
        let t = line.trim();
        if t.is_empty() || t.starts_with("Policy for ") {
            continue;
        }
        if t.contains("has no policy") || t.starts_with("Policy error") {
            continue;
        }
        // "  Version: 1" / "Version: 1"
        let t = t.trim_start();
        if let Some(v) = t.strip_prefix("Version:") {
            info.version = Some(v.trim().to_string());
        } else if let Some(v) = t.strip_prefix("Policy ID:") {
            info.policy_id = Some(v.trim().to_string());
        } else if let Some(v) = t.strip_prefix("Effective:") {
            info.effective = Some(v.trim().to_string());
        } else if let Some(v) = t.strip_prefix("Validity:") {
            // JoinTime / Continuous — make human-friendly
            let raw = v.trim().to_string();
            info.validity = Some(match raw.as_str() {
                "JoinTime" => "Checked at join".into(),
                "Continuous" => "Checked continuously".into(),
                other => other.to_string(),
            });
        } else if let Some(v) = t.strip_prefix("Requirement:") {
            info.requirement = Some(humanize_requirement(v.trim()));
        } else if let Some(rest) = t.strip_prefix("Role '") {
            // Role 'op': ACCEPT(abc...) + PRESENT(...)
            if let Some((role, req)) = rest.split_once("':") {
                info.roles
                    .push((role.trim().to_string(), humanize_requirement(req.trim())));
            }
        } else if let Some(rest) = t.strip_prefix("Role ") {
            // fallback Role op: ...
            if let Some((role, req)) = rest.split_once(':') {
                let role = role.trim().trim_matches('\'').to_string();
                info.roles
                    .push((role, humanize_requirement(req.trim())));
            }
        }
    }
    info
}

/// Turn DSL dumps like `ACCEPT(0b5752faf791...)` / `ALL(ACCEPT(...), PRESENT(github_membership, issuer=…))`
/// into short readable labels.
fn humanize_requirement(raw: &str) -> String {
    let s = raw.trim();
    if s.is_empty() {
        return "—".into();
    }
    // Simple token replacements for common forms.
    let mut out = s.to_string();
    // ACCEPT(hash...) → Accept channel rules
    if let Some(inner) = out.strip_prefix("ACCEPT(") {
        let hash = inner.trim_end_matches(')');
        let short = if hash.len() > 10 { &hash[..10] } else { hash };
        return format!("Accept channel rules ({short}…)");
    }
    if out.starts_with("PRESENT(") {
        // PRESENT(github_membership, issuer=did:…)
        let inner = out
            .trim_start_matches("PRESENT(")
            .trim_end_matches(')');
        let cred = inner.split(',').next().unwrap_or(inner).trim();
        let label = match cred {
            "github_membership" => "GitHub org member",
            "github_repo" => "GitHub repo collaborator",
            "bluesky_follower" => "Bluesky follower",
            "channel_moderator" => "Moderator appointment",
            other => other,
        };
        return format!("Present credential: {label}");
    }
    if out.starts_with("PROVE(") {
        let inner = out.trim_start_matches("PROVE(").trim_end_matches(')');
        return format!("Prove: {inner}");
    }
    if out.starts_with("ALL(") {
        // Leave structure but soften
        out = out.replacen("ALL(", "All of: ", 1);
        out = out.trim_end_matches(')').to_string();
        // Recursively soften nested? keep simple for now
        return out.replace("ACCEPT(", "accept rules (").replace("PRESENT(", "credential (");
    }
    if out.starts_with("ANY(") {
        out = out.replacen("ANY(", "Any of: ", 1);
        return out.trim_end_matches(')').to_string();
    }
    out
}

// ─── Rendering ───────────────────────────────────────────────────────────────

fn render_policy_dialog(channel: &str, rules_lines: &[String], info_lines: &[String]) -> String {
    let rules = parse_rules_section(rules_lines);
    let info = parse_info_section(info_lines);
    let _ = channel;

    let mut sections = String::new();

    // Rules text
    sections.push_str(r#"<section class="space-y-1.5">"#);
    sections.push_str(
        r#"<h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">Rules</h3>"#,
    );
    if rules.text.is_empty() {
        sections.push_str(
            r#"<p class="text-sm text-zinc-500">No rules text is stored for this policy.</p>"#,
        );
    } else {
        sections.push_str(&format!(
            r#"<p class="text-sm text-zinc-200 whitespace-pre-wrap leading-relaxed">{}</p>"#,
            html_escape_plain(&rules.text)
        ));
    }
    if let Some(h) = &rules.rules_hash {
        let short = if h.len() > 12 { &h[..12] } else { h.as_str() };
        sections.push_str(&format!(
            r#"<p class="text-[10px] font-mono text-zinc-600" title="{}">hash · {}…</p>"#,
            html_escape_plain(h),
            html_escape_plain(short)
        ));
    }
    sections.push_str("</section>");

    // Join requirement
    if info.requirement.is_some()
        || info.version.is_some()
        || info.policy_id.is_some()
        || info.effective.is_some()
        || info.validity.is_some()
    {
        sections.push_str(r#"<section class="space-y-2 pt-3 border-t border-[#232932]">"#);
        sections.push_str(
            r#"<h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">Policy</h3>"#,
        );
        sections.push_str(r#"<dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-xs">"#);
        if let Some(v) = &info.version {
            sections.push_str(&kv_row("Version", v));
        }
        if let Some(v) = &info.validity {
            sections.push_str(&kv_row("Validity", v));
        }
        if let Some(v) = &info.effective {
            // Trim long RFC3339 timestamps for display
            let display = if v.len() > 19 { &v[..19] } else { v.as_str() };
            let display = display.replace('T', " ");
            sections.push_str(&kv_row("Effective", &display));
        }
        if let Some(v) = &info.requirement {
            sections.push_str(&kv_row("To join", v));
        }
        if let Some(v) = &info.policy_id {
            let short = if v.len() > 16 { &v[..16] } else { v.as_str() };
            sections.push_str(&format!(
                r#"<dt class="text-zinc-500">Policy ID</dt><dd class="font-mono text-zinc-400 break-all" title="{}">{}…</dd>"#,
                html_escape_plain(v),
                html_escape_plain(short)
            ));
        }
        sections.push_str("</dl></section>");
    }

    // Roles
    if !info.roles.is_empty() {
        sections.push_str(r#"<section class="space-y-2 pt-3 border-t border-[#232932]">"#);
        sections.push_str(
            r#"<h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">Roles</h3>"#,
        );
        sections.push_str(r#"<ul class="space-y-1.5">"#);
        for (role, req) in &info.roles {
            let mode = match role.to_ascii_lowercase().as_str() {
                "op" | "admin" | "owner" => "+o",
                "moderator" | "halfop" => "+h",
                "voice" => "+v",
                _ => "",
            };
            let mode_badge = if mode.is_empty() {
                String::new()
            } else {
                format!(
                    r#"<span class="text-[10px] text-yellow-400/80 font-mono ml-1">{}</span>"#,
                    mode
                )
            };
            sections.push_str(&format!(
                r#"<li class="rounded-lg border border-[#232932] bg-[#0e1116] px-2.5 py-2">
                    <div class="flex items-center gap-1.5 text-xs">
                      <span class="text-yellow-400">⚡</span>
                      <span class="font-medium text-zinc-200">{}</span>
                      {mode_badge}
                    </div>
                    <p class="mt-0.5 text-[11px] text-zinc-500 pl-5">{}</p>
                  </li>"#,
                html_escape_plain(role),
                html_escape_plain(req),
            ));
        }
        sections.push_str("</ul></section>");
    }

    format!(r#"<div class="space-y-1">{sections}</div>"#)
}

fn kv_row(label: &str, value: &str) -> String {
    format!(
        r#"<dt class="text-zinc-500">{}</dt><dd class="text-zinc-200">{}</dd>"#,
        html_escape_plain(label),
        html_escape_plain(value)
    )
}

/// Send `POLICY <channel> {RULES|INFO}` and collect nick-directed NOTICE replies.
async fn fetch_policy_notices(
    session: &crate::state::SessionHandle,
    channel: &str,
    subcommand: &str,
) -> Vec<String> {
    use tokio::time::{timeout, timeout_at, Duration, Instant};

    let mut rx = session.lines_tx.subscribe();
    let tx = session.irc_tx.lock().clone();
    if tx
        .try_send(format!("POLICY {channel} {subcommand}\r\n"))
        .is_err()
    {
        return Vec::new();
    }

    let mut out: Vec<String> = Vec::new();
    let overall = Duration::from_secs(3);

    let _ = timeout(overall, async {
        loop {
            let gap = if out.is_empty() {
                Duration::from_millis(1500)
            } else {
                Duration::from_millis(500)
            };
            match timeout_at(Instant::now() + gap, rx.recv()).await {
                Ok(Ok(line)) => {
                    if let Some(text) = parse_policy_notice(&line) {
                        // Terminal "no policy" — keep the marker line so caller can detect it.
                        if text.contains("has no policy") || text.contains("Policy error") {
                            out.push(text);
                            return;
                        }
                        // Ignore unrelated control notices that might sneak in.
                        if text.starts_with("DPOP_NONCE ") || text.starts_with("API-BEARER ") {
                            continue;
                        }
                        out.push(text);
                    }
                }
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => return,
                Err(_) => return,
            }
        }
    })
    .await;

    out
}

/// Parse a user-directed IRC NOTICE trailing text.
fn parse_policy_notice(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let sp = rest.find(' ')?;
    let after_cmd = &rest[sp + 1..];
    if !after_cmd.starts_with("NOTICE ") {
        return None;
    }
    let rest = &after_cmd["NOTICE ".len()..];
    let target_end = rest.find(' ')?;
    let target = &rest[..target_end];
    if target.starts_with('#') || target.starts_with('&') {
        return None;
    }
    let trailing = rest.splitn(2, " :").nth(1)?;
    Some(trailing.to_string())
}

#[route(GET "/api/policy/{channel}/rules")]
async fn api_policy_rules(cx: &Cx) -> Result<String> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let url = app
        .upstream
        .base
        .join(&format!(
            "api/v1/policy/{}/history",
            urlencoding_channel(&channel)
        ))
        .unwrap();
    match app.http.get(url).send().await {
        Ok(r) => {
            let ct = r
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let text = r.text().await.unwrap_or_default();
            if ct.contains("text/html") || text.trim_start().starts_with("<!DOCTYPE")
                || text.trim_start().starts_with("<html")
            {
                return Ok("# No channel policy rules\n\nThis channel has no published rules.".to_string());
            }
            Ok(text)
        }
        Err(e) => Ok(format!("upstream error: {e}")),
    }
}

#[route(GET "/api/rules/{hash}")]
async fn api_rule(cx: &Cx) -> Result<String> {
    let hash = path_param::<Hash>(cx);
    let app = state(cx);
    let url = app
        .upstream
        .base
        .join(&format!("api/v1/authority/{hash}"))
        .unwrap();
    match app.http.get(url).send().await {
        Ok(r) => {
            let ct = r
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let text = r.text().await.unwrap_or_default();
            if ct.contains("text/html") || text.trim_start().starts_with("<!DOCTYPE")
                || text.trim_start().starts_with("<html")
            {
                return Ok("# Rule not found\n\nThe requested rule could not be found.".to_string());
            }
            Ok(text)
        }
        Err(e) => Ok(format!("upstream error: {e}")),
    }
}

fn urlencoding_channel(channel: &str) -> String {
    // REST path uses channel without #, percent-encoded if needed.
    let bare = channel.trim_start_matches('#');
    bare.replace('/', "%2F")
}

/// Open-join / no policy fallback.
fn no_policy_html() -> String {
    r#"<div class="space-y-2 text-sm">
        <p class="text-zinc-200">Open channel — no policy.</p>
        <p class="text-xs text-zinc-500">Anyone can join and participate freely.</p>
    </div>"#
        .to_string()
}

fn html_escape_plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}
