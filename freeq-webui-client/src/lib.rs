use wasm_bindgen::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub mod channel;
pub mod navbar;
pub mod stream;

// Re-export the WASM-bindgen entry points so wasm-pack picks them up at the
// crate root and emits them in the generated `freeq_webui_client.js`.
pub use channel::init_channel_list;
pub use navbar::init_navbar;
pub use stream::{attach_stream, init_stream};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberEntry {
    pub nick: String,
    pub op: bool,
    #[serde(default)]
    pub halfop: bool,
    #[serde(default)]
    pub voiced: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Signals {
    #[serde(default, rename = "myReactions")]
    my_reactions: HashMap<String, Vec<String>>,
    #[serde(default, rename = "currentNick")]
    current_nick: String,
}

#[wasm_bindgen]
pub fn update_member_panel(members: JsValue) -> Result<(), JsValue> {
    let list: Vec<MemberEntry> = serde_wasm_bindgen::from_value(members)
        .map_err(|e| JsValue::from_str(&format!("bad input: {e}")))?;
    let html = build_member_html(&list);
    set_inner_html("member-panel", &html);
    Ok(())
}

#[wasm_bindgen]
pub fn toggle_reaction(msgid: String, emoji: String, channel: String) -> Result<(), JsValue> {
    let body = html_body()?;

    let mut sigs = read_signals(&body);
    let map = sigs.my_reactions.entry(msgid.clone()).or_default();
    let had = map.contains(&emoji);
    let map = sigs.my_reactions.entry(msgid.clone()).or_insert_with(Vec::new);
    let had = map.contains(&emoji);
    if had {
        map.retain(|e| e != &emoji);
    } else {
        map.push(emoji.clone());
    }
    write_signals(&body, &sigs);
    update_chip_locally(&body, &msgid, &emoji, !had);

    let url = format!("/chat/{}/{}", channel, if had { "unreact" } else { "react" });
    let payload = serde_json::json!({ "msgid": msgid, "emoji": emoji });
    let body2 = body.clone();
    let emoji2 = emoji.clone();
    let msgid2 = msgid.clone();
    spawn_post(
        &url,
        &payload,
        move |ok| {
            if !ok {
                update_chip_locally(&body2, &msgid2, &emoji2, had);
            }
        },
    );
    Ok(())
}

#[wasm_bindgen]
pub fn peer_reaction(msgid: String, emoji: String, nick: String, added: bool) -> Result<(), JsValue> {
    let body = html_body()?;
    let sigs = read_signals(&body);

    let mut emoji_clean = emoji.trim().to_string();
    while emoji_clean.starts_with(':') {
        emoji_clean.remove(0);
    }
    while emoji_clean.ends_with(':') {
        emoji_clean.pop();
    }

    let selector = format!(
        "#msg-{msgid} .reaction-chip[data-emoji=\"{emoji}\"]",
        msgid = msgid.replace('\'', "").replace('"', ""),
        emoji = emoji_clean.replace('\\', "\\\\").replace('"', "\\\""),
    );
    let document = web_sys::window().unwrap().document().unwrap();
    let Some(chip) = document.query_selector(&selector).ok().flatten() else { return Ok(()); };
    let chip = chip.dyn_into::<web_sys::Element>().map_err(|_| JsValue::from_str("not element"))?;
    let title = chip.get_attribute("title").unwrap_or_default();
    let mut nicks: Vec<&str> = title.split(", ").filter(|s| !s.is_empty()).collect();
    let nick_str = nick.as_str();
    if added {
        if !nicks.contains(&nick_str) {
            nicks.push(nick_str);
        }
    } else {
        nicks.retain(|n| *n != nick_str);
    }
    chip.set_attribute("title", &nicks.join(", "));
    let count = if nicks.len() >= 2 {
        let emoji_part: String = chip
            .text_content()
            .unwrap_or_default()
            .chars()
            .skip_while(|c| c.is_ascii_digit())
            .collect();
        format!("{}{}", nicks.len(), emoji_part)
    } else {
        emoji_clean
    };
    chip.set_text_content(Some(&count));
    let mine = nicks.contains(&sigs.current_nick.as_str());
    let Ok(chip_el) = chip.dyn_into::<web_sys::HtmlElement>() else { return Ok(()); };
    if mine {
        let _ = chip_el.class_list().add_1("mine");
    } else {
        let _ = chip_el.class_list().remove_1("mine");
    }
    Ok(())
}

fn html_body() -> Result<web_sys::HtmlElement, JsValue> {
    web_sys::window()
        .ok_or_else(|| JsValue::from_str("no window"))?
        .document()
        .ok_or_else(|| JsValue::from_str("no document"))?
        .body()
        .ok_or_else(|| JsValue::from_str("no body"))?
        .dyn_into::<web_sys::HtmlElement>()
        .map_err(|_| JsValue::from_str("body isn't HtmlElement"))
}

fn read_signals(body: &web_sys::HtmlElement) -> Signals {
    let raw = body.get_attribute("data-signals").unwrap_or_default();
    serde_json::from_str(&raw).unwrap_or_default()
}

fn write_signals(body: &web_sys::HtmlElement, sigs: &Signals) {
    if let Ok(json) = serde_json::to_string(sigs) {
        body.set_attribute("data-signals", &json);
    }
}

fn update_chip_locally(body: &web_sys::HtmlElement, msgid: &str, emoji: &str, mine: bool) {
    let me = body.get_attribute("data-nick").unwrap_or_default();
    let document = match web_sys::window().and_then(|w| w.document()) {
        Some(d) => d,
        None => return,
    };
    let selector = format!(
        "#msg-{msgid} .reaction-chip[data-emoji=\"{emoji}\"]",
        msgid = msgid.replace('\'', "").replace('"', ""),
    );
    let Some(chip) = document.query_selector(&selector).ok().flatten() else { return; };
    let Ok(chip) = chip.dyn_into::<web_sys::Element>() else { return; };
    let title = chip.get_attribute("title").unwrap_or_default();
    let mut nicks: Vec<&str> = title.split(", ").filter(|s| !s.is_empty()).collect();
    if mine {
        if !nicks.contains(&me.as_str()) {
            nicks.push(&me);
        }
    } else {
        nicks.retain(|n| *n != me);
    }
    if nicks.is_empty() {
        chip.remove();
        return;
    }
    let count = if nicks.len() >= 2 {
        let emoji_part: String = chip
            .text_content()
            .unwrap_or_default()
            .chars()
            .skip_while(|c| c.is_ascii_digit())
            .collect();
        format!("{}{}", nicks.len(), emoji_part)
    } else {
        emoji.to_string()
    };
    chip.set_attribute("title", &nicks.join(", "));
    chip.set_text_content(Some(&count));
    if mine {
        let _ = chip.class_list().add_1("mine");
    } else {
        let _ = chip.class_list().remove_1("mine");
    }
}

fn spawn_post(url: &str, payload: &serde_json::Value, cb: impl FnOnce(bool) + 'static) {
    use wasm_bindgen_futures::JsFuture;
    let url = url.to_string();
    let payload = payload.clone();
    let window = match web_sys::window() {
        Some(w) => w,
        None => { cb(false); return; }
    };
    wasm_bindgen_futures::spawn_local(async move {
        let opts = web_sys::RequestInit::new();
        opts.set_method("POST");
        opts.set_credentials(web_sys::RequestCredentials::SameOrigin);
        let body = match serde_json::to_string(&payload) {
            Ok(s) => s,
            Err(_) => { cb(false); return; }
        };
        opts.set_body(&JsValue::from_str(&body));
        let headers = match web_sys::Headers::new() {
            Ok(h) => h,
            Err(_) => { cb(false); return; }
        };
        let _ = headers.set("content-type", "application/json");
        opts.set_headers(&headers);
        let req = match web_sys::Request::new_with_str_and_init(&url, &opts) {
            Ok(r) => r,
            Err(_) => { cb(false); return; }
        };
        let resp = match JsFuture::from(window.fetch_with_request(&req)).await {
            Ok(r) => r,
            Err(_) => { cb(false); return; }
        };
        let resp: web_sys::Response = match resp.dyn_into() {
            Ok(r) => r,
            Err(_) => { cb(false); return; }
        };
        cb(resp.ok());
    });
}

fn set_inner_html(id: &str, html: &str) {
    let document = match web_sys::window().and_then(|w| w.document()) {
        Some(d) => d,
        None => return,
    };
    if let Some(el) = document.get_element_by_id(id) {
        el.set_inner_html(html);
    }
}

fn build_member_html(members: &[MemberEntry]) -> String {
    if members.is_empty() {
        return r#"<div class="member empty">—</div>"#.to_string();
    }
    let mut sorted: Vec<&MemberEntry> = members.iter().collect();
    sorted.sort_by(|a, b| {
        let rank = |m: &&MemberEntry| match (m.op, m.halfop, m.voiced) {
            (true, _, _) => 0,
            (_, true, _) => 1,
            (_, _, true) => 2,
            _ => 3,
        };
        rank(a).cmp(&rank(b))
            .then_with(|| a.nick.to_lowercase().cmp(&b.nick.to_lowercase()))
    });
    let mut out = String::new();
    for m in sorted {
        let color = nick_color(&m.nick);
        let pfx = if m.op { r#"<span class="pfx op">@</span>"# }
            else if m.halfop { r#"<span class="pfx halfop">%</span>"# }
            else if m.voiced { r#"<span class="pfx voice">+</span>"# }
            else { "" };
        out.push_str(&format!(
            r#"<div class="member"><span class="pfx">{pfx}</span><span class="nick {color}">{nick}</span></div>"#,
            nick = html_escape(&m.nick),
        ));
    }
    out
}

fn nick_color(nick: &str) -> &'static str {
    let mut hash: u32 = 0;
    for b in nick.bytes() {
        hash = hash.wrapping_mul(31).wrapping_add(b as u32);
    }
    static COLORS: [&str; 8] = ["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"];
    COLORS[(hash as usize) % COLORS.len()]
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
