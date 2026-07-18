//! Channel list + per-channel chat shell.

mod channel;

use topcoat::Result;
use topcoat::context::Cx;
use topcoat::router::page;
use topcoat::view::view;

use crate::app::state;
use crate::irc_render::canonical_channel;
use crate::session_util::ensure_session_id;
use crate::state::{AuthState, EVENTS_JS};
use crate::upstream::fetch_channels;

#[page("/chat")]
async fn channels_page(cx: &Cx) -> Result {
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
    channels.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    let auth = session.auth.lock().clone();
    let (login_handle, is_auth) = match &auth {
        AuthState::Authenticated { handle, .. } => (handle.clone(), true),
        AuthState::Guest => (String::new(), false),
    };

    view! {
        <div class="flex h-dvh flex-col">
            <header class="flex items-center justify-between border-b border-[#232932] px-4 py-3">
                <div class="flex items-center gap-3">
                    <span class="text-lg font-bold">"freeq"</span>
                    <span class="text-sm text-zinc-500">"channels"</span>
                </div>
                <div class="flex items-center gap-3 text-sm">
                    if is_auth {
                        <span class="text-[#5cdb95]">"🔒 " (login_handle.clone())</span>
                        <form method="POST" action="/logout">
                            <button type="submit" class="text-zinc-400 hover:text-white">"Sign out"</button>
                        </form>
                    } else {
                        <a href="/login" class="text-[#7ab7ff] hover:underline">"Sign in"</a>
                    }
                </div>
            </header>
            <main class="flex-1 overflow-y-auto p-4">
                <form id="join-form" class="mb-4 flex gap-2">
                    <input
                        class="flex-1 rounded-lg border border-[#232932] bg-[#151a22] px-3 py-2 text-sm"
                        type="text"
                        name="channel"
                        placeholder="join #channel"
                        autocomplete="off"
                    >
                    <button
                        type="submit"
                        class="rounded-lg bg-[#7ab7ff] px-3 py-2 text-sm font-semibold text-[#0e1116]"
                    >
                        "Join"
                    </button>
                </form>
                <ul class="space-y-1">
                    for ch in channels {
                        let bare = ch.name.trim_start_matches('#').to_string();
                        let href = format!("/chat/{bare}");
                        let is_joined = joined.iter().any(|j| j.eq_ignore_ascii_case(&ch.name));
                        <li>
                            <a
                                href=(href)
                                class="flex items-center justify-between rounded-lg px-3 py-2 text-sm hover:bg-[#151a22]"
                            >
                                <span
                                    class=(if is_joined {
                                        "text-[#7ab7ff] font-medium"
                                    } else {
                                        "text-zinc-300"
                                    })
                                >
                                    (ch.name.clone())
                                </span>
                                <span class="text-xs text-zinc-500">(ch.members)</span>
                            </a>
                        </li>
                    }
                </ul>
            </main>
            <script type="module" src=(EVENTS_JS)></script>
        </div>
    }
}
