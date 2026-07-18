//! IRC line → HTML rendering and parse helpers.
use crate::state::MemberEntry;
use crate::upstream::UpstreamHistoryMessage;
use chrono::Utc;

pub fn canonical_channel(s: &str) -> String {
    if s.starts_with('#') {
        s.to_string()
    } else {
        format!("#{s}")
    }
}

pub fn should_emit(line: &str, current_channel: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.starts_with("PING ") || line.starts_with("PONG ") {
        return false;
    }
    // Strip IRCv3 message tags (`@key=value ...`) before parsing the prefix.
    let after_tags = parse_irc_tags(line).1;
    let Some(rest) = after_tags.strip_prefix(':') else {
        // Client→server style without prefix: ignore.
        return false;
    };
    let Some(sp) = rest.find(' ') else {
        return false;
    };
    let after_prefix = &rest[sp + 1..];
    let cmd = after_prefix.split_whitespace().next().unwrap_or("");

    // Numerics (001 welcome, 353 names, …) are handled elsewhere or noise.
    if cmd.len() == 3 && cmd.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }

    // Registration / protocol control — never show in the message pane.
    match cmd {
        "CAP" | "AUTHENTICATE" | "BATCH" | "PING" | "PONG" | "ERROR" | "TAGMSG" => {
            return false;
        }
        "PRIVMSG" | "NOTICE" | "JOIN" | "PART" | "QUIT" | "TOPIC" | "KICK" | "NICK" | "MODE" => {}
        _ => return false,
    }

    // Channel-scoped messages: only emit if the target matches the
    // channel this SSE subscriber is viewing.
    if let Some(target) = extract_irc_target(after_prefix) {
        let canon_cur = canonical_channel(current_channel);
        if !target.eq_ignore_ascii_case(&canon_cur) {
            return false;
        }
    }

    // Suppress protocol / policy control NOTICEs directed at the nick
    // (POLICY RULES, DPoP, API-BEARER, …) so they don't leak into chat.
    if cmd == "NOTICE" {
        if let Some(text) = notice_trailing(after_prefix) {
            if is_control_notice(text) {
                return false;
            }
        }
    }

    true
}

/// Like `should_emit` but for the session-scoped SSE — returns the channel
/// the line belongs to (so the client can filter), or `None` for session-wide
/// lines that should not be shown as channel messages.
pub fn should_emit_any(line: &str) -> EmitInfo {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.starts_with("PING ") || line.starts_with("PONG ") {
        return EmitInfo::Skip;
    }
    let after_tags = parse_irc_tags(line).1;
    let Some(rest) = after_tags.strip_prefix(':') else {
        return EmitInfo::Skip;
    };
    let Some(sp) = rest.find(' ') else {
        return EmitInfo::Skip;
    };
    let after_prefix = &rest[sp + 1..];
    let cmd = after_prefix.split_whitespace().next().unwrap_or("");

    if cmd.len() == 3 && cmd.bytes().all(|b| b.is_ascii_digit()) {
        return EmitInfo::Skip;
    }

    match cmd {
        "CAP" | "AUTHENTICATE" | "BATCH" | "PING" | "PONG" | "ERROR" | "TAGMSG" => EmitInfo::Skip,
        "PRIVMSG" | "NOTICE" => {
            // Suppress control NOTICEs
            if cmd == "NOTICE" {
                if let Some(text) = notice_trailing(after_prefix) {
                    if is_control_notice(text) {
                        return EmitInfo::Skip;
                    }
                }
            }
            match extract_irc_target(after_prefix) {
                Some(ch) => EmitInfo::Channel(ch.to_string()),
                None => EmitInfo::Session, // NOTICE to nick, etc.
            }
        }
        "JOIN" => {
            let ch = after_prefix
                .split_whitespace()
                .nth(1)
                .unwrap_or("")
                .trim_start_matches(':');
            if ch.starts_with('#') || ch.starts_with('&') {
                EmitInfo::Channel(ch.to_string())
            } else {
                EmitInfo::Skip
            }
        }
        "PART" => {
            let ch = after_prefix.split_whitespace().nth(1).unwrap_or("");
            if ch.starts_with('#') || ch.starts_with('&') {
                EmitInfo::Channel(ch.to_string())
            } else {
                EmitInfo::Skip
            }
        }
        "QUIT" | "NICK" => EmitInfo::Session, // No specific channel
        "TOPIC" | "MODE" | "KICK" => {
            match extract_irc_target(after_prefix) {
                Some(ch) => EmitInfo::Channel(ch.to_string()),
                None => EmitInfo::Skip,
            }
        }
        _ => EmitInfo::Skip,
    }
}

