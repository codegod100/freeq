//! Small request helpers shared by the web UI handlers.

use axum::http::{header, HeaderValue};
use rand::Rng;

/// Pull the `session_id` cookie or mint a new one. Returns (id, is_new).
pub fn session_id_from_request(req: &axum::http::HeaderMap) -> (String, bool) {
    if let Some(v) = req.get(header::COOKIE).and_then(|h| h.to_str().ok()) {
        for part in v.split(';').map(str::trim) {
            if let Some(rest) = part.strip_prefix("session_id=") {
                if !rest.is_empty() {
                    return (rest.to_string(), false);
                }
            }
        }
    }
    let mut buf = [0u8; 16];
    rand::thread_rng().fill(&mut buf);
    (hex::encode(buf), true)
}

pub fn session_cookie_header(id: &str) -> HeaderValue {
    // 30 days. No Secure flag (we may be on http://localhost for dev).
    HeaderValue::from_str(&format!(
        "session_id={id}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
    ))
    .expect("cookie header is always ASCII")
}

/// Derive a `https://host[:port]` URL from the incoming request, honoring
/// `X-Forwarded-Proto` so a reverse proxy / Tailscale funnel can still get a
/// working callback URI without the operator having to set FREEQ_PUBLIC_URL.
/// Returns `None` for obviously-loopback hosts (so the legacy loopback OAuth
/// flow keeps working for local dev).
pub fn public_url_from_request(req: &axum::http::HeaderMap) -> Option<String> {
    let host = req
        .get(axum::http::header::HOST)
        .and_then(|h| h.to_str().ok())?
        .trim();
    if host.is_empty() {
        return None;
    }
    let host_clean = host.trim_start_matches('[').trim_end_matches(']');
    let host_lower = host_clean.to_ascii_lowercase();
    if host_lower == "127.0.0.1"
        || host_lower == "localhost"
        || host_lower == "::1"
        || host_lower.starts_with("127.")
    {
        return None;
    }
    let scheme = req
        .get("x-forwarded-proto")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("http")
        .split(',')
        .next()
        .unwrap_or("http")
        .trim()
        .to_string();
    Some(format!("{scheme}://{host}"))
}

// Inline hex encoder — avoids pulling another crate for 8 lines.
mod hex {
    pub fn encode<T: AsRef<[u8]>>(data: T) -> String {
        use std::fmt::Write;
        let mut s = String::with_capacity(data.as_ref().len() * 2);
        for b in data.as_ref() {
            let _ = write!(s, "{b:02x}");
        }
        s
    }
}

pub fn canonical_channel(s: &str) -> String {
    if s.starts_with('#') {
        s.to_string()
    } else {
        format!("#{s}")
    }
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

/// Convert a handle into a valid IRC nick: keep only alphanumeric,
/// dots, hyphens, underscores; truncate to 20 chars.
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

/// Wrap `https://` URLs in the already-escaped text with `<a target="_blank">`.
pub fn linkify_urls(escaped: &str) -> String {
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

pub fn nick_color_class(nick: &str) -> &'static str {
    let mut h: u64 = 5381;
    for b in nick.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    const CLASSES: &[&str] = &["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"];
    CLASSES[(h % 8) as usize]
}
