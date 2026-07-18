use topcoat::Result;
use topcoat::context::Cx;
use topcoat::router::{page, path_param};
use topcoat::view::{Unescaped, component, view};

use crate::app::state;
use crate::irc_render::{canonical_channel, render_history_row};
use crate::session_util::ensure_session_id;
use crate::state::{AuthState, EVENTS_JS};
use crate::upstream::{fetch_channels, fetch_history};

#[path_param]
struct Channel(str);

#[page("/chat/{channel}")]
async fn chat_channel(cx: &Cx) -> Result {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let bare = channel.trim_start_matches('#').to_string();

    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    let mut channels = fetch_channels(&app).await.unwrap_or_default();
    let joined: std::collections::HashSet<String> = session.joined.lock().iter().cloned().collect();
    let existing: std::collections::HashSet<String> =
        channels.iter().map(|c| c.name.to_lowercase()).collect();
    for ch in &joined {
        let c = canonical_channel(ch);
        if !existing.contains(&c.to_lowercase()) {
            channels.push(crate::upstream::UpstreamChannel {
                name: c,
                topic: String::new(),
                members: 0,
            });
        }
    }
    // Ensure current channel appears in joined list for sidebar.
    session.joined.lock().insert(channel.clone());

    let topic = channels
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&channel))
        .map(|c| c.topic.clone())
        .unwrap_or_default();

    let history = fetch_history(&app, &channel, 25).await.unwrap_or_default();
    // Seed dedup so JOIN chathistory replay over SSE is not appended again.
    session.note_seen_msgids(
        history
            .iter()
            .filter_map(|m| m.msgid.clone())
            .filter(|id| !id.is_empty()),
    );
    let initial_messages_html = history.iter().map(render_history_row).collect::<String>();

    let auth = session.auth.lock().clone();
    let (login_handle, auth_nick, is_auth) = match &auth {
        AuthState::Authenticated { handle, nick, .. } => (handle.clone(), nick.clone(), true),
        AuthState::Guest => (String::new(), String::new(), false),
    };

    let placeholder = format!("Send to {channel}…");
    let channel_label = channel.clone();

    // Split joined vs all for sidebar
    let mut my_channels = Vec::new();
    let mut all_channels = Vec::new();
    for ch in channels {
        if joined.iter().any(|j| j.eq_ignore_ascii_case(&ch.name))
            || ch.name.eq_ignore_ascii_case(&channel)
        {
            my_channels.push(ch);
        } else {
            all_channels.push(ch);
        }
    }

    view! {
        <div
            id="freeq-chat"
            class="flex h-dvh flex-col"
            data-channel=(bare.clone())
            data-auth-handle=(auth_nick.clone())
        >
            <nav class="flex shrink-0 items-center gap-2 border-b border-[#232932] px-2 py-2">
                <button
                    class="mobile-btn hidden h-10 w-10 items-center justify-center text-lg text-[#7ab7ff]"
                    type="button"
                    onclick="toggleSidebar()"
                    aria-label="Channels"
                >
                    "☰"
                </button>
                <span class="text-sm font-bold">"freeq"</span>
                <span class="text-sm text-[#7ab7ff]">(channel_label.clone())</span>
                <span
                    id="channel-topic"
                    class="ml-2 hidden truncate text-xs text-zinc-500 md:inline"
                >
                    (topic.clone())
                </span>
                <div class="ml-auto flex items-center gap-2 text-xs">
                    if is_auth {
                        <span class="text-[#5cdb95]">"🔒 " (login_handle.clone())</span>
                    } else {
                        <a href="/login" class="text-[#7ab7ff] hover:underline">"Sign in"</a>
                    }
                    <span id="status"><span class="dot"></span> <span>"connecting…"</span></span>
                    <button
                        class="mobile-btn hidden h-10 w-10 items-center justify-center text-lg"
                        type="button"
                        onclick="toggleMembers()"
                        aria-label="Members"
                    >
                        "👥"
                    </button>
                </div>
            </nav>

            <div class="relative flex min-h-0 flex-1">
                // Sidebar
                <aside
                    id="sidebar"
                    class="w-44 shrink-0 overflow-y-auto border-r border-[#232932] p-2 text-xs"
                >
                    <form id="join-form" class="mb-2 flex gap-1">
                        <input
                            class="min-w-0 flex-1 rounded border border-[#232932] bg-[#151a22] px-2 py-1"
                            type="text"
                            name="channel"
                            placeholder="join #…"
                            autocomplete="off"
                        >
                        <button
                            type="submit"
                            class="rounded bg-[#7ab7ff] px-2 py-1 font-semibold text-[#0e1116]"
                        >
                            "+"
                        </button>
                    </form>
                    <p
                        class="sidebar-toggle mb-1 px-1 text-[0.65rem] tracking-wide text-zinc-500"
                        data-target="my-channels"
                    >
                        "MY CHANNELS"
                    </p>
                    <ul id="my-channels" class="mb-3 space-y-0.5">
                        for ch in my_channels {
                            channel_link(ch: &ch, active: &channel)
                        }
                    </ul>
                    <p
                        class="sidebar-toggle collapsed mb-1 px-1 text-[0.65rem] tracking-wide text-zinc-500"
                        data-target="all-channels"
                    >
                        "ALL CHANNELS"
                    </p>
                    <ul id="all-channels" class="space-y-0.5" style="display:none">
                        for ch in all_channels {
                            channel_link(ch: &ch, active: &channel)
                        }
                    </ul>
                </aside>

                // Messages + compose
                <section class="flex min-w-0 flex-1 flex-col">
                    <div id="messages" class="flex-1 overflow-y-auto px-3 py-2">
                        (Unescaped::new_unchecked(initial_messages_html.clone()))
                    </div>
                    <form
                        id="send-form"
                        class="flex shrink-0 gap-2 border-t border-[#232932] px-2 py-2"
                    >
                        <input
                            class="min-w-0 flex-1 rounded-lg border border-[#232932] bg-[#151a22] px-3 py-2 text-sm outline-none focus:border-[#7ab7ff]"
                            type="text"
                            name="msg"
                            placeholder=(placeholder.clone())
                            autocomplete="off"
                            autofocus=(true)
                        >
                        <button
                            type="submit"
                            class="rounded-lg bg-[#7ab7ff] px-3 py-2 text-sm font-semibold text-[#0e1116]"
                        >
                            "Send"
                        </button>
                        <button
                            id="part-btn"
                            type="button"
                            class="rounded-lg border border-[#232932] px-3 py-2 text-sm text-zinc-400 hover:text-white"
                        >
                            "×"
                        </button>
                    </form>
                </section>

                // Members — render cached roster at SSR so the panel isn't blank
                // before the SSE pushes an update.
                let cached_members_html = {
                    let key = crate::irc_render::channel_key(&channel);
                    let members = session.channel_members.lock();
                    members
                        .get(&key)
                        .map(crate::irc_render::render_member_list)
                        .unwrap_or_else(|| r#"<div class="text-zinc-500">—</div>"#.to_string())
                };
                <aside
                    id="member-panel"
                    class="w-40 shrink-0 overflow-y-auto border-l border-[#232932] p-2 text-xs"
                >
                    (Unescaped::new_unchecked(cached_members_html))
                </aside>
            </div>

            <div id="react-picker" role="menu" aria-label="React with emoji"></div>
            <div id="mobile-backdrop" onclick="closeDrawers()"></div>
            <div id="policy-modal" onclick="if(event.target===this)closePolicy()">
                <div class="mx-4 w-full max-w-md rounded-xl border border-[#232932] bg-[#151a22] p-5 shadow-2xl">
                    <div class="mb-3 flex items-center gap-2">
                        <span class="text-base">"🛡️"</span>
                        <span class="font-semibold text-sm text-white">"Channel policy"</span>
                        <span
                            id="policy-channel-name"
                            class="rounded bg-[#1a1f28] px-1.5 py-0.5 text-[10px] text-zinc-400 font-mono"
                        ></span>
                        <button
                            type="button"
                            class="ml-auto text-zinc-500 hover:text-white text-lg leading-none px-1"
                            onclick="closePolicy()"
                            aria-label="Close"
                        >
                            "×"
                        </button>
                    </div>
                    <div id="policy-body" class="text-sm text-zinc-300 max-h-[70vh] overflow-y-auto"></div>
                </div>
            </div>

            <script type="module" src=(EVENTS_JS)></script>
        </div>
    }
}

#[component]
async fn channel_link(ch: &crate::upstream::UpstreamChannel, active: &str) -> Result {
    let bare = ch.name.trim_start_matches('#').to_string();
    let href = format!("/chat/{bare}");
    let is_active = ch.name.eq_ignore_ascii_case(active);
    let cls = if is_active {
        "block rounded px-2 py-1 bg-[#7ab7ff] text-[#0e1116] font-medium"
    } else {
        "block rounded px-2 py-1 text-zinc-300 hover:bg-[#151a22]"
    };
    let members = ch.members;
    let name = ch.name.clone();
    view! {
        <li class="flex items-center gap-1">
            <a href=(href) class=(cls) style="flex:1;min-width:0;overflow-wrap:anywhere">
                (name.clone())
            </a>
            <button
                type="button"
                class="rounded bg-[#1a1f28] px-1.5 py-0.5 text-[0.65rem] text-zinc-400 hover:text-white"
                title="Channel policy"
                onclick=(format!("event.stopPropagation();showPolicy('{}')", bare))
            >
                (members)
            </button>
        </li>
    }
}
