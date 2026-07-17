//! Browser session cookie helpers (stable sid across restarts).

use topcoat::context::Cx;
use topcoat::cookie::{Cookie, Cookies, cookies};
use rand::Rng;

const COOKIE_NAME: &str = "session_id";

/// Return the browser session id, minting and setting a cookie if missing.
pub fn ensure_session_id(cx: &Cx) -> String {
    let jar = cookies(cx);
    if let Some(c) = jar.get(COOKIE_NAME) {
        let v = c.value().to_string();
        if !v.is_empty() {
            return v;
        }
    }
    let mut buf = [0u8; 16];
    rand::thread_rng().fill(&mut buf);
    let id = hex_encode(&buf);
    jar.add(
        Cookie::build((COOKIE_NAME, id.clone()))
            .path("/")
            .http_only(true)
            .same_site(topcoat::cookie::SameSite::Lax)
            .max_age(topcoat::cookie::time::Duration::days(30))
            .build(),
    );
    id
}

fn hex_encode(data: &[u8]) -> String {
    use std::fmt::Write;
    let mut s = String::with_capacity(data.len() * 2);
    for b in data {
        let _ = write!(s, "{b:02x}");
    }
    s
}
