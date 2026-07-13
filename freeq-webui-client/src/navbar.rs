use wasm_bindgen::prelude::*;
use yew::prelude::*;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AuthPayload {
    #[serde(default)]
    pub handle: String,
    #[serde(default)]
    pub did: String,
    #[serde(default)]
    pub is_authenticated: bool,
}

#[wasm_bindgen]
pub fn init_navbar() -> Result<(), JsValue> {
    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let document = window.document().ok_or_else(|| JsValue::from_str("no document"))?;
    let data_el = document.get_element_by_id("freeq-auth-data")
        .ok_or_else(|| JsValue::from_str("no #freeq-auth-data element"))?;
    let raw = data_el.text_content().unwrap_or_default();
    let data: AuthPayload = serde_json::from_str(&raw)
        .map_err(|e| JsValue::from_str(&format!("parse error: {e}")))?;
    let mount = document.get_element_by_id("freeq-navbar")
        .ok_or_else(|| JsValue::from_str("no #freeq-navbar element"))?;

    yew::Renderer::<NavbarApp>::with_root_and_props(
        mount,
        NavbarProps {
            handle: data.handle,
            did: data.did,
            is_authenticated: data.is_authenticated,
        },
    ).render();
    Ok(())
}

#[derive(Clone, PartialEq, Properties)]
pub struct NavbarProps {
    pub handle: String,
    pub did: String,
    pub is_authenticated: bool,
}

#[function_component(NavbarApp)]
fn navbar(props: &NavbarProps) -> Html {
    if props.is_authenticated {
        html! {
            <>
                <div class="navbar-item py-1 is-size-7">{"@"}{&props.handle}</div>
                <div class="navbar-item py-1 is-size-7 has-text-grey">{&props.did}</div>
                <div class="navbar-item py-1"><a class="button is-small is-link is-outlined" href="/logout">{"Sign out"}</a></div>
            </>
        }
    } else {
        html! {
            <div class="navbar-item py-1"><a class="button is-small is-link is-outlined" href="/login">{"Sign in"}</a></div>
        }
    }
}