pub enum EmitInfo {
    Skip,
    Session,
    Channel(String),
}

/// Parse a topic change or 332 numeric, returning (channel, topic).
/// Unlike `parse_topic_change`, does not filter by a specific channel.
pub fn parse_topic_any(line: &str) -> Option<(String, String)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let colon_idx = rest.find(" :")?;
    let before = &rest[..colon_idx];
    let text = &rest[colon_idx + 2..];
    let mut tokens = before.split_whitespace();
    let _source = tokens.next()?;
    let second = tokens.next()?;
    let channel = if second.eq_ignore_ascii_case("TOPIC") {
        tokens.next()?
    } else if second == "332" {
        let _nick = tokens.next()?;
        tokens.next()?
    } else {
        return None;
    };
    Some((channel.to_string(), text.to_string()))
}

/// Parse a channel error numeric (442/482), returning (channel, message).
/// Unlike `parse_channel_error`, does not filter by a specific channel.
pub fn parse_channel_error_any(line: &str) -> Option<(String, &'static str)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let mut tokens = rest.split_whitespace();
    let _server = tokens.next()?;
    let numeric = tokens.next()?;
    if !matches!(numeric, "442" | "482") {
        return None;
    }
    let _nick = tokens.next()?;
    let channel = tokens.next()?;
    let msg = match numeric {
        "442" => "You are not on that channel.",
        "482" => "You must be a channel operator to change the topic.",
        _ => return None,
    };
    Some((channel.to_string(), msg))
}

/// Trailing text of `NOTICE target :text`.
fn notice_trailing(after_prefix: &str) -> Option<&str> {
    let rest = after_prefix.strip_prefix("NOTICE ")?;
    let sp = rest.find(' ')?;
    let trailing = rest[sp + 1..].trim_start();
    Some(trailing.trim_start_matches(':'))
}

/// True for server control/policy NOTICEs that should not appear in chat.
fn is_control_notice(text: &str) -> bool {
    let t = text.trim();
    t.starts_with("Rules for #")
        || t.starts_with("Rules for &")
        || t.contains("rules_hash=")
        || t.contains("has no policy")
        || t.contains("no rules text")
        || t.contains("Rules text isn't available")
        || t.starts_with("Policy for #")
        || t.starts_with("Policy for &")
        || t.starts_with("Policy error")
        || t.starts_with("Version:")
        || t.starts_with("Policy ID:")
        || t.starts_with("Effective:")
        || t.starts_with("Validity:")
        || t.starts_with("Requirement:")
        || t.starts_with("Role '")
        || t.starts_with("Role ")
        || t.starts_with("DPOP_NONCE ")
        || t.starts_with("API-BEARER ")
        || t.contains("SASL authentication")
}

/// Parse `BATCH +id type [args…]` / `BATCH -id`. Returns `(id, open, batch_type)`.
/// `open` is true for `+`, false for `-`. `batch_type` is only set when opening.
pub fn parse_batch_line(line: &str) -> Option<(String, bool, Option<String>)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let after_tags = parse_irc_tags(line).1;
    let rest = after_tags.strip_prefix(':')?;
    let sp = rest.find(' ')?;
    let after_prefix = &rest[sp + 1..];
    let mut parts = after_prefix.split_whitespace();
    if parts.next()? != "BATCH" {
        return None;
    }
    let ref_tok = parts.next()?;
    let (open, id) = if let Some(id) = ref_tok.strip_prefix('+') {
        (true, id.to_string())
    } else if let Some(id) = ref_tok.strip_prefix('-') {
        (false, id.to_string())
    } else {
        return None;
    };
    let batch_type = if open {
        parts.next().map(|s| s.to_string())
    } else {
        None
    };
    Some((id, open, batch_type))
}

