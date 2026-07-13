//! Yew component that opens an EventSource to /chat/{channel}/stream and
//! appends incoming IRC lines to #messages.

use wasm_bindgen::prelude::*;
use yew::prelude::*;

#[derive(Clone, PartialEq, Properties)]
pub struct StreamProps {
    pub channel: String,
}

#[wasm_bindgen]
pub fn init_stream() -> Result<(), JsValue> {
    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let document = window.document().ok_or_else(|| JsValue::from_str("no document"))?;
    let channel = current_channel(&document);
    let mount = document
        .get_element_by_id("freeq-stream-root")
        .ok_or_else(|| JsValue::from_str("no #freeq-stream-root element"))?;
    yew::Renderer::<StreamApp>::with_root_and_props(
        mount,
        StreamProps { channel },
    )
    .render();
    Ok(())
}

fn current_channel(document: &web_sys::Document) -> String {
    if let Some(form) = document.get_element_by_id("send-form") {
        if let Some(action) = form.get_attribute("action") {
            let parts: Vec<&str> = action.trim_matches('/').split('/').collect();
            if parts.len() >= 2 && parts[0] == "chat" {
                return parts[1].to_string();
            }
        }
    }
    if let Some(loc) = web_sys::window().and_then(|w| w.location().pathname().ok()) {
        let parts: Vec<&str> = loc.trim_matches('/').split('/').collect();
        if parts.len() >= 2 && parts[0] == "chat" {
            return parts[1].to_string();
        }
    }
    String::new()
}

#[function_component(StreamApp)]
fn stream_app(_props: &StreamProps) -> Html {
    // We don't actually need to render anything; the EventSource is opened
    // and managed by `attach_stream` called from the module script.
    html! {}
}

/// Open a new EventSource for the given channel, closing any previous one.
#[wasm_bindgen]
pub fn attach_stream(channel: String) -> Result<(), JsValue> {
    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let document = window.document().ok_or_else(|| JsValue::from_str("no document"))?;

    if let Ok(prev) = js_sys::Reflect::get(&window, &JsValue::from_str("__freeqES")) {
        if let Some(es) = prev.dyn_ref::<web_sys::EventSource>().cloned() {
            es.close();
        }
    }

    let url = format!("/chat/{}/stream", channel);
    let es = web_sys::EventSource::new(&url)
        .map_err(|e| JsValue::from_str(&format!("EventSource failed: {e:?}")))?;

    let _ = js_sys::Reflect::set(&window, &JsValue::from_str("__freeqES"), &es);

    setup_closure_handler(&es, &document, &channel);
    Ok(())
}

fn setup_closure_handler(es: &web_sys::EventSource, document: &web_sys::Document, channel: &str) {
    let doc = document.clone();
    let channel = channel.to_string();
    let closure: Closure<dyn FnMut(JsValue)> = Closure::new(move |ev: JsValue| {
        let data_opt = js_sys::Reflect::get(&ev, &JsValue::from_str("data"))
            .ok()
            .and_then(|v| v.as_string());
        if let Some(line) = data_opt {
            append_line(&doc, &line, &channel);
        }
    });
    es.set_onmessage(Some(closure.as_ref().unchecked_ref()));
    closure.forget();
}

fn append_line(document: &web_sys::Document, line: &str, channel: &str) {
    let Some(messages) = document.get_element_by_id("messages") else { return };
    let html = render_line_html(line, channel);
    let _ = messages.insert_adjacent_html("beforeend", &html);
}

fn render_line_html(line: &str, channel: &str) -> String {
    if let Some(w) = web_sys::window() {
        let func_val = js_sys::Reflect::get(&w, &JsValue::from_str("renderIncomingLine"))
            .unwrap_or(JsValue::UNDEFINED);
        if func_val.is_function() {
            let out = js_sys::Function::from(func_val).call2(
                &JsValue::NULL,
                &JsValue::from_str(line),
                &JsValue::from_str(channel),
            );
            if let Ok(v) = out {
                if let Some(s) = v.as_string() {
                    return s;
                }
            }
        }
    }
    format!(
        r#"<div class="msg"><span class="ts">--:--:--</span><span class="body">{}</span></div>"#,
        html_escape(line)
    )
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
