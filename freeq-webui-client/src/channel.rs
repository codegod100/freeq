use wasm_bindgen::prelude::*;
use yew::prelude::*;
use yew_router::prelude::*;
use web_sys::MouseEvent;
use js_sys::eval;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ChannelEntry {
    pub name: String,
    #[serde(default)]
    pub topic: String,
    #[serde(default)]
    pub members: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct ChannelListPayload {
    pub channels: Vec<ChannelEntry>,
    pub joined: Vec<String>,
    pub current_channel: String,
}

#[derive(Clone, Routable, PartialEq)]
pub enum Route {
    #[at("/chat/:channel")]
    Chat { channel: String },
    #[at("/chat")]
    Channels,
    #[not_found]
    #[at("/")]
    NotFound,
}

/// Run the Yew channel-list app, mounting into `#freeq-sidebar`.
/// The server writes the initial payload into the `#freeq-channels-data`
/// textarea before the module script loads.
#[wasm_bindgen]
pub fn init_channel_list() -> Result<(), JsValue> {
    let window = web_sys::window().ok_or_else(|| JsValue::from_str("no window"))?;
    let document = window.document().ok_or_else(|| JsValue::from_str("no document"))?;
    let data_el = document.get_element_by_id("freeq-channels-data")
        .ok_or_else(|| JsValue::from_str("no #freeq-channels-data element"))?;
    let raw = data_el.text_content().unwrap_or_default();
    let data: ChannelListPayload = serde_json::from_str(&raw)
        .map_err(|e| JsValue::from_str(&format!("parse error: {e}")))?;
    let mount = document.get_element_by_id("freeq-sidebar")
        .ok_or_else(|| JsValue::from_str("no #freeq-sidebar element"))?;

    yew::Renderer::<RouterApp>::with_root_and_props(
        mount,
        RouterProps { payload: data },
    ).render();

    Ok(())
}

#[derive(Clone, PartialEq, Properties)]
pub struct RouterProps {
    pub payload: ChannelListPayload,
}

#[function_component(RouterApp)]
fn router_app(props: &RouterProps) -> Html {
    let payload = props.payload.clone();
    let current_channel = payload.current_channel.clone();
    html! {
        <BrowserRouter>
            <RouteHandler current_channel={current_channel} />
            <ChannelApp channels={payload.channels} joined={payload.joined} current_channel={payload.current_channel} />
        </BrowserRouter>
    }
}

#[derive(Clone, PartialEq, Properties)]
pub struct RouteHandlerProps {
    pub current_channel: String,
}

#[function_component(RouteHandler)]
fn route_handler(props: &RouteHandlerProps) -> Html {
    let route = use_route::<Route>();
    let current = props.current_channel.trim_start_matches('#').to_ascii_lowercase();
    // Only fire when the route target genuinely changes from the last
    // one we handled. This protects against the loop where re-running
    // init_channel_list on swap re-mounts the Yew tree and re-fires the
    // effect.
    let last_handled = use_state(String::new);
    use_effect_with_deps(
        move |route: &Option<Route>| {
            if let Some(Route::Chat { channel }) = route {
                let target = channel.trim_start_matches('#').to_ascii_lowercase();
                if target != current && target != *last_handled {
                    last_handled.set(target);
                    let escaped = channel.replace('\\', "\\\\").replace('"', "\\\"");
                    let js = format!(
                        r#"if(window.navigateChannel){{window.navigateChannel("{}");}}"#,
                        escaped
                    );
                    let _ = eval(&js);
                }
            }
            || ()
        },
        route,
    );
    html! {}
}

// ── Yew Channel App ──────────────────────────────────────────────────────

#[derive(Clone, PartialEq, Properties)]
pub struct ChannelAppProps {
    pub channels: Vec<ChannelEntry>,
    pub joined: Vec<String>,
    pub current_channel: String,
}

#[function_component(ChannelApp)]
fn channel_app(props: &ChannelAppProps) -> Html {
    let navigator = use_navigator().expect("navigator");
    let joined_set: std::collections::HashSet<_> = props.joined.iter().cloned().collect();
    let current = props.current_channel.trim_start_matches('#').to_ascii_lowercase();

    let my_channels: Vec<&ChannelEntry> = props
        .channels
        .iter()
        .filter(|c| joined_set.contains(&c.name))
        .collect();
    let all_channels: Vec<&ChannelEntry> = props
        .channels
        .iter()
        .filter(|c| !joined_set.contains(&c.name))
        .collect();

    let all_hidden = all_channels.is_empty();

    html! {
        <div class="menu">
            <p class="menu-label has-text-grey-light px-2 pt-2 mb-0 sidebar-toggle" data-target="my-channels" style="font-size:.65rem;letter-spacing:.05em">{"MY CHANNELS"}</p>
            <ul class="menu-list" id="my-channels">
                { for my_channels.iter().map(|ch| render_channel(ch, &current, navigator.clone())) }
            </ul>
            <p class={classes!("menu-label", "has-text-grey-light", "px-2", "pt-2", "mb-0", "sidebar-toggle", all_hidden.then(|| "collapsed"))} data-target="all-channels" style="font-size:.65rem;letter-spacing:.05em">{"ALL CHANNELS"}</p>
            <ul class="menu-list" id="all-channels" style={if all_hidden { "display:none" } else { "" }}>
                { for all_channels.iter().map(|ch| render_channel(ch, &current, navigator.clone())) }
            </ul>
        </div>
    }
}

fn render_channel(ch: &&ChannelEntry, current: &str, navigator: Navigator) -> Html {
    let name_no_hash = ch.name.trim_start_matches('#');
    let active = name_no_hash.to_ascii_lowercase() == *current;
    let policy_name = name_no_hash.to_string();
    let channel_name = name_no_hash.to_string();

    let onclick = {
        let navigator = navigator.clone();
        let name = name_no_hash.to_string();
        Callback::from(move |e: MouseEvent| {
            e.prevent_default();
            navigator.push(&Route::Chat { channel: name.clone() });
        })
    };

    let show_policy = Callback::from(move |e: MouseEvent| {
        e.stop_propagation();
        let escaped = policy_name.replace('\\', "\\\\").replace('"', "\\\"");
        let js = format!(r#"showPolicy("{}")"#, escaped);
        let _ = eval(&js);
    });

    html! {
        <li class="channel-row">
            <a class={classes!("channel-link", "is-size-7", "py-1", "px-2", active.then(|| "is-active"))}
               href={format!("/chat/{}", channel_name)}
               title={ch.topic.clone()}
               onclick={onclick}>
                <span style="overflow-wrap:anywhere">{&ch.name}</span>
            </a>
            <button type="button" class="tag is-rounded is-dark is-small policy-tag"
                title="Channel policy" onclick={show_policy}>
                {ch.members.to_string()}
            </button>
        </li>
    }
}