/// Extract `msgid` tag from an IRCv3-tagged line, if present.
pub fn line_msgid(line: &str) -> Option<String> {
    let (tags, _) = parse_irc_tags(line);
    tags.get("msgid").cloned()
}

pub fn extract_irc_target(after_prefix: &str) -> Option<&str> {
    // PRIVMSG #chan :msg  /  NOTICE #chan :msg  /  TOPIC #chan :new  /  etc.
    let cmd_end = after_prefix.find(' ')?;
    let command = &after_prefix[..cmd_end];
    match command {
        "PRIVMSG" | "NOTICE" | "TOPIC" | "MODE" | "KICK" | "INVITE" => {
            let rest = &after_prefix[cmd_end + 1..];
            let target_end = rest.find(' ').unwrap_or(rest.len());
            let target = &rest[..target_end];
            // Only filter if the target looks like a channel (starts with
            // # / & / + / !). Server-wide NOTICE * or PRIVMSG to a nick
            // should pass through unfiltered.
            if target.starts_with('#')
                || target.starts_with('&')
                || target.starts_with('+')
                || target.starts_with('!')
            {
                Some(target)
            } else {
                None
            }
        }
        _ => None,
    }
}

pub fn unescape_tag_value(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some(':') => out.push(';'),
                Some('s') => out.push(' '),
                Some('\\') => out.push('\\'),
                Some('r') => out.push('\r'),
                Some('n') => out.push('\n'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn parse_irc_tags(line: &str) -> (std::collections::HashMap<String, String>, &str) {
    let mut tags = std::collections::HashMap::new();
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(rest) = line.strip_prefix('@') else {
        return (tags, line);
    };
    let Some((tag_part, after)) = rest.split_once(' ') else {
        return (tags, line);
    };
    for item in tag_part.split(';') {
        if let Some((k, v)) = item.split_once('=') {
            tags.insert(k.to_string(), unescape_tag_value(v));
        } else if !item.is_empty() {
            tags.insert(item.to_string(), String::new());
        }
    }
    (tags, after)
}

pub fn parse_reactions_tag(value: &str) -> std::collections::HashMap<String, Vec<String>> {
    let mut map = std::collections::HashMap::new();
    for group in value.split(';') {
        let Some((emoji, nicks)) = group.split_once(':') else {
            continue;
        };
        let nicks: Vec<String> = nicks
            .split(',')
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if !nicks.is_empty() {
            map.insert(emoji.to_string(), nicks);
        }
    }
    map
}

pub fn render_reaction_chips(
    msgid: Option<&str>,
    reactions: &std::collections::HashMap<String, Vec<String>>,
) -> String {
    // No msgid → can't react. Render nothing.
    if msgid.is_none() && reactions.is_empty() {
        return String::new();
    }
    let mut chips = String::from(r#"<span class="reactions">"#);
    for (emoji, nicks) in reactions {
        let title = nicks.join(", ");
        let count = nicks.len();
        let label = if count == 1 {
            emoji.clone()
        } else {
            format!("{emoji} {count}")
        };
        let mid_attr = msgid.unwrap_or("");
        chips.push_str(&format!(
            r#"<button type="button" class="reaction-chip" title="{title}" data-emoji="{emoji}" data-msgid="{mid}" data-class:mine="window.isReacted('{mid}','{emoji}')?'':''" onclick="window.toggleReaction('{mid}','{emoji}')">{label}</button>"#,
            title = html_escape(&title),
            emoji = html_escape(emoji),
            label = html_escape(&label),
            mid = html_escape(mid_attr)
        ));
    }
    if let Some(mid) = msgid {
        chips.push_str(&format!(
            r#"<button class="react-btn" type="button" onclick="window.openReactPicker('{mid}')" title="React">+</button>"#
        ));
    }
    chips.push_str("</span>");
    chips
}

/// Returns `(target_msgid, emoji, reactor_nick, added, channel)`.
/// `added` is true for `+react`, false for `+freeq.at/unreact`.
pub fn parse_tagmsg_reaction(line: &str) -> Option<(String, String, String, bool, String)> {
    let (tags, after) = parse_irc_tags(line);
    let (emoji, added) = if let Some(e) = tags.get("+react") {
        (e.clone(), true)
    } else if let Some(e) = tags.get("+freeq.at/unreact") {
        (e.clone(), false)
    } else {
        return None;
    };
    let msgid = tags.get("+reply")?.clone();
    // `:nick!user@host TAGMSG #channel`
    let rest = after.strip_prefix(':')?;
    let mut parts = rest.split_whitespace();
    let nick = parts.next()?.split('!').next()?.to_string();
    if !parts.next()?.eq_ignore_ascii_case("TAGMSG") {
        return None;
    }
    let channel = parts.next()?.trim_start_matches(':').to_string();
    Some((msgid, emoji, nick, added, channel))
}

/// Escape a value for an IRCv3 message-tag (escaping rules for `;` space `\` CRLF).
pub fn escape_tag_value(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            ';' => out.push_str("\\:"),
            ' ' => out.push_str("\\s"),
            '\\' => out.push_str("\\\\"),
            '\r' => out.push_str("\\r"),
            '\n' => out.push_str("\\n"),
            _ => out.push(c),
        }
    }
    out
}

pub fn render_irc_line(line: &str) -> String {
    let line = line.trim_end_matches(['\r', '\n']);
    let ts = Utc::now().format("%H:%M:%S").to_string();
    let ts_html = format!(r#"<span class="ts">{ts}</span>"#);

    let (tags, rest) = parse_irc_tags(line);

    if let Some(rest) = rest.strip_prefix(':') {
        if let Some(sp) = rest.find(' ') {
            let prefix = &rest[..sp];
            let cmd_and_args = &rest[sp + 1..];
            let nick = prefix.split('!').next().unwrap_or(prefix);
            let mut parts = cmd_and_args.splitn(3, ' ');
            let cmd = parts.next().unwrap_or("");

            if matches!(cmd, "PRIVMSG" | "NOTICE") {
                let _target = parts.next().unwrap_or("");
                let text = parts.next().unwrap_or("").trim_start_matches(':');
                let cls = if cmd == "NOTICE" { "notice" } else { "msg" };
                let color = nick_color_class(nick);
                let safe_text = linkify_urls(&html_escape(text));
                let msgid = tags.get("msgid").cloned();
                let msgid_attr = msgid
                    .as_deref()
                    .map(|m| format!(r#" data-msgid="{m}""#))
                    .unwrap_or_default();
                let reactions = tags
                    .get("+freeq.at/reactions")
                    .map(|v| parse_reactions_tag(v))
                    .unwrap_or_default();
                let reaction_html = render_reaction_chips(msgid.as_deref(), &reactions);
                return format!(
                    r#"<div class="{cls}"{msgid_attr}>{ts_html}<span class="body"><span class="nick {color}">{nick}</span> {safe_text}{reaction_html}</span></div>"#
                );
            }
            if matches!(cmd, "JOIN" | "PART" | "QUIT") {
                let cls = match cmd {
                    "JOIN" => "join",
                    _ => "part",
                };
                return format!(
                    r#"<div class="{cls}">{ts_html}<span class="body">— {nick} {cmd_lower}</span></div>"#,
                    cmd_lower = cmd.to_lowercase(),
                );
            }
            let safe = html_escape(line);
            return format!(
                r#"<div class="notice">{ts_html}<span class="body">{safe}</span></div>"#
            );
        }
    }
    let safe = html_escape(line);
    format!(r#"<div class="notice">{ts_html}<span class="body">{safe}</span></div>"#)
}

pub enum MemberChange {
    Join {
        channel: String,
        nick: String,
    },
    Part {
        channel: String,
        nick: String,
    },
    Quit {
        nick: String,
    },
    /// `(mode_char, adding, target_nick)` — only `o`/`h`/`v` affect display.
    Mode {
        channel: String,
        ops: Vec<(char, bool, String)>,
    },
}

pub fn parse_member_change(line: &str) -> Option<MemberChange> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let sp = rest.find(' ')?;
    let prefix = &rest[..sp];
    let cmd_and_args = &rest[sp + 1..];
    let nick = prefix.split('!').next().unwrap_or(prefix).to_string();
    let mut parts = cmd_and_args.split(' ');
    let cmd = parts.next()?;
    match cmd {
        "JOIN" => {
            // `JOIN #chan` or extended `JOIN #chan account :realname`.
            // Some servers colon the channel (`JOIN :#chan`); trim it.
            let channel = parts.next()?.trim_start_matches(':').to_string();
            Some(MemberChange::Join { channel, nick })
        }
        "PART" => {
            let channel = parts.next()?.trim_start_matches(':').to_string();
            Some(MemberChange::Part { channel, nick })
        }
        "QUIT" => Some(MemberChange::Quit { nick }),
        "MODE" => {
            let channel = parts.next()?.trim_start_matches(':').to_string();
            // Only channel modes affect the nick list; a user-mode change
            // (target is a nick, not a channel) is not a member change.
            if !channel.starts_with('#') && !channel.starts_with('&') {
                return None;
            }
            let modestring = parts.next()?;
            let mut ops = Vec::new();
            let mut adding = true;
            for c in modestring.chars() {
                match c {
                    '+' => adding = true,
                    '-' => adding = false,
                    // Member modes consume one target arg each.
                    'o' | 'h' | 'v' => {
                        if let Some(target) = parts.next() {
                            ops.push((c, adding, target.to_string()));
                        }
                    }
                    // Channel modes (n, t, s, i, k, l, …) take no member
                    // target here; don't consume an arg.
                    _ => {}
                }
            }
            Some(MemberChange::Mode { channel, ops })
        }
        _ => None,
    }
}

pub fn parse_topic_change(line: &str, current_channel: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    // Locate the trailing `:` parameter and the tokens before it.
    let colon_idx = rest.find(" :")?;
    let before = &rest[..colon_idx];
    let text = &rest[colon_idx + 2..];
    let mut tokens = before.split_whitespace();
    let _source = tokens.next()?;
    let second = tokens.next()?;
    let channel = if second.eq_ignore_ascii_case("TOPIC") {
        tokens.next()?
    } else if second == "332" {
        let _nick = tokens.next()?;
        tokens.next()?
    } else {
        return None;
    };
    if channel.eq_ignore_ascii_case(current_channel) {
        Some(text.to_string())
    } else {
        None
    }
}

pub fn parse_channel_error(line: &str, current_channel: &str) -> Option<&'static str> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let mut tokens = rest.split_whitespace();
    let _server = tokens.next()?;
    let numeric = tokens.next()?;
    if !matches!(numeric, "442" | "482") {
        return None;
    }
    let _nick = tokens.next()?;
    let channel = tokens.next()?;
    if !channel.eq_ignore_ascii_case(current_channel) {
        return None;
    }
    match numeric {
        "442" => Some("You are not on that channel."),
        "482" => Some("You must be a channel operator to change the topic."),
        _ => None,
    }
}

pub fn parse_whois_line(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let mut tokens = rest.split_whitespace();
    let _server = tokens.next()?;
    let numeric = tokens.next()?;
    let _me = tokens.next()?;
    let nick = tokens.next()?;
    let trailing = line.splitn(2, " :").nth(1).unwrap_or("");
    match numeric {
        "311" => {
            // RPL_WHOISUSER: <nick> <user> <host> * :<realname>
            let user = tokens.next()?;
            let host = tokens.next()?;
            Some(format!("{nick} is {user}@{host} ({trailing})"))
        }
        "312" => {
            // RPL_WHOISSERVER: <nick> <server> :<server info>
            let server = tokens.next()?;
            Some(format!("{nick} using {server} ({trailing})"))
        }
        "319" => {
            // RPL_WHOISCHANNELS: <nick> :<channels>
            Some(format!("{nick} on {trailing}"))
        }
        "330" => {
            // RPL_WHOISACCOUNT: <nick> <account> :is logged in as
            let account = tokens.next()?;
            Some(format!("{nick} is logged in as {account}"))
        }
        "318" => Some(format!("End of WHOIS for {nick}")),
        "401" => Some(format!("{nick}: No such nick/channel")),
        _ => None,
    }
}

pub fn render_member_list(members: &std::collections::HashMap<String, MemberEntry>) -> String {
    if members.is_empty() {
        return r#"<div class="member empty">—</div>"#.to_string();
    }
    let mut sorted: Vec<&MemberEntry> = members.values().collect();
    sorted.sort_by(|a, b| {
        let rank = |m: &MemberEntry| match (m.op, m.halfop, m.voiced) {
            (true, _, _) => 0,
            (_, true, _) => 1,
            (_, _, true) => 2,
            _ => 3,
        };
        rank(a)
            .cmp(&rank(b))
            .then_with(|| a.nick.to_lowercase().cmp(&b.nick.to_lowercase()))
    });
    sorted
        .iter()
        .map(|m| {
            let color = nick_color_class(&m.nick);
            let safe_nick = html_escape(&m.nick);
            let pfx = if m.op {
                r#"<span class="pfx op">@</span>"#
            } else if m.halfop {
                r#"<span class="pfx halfop">%</span>"#
            } else if m.voiced {
                r#"<span class="pfx voice">+</span>"#
            } else {
                ""
            };
            format!(
                r#"<div class="member">{pfx}<span class="nick {color}">{safe_nick}</span></div>"#
            )
        })
        .collect::<Vec<_>>()
        .join("")
}

pub fn is_353(line: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(rest) = line.strip_prefix(':') else {
        return false;
    };
    let Some(sp) = rest.find(' ') else {
        return false;
    };
    rest[sp + 1..].starts_with("353 ")
}

/// Extract the channel from a 353 (RPL_NAMREPLY) line.
/// Format: `:server 353 nick = #channel :@nick1 @nick2`
pub fn parse_353_channel(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    // server 353 nick = #channel :names
    let mut parts = rest.split_whitespace();
    let _server = parts.next()?;
    let cmd = parts.next()?;
    if cmd != "353" {
        return None;
    }
    let _nick = parts.next()?;
    let _visibility = parts.next()?; // =, *, or @
    let channel = parts.next()?;
    Some(channel.to_string())
}

pub fn parse_333_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let (_prefix, rest) = rest.split_once(' ')?;
    // rest = "333 nick #chan did:plc:xxx timestamp"
    let parts: Vec<&str> = rest.splitn(4, ' ').collect();
    // parts = ["333", "nick", "#chan", "did:plc:xxx timestamp"]
    if parts.len() < 4 || parts[0] != "333" {
        return None;
    }
    let rest2 = parts[3];
    let did = rest2.split(' ').next()?;
    if did.starts_with("did:plc:") {
        Some(did.to_string())
    } else {
        None
    }
}

pub fn parse_auth_notice_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    if !line.contains("authenticated as did:plc:") {
        return None;
    }
    let start = line.find("did:plc:")?;
    let rest = &line[start..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ')')
        .unwrap_or(rest.len());
    Some(rest[..end].to_string())
}

pub fn parse_account_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let (_prefix, rest) = line.strip_prefix(':')?.split_once(' ')?;
    let (cmd, did) = rest.split_once(' ')?;
    if cmd != "ACCOUNT" {
        return None;
    }
    if did == "*" {
        return None;
    } // logged out
    Some(did.to_string())
}

