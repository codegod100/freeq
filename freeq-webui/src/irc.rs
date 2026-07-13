//! IRC line parsing and rendering helpers used by the web UI.

use std::collections::HashMap;

use chrono::Utc;

use crate::helpers::{canonical_channel, html_escape, linkify_urls, nick_color_class};
use crate::state::MemberEntry;
use crate::upstream::UpstreamHistoryMessage;

/// Parse IRCv3 message tags from the leading `@key=value;...` block.
/// Returns the tag map and the remainder of the line (after the leading space).
pub fn parse_irc_tags(line: &str) -> (HashMap<String, String>, &str) {
    let mut tags = HashMap::new();
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

/// Parse `+freeq.at/reactions` tag value into emoji -> nicker map.
/// Format: `emoji1:nick1,nick2;emoji2:nick3`.
pub fn parse_reactions_tag(value: &str) -> HashMap<String, Vec<String>> {
    let mut map = HashMap::new();
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

/// Render reaction chips for a message. `msgid` may be empty for rows that
/// don't support reactions (fallback rendering).
pub fn render_reaction_chips(
    msgid: Option<&str>,
    reactions: &HashMap<String, Vec<String>>,
) -> String {
    if msgid.is_none() && reactions.is_empty() {
        return String::new();
    }
    let mid_attr = msgid.unwrap_or("");
    let mut chips = String::from(r#"<span class="reactions">"#);
    for (emoji, nicks) in reactions {
        let title = nicks.join(", ");
        let count = nicks.len();
        let label = if count == 1 {
            emoji.clone()
        } else {
            format!("{emoji} {count}")
        };
        chips.push_str(&format!(
            r#"<button type="button" class="reaction-chip" title="{title}" data-emoji="{emoji}" data-msgid="{mid}" onclick="window.toggleReaction('{mid}','{emoji}')">{label}</button>"#,
            title = html_escape(&title),
            emoji = html_escape(emoji),
            label = html_escape(&label),
            mid = html_escape(mid_attr)
        ));
    }
    if let Some(mid) = msgid {
        chips.push_str(&format!(
            r#"<button class="react-btn" type="button" onclick="window.openReactPicker('{mid}')" title="React">+</button>"#,
            mid = mid_attr
        ));
    }
    chips.push_str("</span>");
    chips
}

pub fn extract_irc_target(after_prefix: &str) -> Option<&str> {
    let cmd_end = after_prefix.find(' ')?;
    let command = &after_prefix[..cmd_end];
    match command {
        "PRIVMSG" | "NOTICE" | "TOPIC" | "MODE" | "KICK" | "INVITE" => {
            let rest = &after_prefix[cmd_end + 1..];
            let target_end = rest.find(' ').unwrap_or(rest.len());
            let target = &rest[..target_end];
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

pub fn should_emit(line: &str, current_channel: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.starts_with("PING ") || line.starts_with("PONG ") {
        return false;
    }
    let after_tags = parse_irc_tags(line).1;
    let Some(rest) = after_tags.strip_prefix(':') else {
        return true;
    };
    let Some(sp) = rest.find(' ') else {
        return true;
    };
    let after_prefix = &rest[sp + 1..];
    let bytes = after_prefix.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_digit()
        && bytes[1].is_ascii_digit()
        && bytes[2].is_ascii_digit()
    {
        return false;
    }
    if let Some(target) = extract_irc_target(after_prefix) {
        let canon_cur = canonical_channel(current_channel);
        if !target.eq_ignore_ascii_case(&canon_cur) {
            return false;
        }
    }
    true
}

/// Parse a 353 (RPL_NAMREPLY) line. Returns `(channel, entries)`.
pub fn parse_353_members(line: &str) -> Option<(String, Vec<MemberEntry>)> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let rest = rest.splitn(2, ' ').nth(1)?;
    let mut parts = rest.splitn(5, ' ');
    if parts.next()? != "353" {
        return None;
    }
    parts.next()?; // <me>
    parts.next()?; // <visibility>
    let channel = parts.next()?.trim_start_matches(':').to_string();
    let names_part = parts.next()?.trim_start_matches(':');
    let entries = names_part
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
                nick: nick.to_ascii_lowercase(),
                op: pfx.contains('@') || pfx.contains('~') || pfx.contains('&'),
                halfop: pfx.contains('%'),
                voiced: pfx.contains('+'),
            }
        })
        .collect();
    Some((channel, entries))
}

/// Render the member map as an HTML list.
pub fn render_member_list(members: &HashMap<String, MemberEntry>) -> String {
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

/// A membership-affecting IRC event parsed from a line.
pub enum MemberChange {
    Join { channel: String, nick: String },
    Part { channel: String, nick: String },
    Quit { nick: String },
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
                    'o' | 'h' | 'v' => {
                        if let Some(target) = parts.next() {
                            ops.push((c, adding, target.to_string()));
                        }
                    }
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
            let user = tokens.next()?;
            let host = tokens.next()?;
            Some(format!("{nick} is {user}@{host} ({trailing})"))
        }
        "312" => {
            let server = tokens.next()?;
            Some(format!("{nick} using {server} ({trailing})"))
        }
        "319" => Some(format!("{nick} on {trailing}")),
        "330" => {
            let account = tokens.next()?;
            Some(format!("{nick} is logged in as {account}"))
        }
        "318" => Some(format!("End of WHOIS for {nick}")),
        "401" => Some(format!("{nick}: No such nick/channel")),
        _ => None,
    }
}

pub fn parse_333_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let (_prefix, rest) = rest.split_once(' ')?;
    let parts: Vec<&str> = rest.splitn(4, ' ').collect();
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
    }
    Some(did.to_string())
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