/// Normalize a channel name for use as a map key (case-insensitive IRC).
pub fn channel_key(channel: &str) -> String {
    channel.to_lowercase()
}

/// Normalize a nick for use as a map key (case-insensitive IRC).
pub fn nick_key(nick: &str) -> String {
    nick.to_lowercase()
}

pub fn parse_353_members(line: &str) -> Vec<MemberEntry> {
    let line = line.trim_end_matches(['\r', '\n']);
    let names = match line.rfind(" :") {
        Some(i) => &line[i + 2..],
        None => return Vec::new(),
    };
    names
        .split(' ')
        .filter(|t| !t.is_empty())
        .map(|token| {
            let pfx_len = token
                .chars()
                .take_while(|c| matches!(c, '@' | '%' | '+' | '~' | '&'))
                .count();
            let nick = &token[pfx_len..];
            let pfx = &token[..pfx_len];
            MemberEntry {
                nick: nick.to_string(),
                op: pfx.contains('@') || pfx.contains('~') || pfx.contains('&'),
                halfop: pfx.contains('%'),
                voiced: pfx.contains('+'),
            }
        })
        .collect()
}

/// True for RPL_ENDOFNAMES (366).
pub fn is_366(line: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(rest) = line.strip_prefix(':') else {
        return false;
    };
    let Some(sp) = rest.find(' ') else {
        return false;
    };
    rest[sp + 1..].starts_with("366 ")
}