/// Render an IRC line as an HTML row with timestamp + nick color.
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
    format!(
        r#"<div class="notice">{ts_html}<span class="body">{safe}</span></div>"#
    )
}

/// Extract a reaction from an incoming live TAGMSG line.
/// Returns `(target_msgid, emoji, reactor_nick, added)` on success, where
/// `added` is true for `+react` and false for `+freeq.at/unreact`.
pub fn parse_tagmsg_reaction(line: &str) -> Option<(String, String, String, bool)> {
    let (tags, after) = parse_irc_tags(line);
    let (emoji, added) = if let Some(e) = tags.get("+react") {
        (e, true)
    } else if let Some(e) = tags.get("+freeq.at/unreact") {
        (e, false)
    } else {
        return None;
    };
    let msgid = tags.get("+reply")?;
    if !after
        .split_whitespace()
        .nth(1)?
        .eq_ignore_ascii_case("TAGMSG")
    {
        return None;
    }
    let nick = after
        .strip_prefix(':')?
        .split('!')
        .next()
        .unwrap_or("")
        .to_string();
    Some((msgid.clone(), emoji.clone(), nick, added))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn entry(nick: &str, op: bool, halfop: bool, voiced: bool) -> MemberEntry {
        MemberEntry {
            nick: nick.to_string(),
            op,
            halfop,
            voiced,
        }
    }

    #[test]
    fn parse_353_strips_mode_prefixes() {
        let line = ":srv 353 me = #ch :@op +voice %half normal";
        let v = parse_353_members(line);
        let nicks: Vec<&str> = v.iter().map(|e| e.nick.as_str()).collect();
        assert_eq!(nicks, vec!["op", "voice", "half", "normal"]);
        assert!(v[0].op);
        assert!(v[1].voiced);
        assert!(v[2].halfop);
        assert!(!v[3].op && !v[3].halfop && !v[3].voiced);
    }

    #[test]
    fn parse_353_owner_admin_prefixes_map_to_op() {
        let v = parse_353_members(":srv 353 me = #ch :~owner &admin");
        assert_eq!(v[0].nick, "owner");
        assert!(v[0].op);
        assert_eq!(v[1].nick, "admin");
        assert!(v[1].op);
    }

    #[test]
    fn parse_353_drops_empty_tokens() {
        let v = parse_353_members(":srv 353 me = #ch :a  b ");
        let nicks: Vec<&str> = v.iter().map(|e| e.nick.as_str()).collect();
        assert_eq!(nicks, vec!["a", "b"]);
    }

    #[test]
    fn parse_353_no_trailing_param_is_empty() {
        assert!(parse_353_members(":srv 353 me = #ch").is_empty());
        assert!(parse_353_members("not an irc line").is_empty());
    }

    #[test]
    fn parse_join_basic() {
        let c = parse_member_change(":alice!u@h JOIN #general").unwrap();
        match c {
            MemberChange::Join { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "alice");
            }
            _ => panic!("expected Join"),
        }
    }

    #[test]
    fn parse_join_extended_ignores_extra_params() {
        let c = parse_member_change(":alice!u@h JOIN #general acct :Real Name").unwrap();
        match c {
            MemberChange::Join { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "alice");
            }
            _ => panic!("expected Join"),
        }
    }

    #[test]
    fn parse_part() {
        let c = parse_member_change(":bob!u@h PART #general :leaving").unwrap();
        match c {
            MemberChange::Part { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "bob");
            }
            _ => panic!("expected Part"),
        }
    }

    #[test]
    fn parse_quit() {
        let c = parse_member_change(":carol!u@h QUIT :ping timeout").unwrap();
        match c {
            MemberChange::Quit { nick } => assert_eq!(nick, "carol"),
            _ => panic!("expected Quit"),
        }
    }

    #[test]
    fn parse_mode_plus_ov_consumes_two_targets() {
        let c = parse_member_change(":op!u@h MODE #ch +ov alice bob").unwrap();
        match c {
            MemberChange::Mode { channel, ops } => {
                assert_eq!(channel, "#ch");
                assert_eq!(
                    ops,
                    vec![('o', true, "alice".into()), ('v', true, "bob".into())]
                );
            }
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_mixed_signs() {
        let c = parse_member_change(":op!u@h MODE #ch -o+v alice bob").unwrap();
        match c {
            MemberChange::Mode { ops, .. } => {
                assert_eq!(
                    ops,
                    vec![('o', false, "alice".into()), ('v', true, "bob".into())]
                );
            }
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_channel_modes_take_no_target() {
        let c = parse_member_change(":op!u@h MODE #ch +nt").unwrap();
        match c {
            MemberChange::Mode { ops, .. } => assert!(ops.is_empty()),
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_user_mode_is_not_a_member_change() {
        assert!(parse_member_change(":alice!u@h MODE alice +i").is_none());
    }

    #[test]
    fn parse_non_member_command_is_none() {
        assert!(parse_member_change(":alice!u@h PRIVMSG #ch :hi").is_none());
        assert!(parse_member_change("PING :srv").is_none());
    }

    #[test]
    fn render_empty_returns_placeholder() {
        let map: HashMap<String, MemberEntry> = HashMap::new();
        assert_eq!(
            render_member_list(&map),
            r#"<div class="member empty">—</div>"#
        );
    }

    #[test]
    fn render_sorts_by_rank_then_alpha() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("zoe".into(), entry("zoe", false, false, false));
        map.insert("amy".into(), entry("amy", false, false, true));
        map.insert("bob".into(), entry("bob", true, false, false));
        map.insert("cal".into(), entry("cal", false, false, false));
        let html = render_member_list(&map);
        let pos = |n: &str| html.find(n).unwrap();
        assert!(pos("bob") < pos("amy"), "op before voiced");
        assert!(pos("amy") < pos("cal"), "voiced before plain");
        assert!(pos("cal") < pos("zoe"), "plain alphabetical");
    }

    #[test]
    fn render_shows_prefix_spans_only_for_ranked() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("op".into(), entry("op", true, false, false));
        map.insert("hp".into(), entry("hp", false, true, false));
        map.insert("vc".into(), entry("vc", false, false, true));
        map.insert("pl".into(), entry("pl", false, false, false));
        let html = render_member_list(&map);
        assert!(html.contains(r#"<span class="pfx op">@</span>"#));
        assert!(html.contains(r#"<span class="pfx halfop">%</span>"#));
        assert!(html.contains(r#"<span class="pfx voice">+</span>"#));
        assert_eq!(html.matches("pfx").count(), 3);
    }

    #[test]
    fn render_escapes_nick() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("a<b>&c".into(), entry("a<b>&c", false, false, false));
        let html = render_member_list(&map);
        assert!(html.contains("a&lt;b&gt;&amp;c"));
        assert!(!html.contains("a<b>&c"));
    }

    #[test]
    fn should_emit_filters_privmsg_to_other_channel() {
        assert!(!should_emit(":alice!u@h PRIVMSG #other :hello", "#test"));
    }

    #[test]
    fn should_emit_passes_privmsg_to_same_channel() {
        assert!(should_emit(":alice!u@h PRIVMSG #test :hello", "#test"));
    }

    #[test]
    fn should_emit_case_insensitive_channel_match() {
        assert!(should_emit(":alice!u@h PRIVMSG #TEST :hello", "#test"));
    }

    #[test]
    fn should_emit_filters_notice_to_other_channel() {
        assert!(!should_emit(":srv NOTICE #other :something", "#test"));
    }

    #[test]
    fn should_emit_passes_notice_to_same_channel() {
        assert!(should_emit(":srv NOTICE #test :welcome", "#test"));
    }

    #[test]
    fn should_emit_filters_topic_to_other_channel() {
        assert!(!should_emit(":op!u@h TOPIC #other :new topic", "#test"));
    }

    #[test]
    fn should_emit_passes_topic_to_same_channel() {
        assert!(should_emit(":op!u@h TOPIC #test :new topic", "#test"));
    }

    #[test]
    fn should_emit_passes_non_channel_scoped_message() {
        assert!(should_emit(":srv NOTICE * :Server shutting down", "#test"));
    }

    #[test]
    fn should_emit_skips_ping() {
        assert!(!should_emit("PING :server", "#test"));
    }

    #[test]
    fn should_emit_skips_numerics() {
        assert!(!should_emit(":srv 001 alice :Welcome to freeq", "#test"));
    }

    #[test]
    fn should_emit_filters_tagged_privmsg_to_other_channel() {
        assert!(!should_emit(
            "@msgid=abc :alice!u@h PRIVMSG #freeq :hello",
            "#test"
        ));
        assert!(should_emit(
            "@msgid=abc :alice!u@h PRIVMSG #test :hello",
            "#test"
        ));
    }

    #[test]
    fn extract_target_privmsg() {
        assert_eq!(extract_irc_target("PRIVMSG #chan :hello"), Some("#chan"));
    }

    #[test]
    fn extract_target_notice_channel() {
        assert_eq!(extract_irc_target("NOTICE #chan :msg"), Some("#chan"));
    }

    #[test]
    fn extract_target_notice_star_returns_none() {
        assert_eq!(extract_irc_target("NOTICE * :Server shutting down"), None);
    }

    #[test]
    fn extract_target_privmsg_nick_returns_none() {
        assert_eq!(extract_irc_target("PRIVMSG alice :hello"), None);
    }

    #[test]
    fn extract_target_mode() {
        assert_eq!(extract_irc_target("MODE #chan +o bob"), Some("#chan"));
    }

    #[test]
    fn extract_target_non_channel_command_returns_none() {
        assert_eq!(extract_irc_target("QUIT :bye"), None);
        assert_eq!(extract_irc_target("JOIN :#chan"), None);
        assert_eq!(extract_irc_target("PART #chan"), None);
    }

    #[test]
    fn parse_topic_change_topic_same_channel() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #test :new topic", "#test"),
            Some("new topic".to_string())
        );
    }

    #[test]
    fn parse_topic_change_topic_other_channel_is_none() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #other :new topic", "#test"),
            None
        );
    }

    #[test]
    fn parse_topic_change_332_same_channel() {
        assert_eq!(
            parse_topic_change(":srv 332 alice #test :welcome", "#test"),
            Some("welcome".to_string())
        );
    }

    #[test]
    fn parse_topic_change_332_other_channel_is_none() {
        assert_eq!(
            parse_topic_change(":srv 332 alice #other :welcome", "#test"),
            None
        );
    }

    #[test]
    fn parse_topic_change_topic_with_colons_and_channel_in_text() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #test :visit #test at https://x/y", "#test"),
            Some("visit #test at https://x/y".to_string())
        );
    }

    #[test]
    fn parse_whois_line_variants() {
        assert_eq!(
            parse_whois_line(":srv 311 me alice ~user freeq/plc/abc * :Alice User"),
            Some("alice is ~user@freeq/plc/abc (Alice User)".to_string())
        );
        assert_eq!(
            parse_whois_line(":srv 312 me alice irc.freeq.at :freeq server"),
            Some("alice using irc.freeq.at (freeq server)".to_string())
        );
        assert_eq!(
            parse_whois_line(":srv 319 me alice :#general #rust"),
            Some("alice on #general #rust".to_string())
        );
        assert_eq!(
            parse_whois_line(":srv 330 me alice did:plc:xyz :is logged in as"),
            Some("alice is logged in as did:plc:xyz".to_string())
        );
        assert_eq!(
            parse_whois_line(":srv 318 me alice :End of /WHOIS list"),
            Some("End of WHOIS for alice".to_string())
        );
        assert_eq!(
            parse_whois_line(":srv 401 me alice :No such nick"),
            Some("alice: No such nick/channel".to_string())
        );
        assert_eq!(parse_whois_line(":srv 001 me :welcome"), None);
    }
}