pub fn render_history_row(msg: &UpstreamHistoryMessage) -> String {
    let nick = msg.sender.split('!').next().unwrap_or(&msg.sender);
    let color = nick_color_class(nick);
    let ts = chrono::DateTime::<Utc>::from_timestamp(msg.timestamp, 0)
        .map(|dt| dt.format("%H:%M:%S").to_string())
        .unwrap_or_else(|| "--:--:--".to_string());
    let safe_text = html_escape(&msg.text);
    let msgid_attr = msg
        .msgid
        .as_deref()
        .map(|m| format!(r#" data-msgid="{m}""#))
        .unwrap_or_default();
    let reactions = msg.reactions();
    let reaction_html = render_reaction_chips(msg.msgid.as_deref(), &reactions);
    format!(
        r#"<div class="msg"{msgid_attr}><span class="ts">{ts}</span><span class="body"><span class="nick {color}">{nick}</span> {safe_text}{reaction_html}</span></div>"#
    )
}

pub fn nick_color_class(nick: &str) -> &'static str {
    let mut h: u64 = 5381;
    for b in nick.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    const CLASSES: &[&str] = &["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"];
    CLASSES[(h % 8) as usize]
}

pub fn html_escape(s: &str) -> String {
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

pub fn sanitize_nick(handle: &str) -> String {
    let mut out = String::with_capacity(handle.len().min(20));
    for c in handle.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
            out.push(c);
        }
        if out.len() >= 20 {
            break;
        }
    }
    if out.is_empty() {
        return String::new();
    }
    // Must start with a letter.
    if !out.starts_with(|c: char| c.is_ascii_alphabetic()) {
        out.insert(0, 'u');
        out.truncate(20);
    }
    out
}

pub fn linkify_urls(escaped: &str) -> String {
    // Text is already HTML-escaped. Find https://... and wrap in <a>.
    let mut out = String::with_capacity(escaped.len() + 64);
    let mut rest = escaped;
    while let Some(pos) = rest.find("https://") {
        out.push_str(&rest[..pos]);
        let url_end = rest[pos..]
            .find(|c: char| c.is_whitespace() || c == '<')
            .unwrap_or(rest.len() - pos);
        let url = &rest[pos..pos + url_end];
        out.push_str(&format!(
            r#"<a href="{url}" target="_blank" rel="noopener">{url}</a>"#
        ));
        rest = &rest[pos + url_end..];
    }
    out.push_str(rest);
    out
}
