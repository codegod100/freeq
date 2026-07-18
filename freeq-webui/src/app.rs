//! Topcoat module router and root layout.

mod actions;
mod api;
mod auth;
mod chat;
mod events;
mod login;
mod static_files;

use topcoat::Result;
use topcoat::asset::{AssetBundle, RouterBuilderAssetExt};
use topcoat::context::{Cx, app_context};
use topcoat::cookie::RouterBuilderCookieExt;
use topcoat::router::{Router, RouterBuilderDiscoverExt, Slot, layout, page, redirect};
use topcoat::tailwind;
use topcoat::view::view;

use crate::state::AppState;

pub fn router(state: AppState) -> Router {
    let assets = AssetBundle::load().unwrap_or_else(|e| {
        tracing::warn!(
            "asset bundle not found ({e}); run `topcoat asset bundle` after cargo build"
        );
        AssetBundle::empty()
    });
    Router::builder()
        .cookies()
        .assets(assets)
        .app_context(state)
        .discover()
        .build()
}

pub(crate) fn state(cx: &Cx) -> AppState {
    app_context::<AppState>(cx).clone()
}

#[layout("/")]
async fn root_layout(slot: Slot<'_>) -> Result {
    view! {
        <!DOCTYPE html>
        <html lang="en" class="h-full">
            <head>
                <meta charset="utf-8">
                <meta
                    name="viewport"
                    content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=0"
                >
                <meta name="theme-color" content="#0e1116">
                <meta name="mobile-web-app-capable" content="yes">
                <link rel="manifest" href="/manifest.json">
                <link rel="icon" href="/icon-192.png">
                <title>"freeq"</title>
                topcoat::dev::script()
                topcoat::runtime::script()
                <link rel="stylesheet" href=(tailwind::stylesheet!())>
                <style>
                    r#"
:root {
  --nick-1:#7ab7ff;--nick-2:#f78b6c;--nick-3:#c792ea;--nick-4:#ffd166;
  --nick-5:#06d6a0;--nick-6:#ef476f;--nick-7:#f4a261;--nick-8:#90e0ef;
  --self:#5cdb95;--bg:#0e1116;--fg:#d6d6d6;--muted:#6b7280;--border:#232932;
}
html,body{height:100dvh;overflow:hidden;background:var(--bg);color:var(--fg)}
::-webkit-scrollbar{width:6px}::-webkit-scrollbar-track{background:#1a1a2e}
::-webkit-scrollbar-thumb{background:#333;border-radius:3px}
*{scrollbar-width:thin;scrollbar-color:#333 #1a1a2e}
#messages{overflow-y:auto;flex:1}
#messages .msg{display:grid;grid-template-columns:48px 1fr;gap:.3rem;padding:1px 0;font-size:.8rem}
#messages .ts{color:var(--muted);font-size:.65rem;text-align:right;user-select:none}
#messages .body{white-space:pre-wrap;overflow-wrap:anywhere}
#messages .nick{font-weight:600}
.nick.n1{color:var(--nick-1)}.nick.n2{color:var(--nick-2)}.nick.n3{color:var(--nick-3)}.nick.n4{color:var(--nick-4)}
.nick.n5{color:var(--nick-5)}.nick.n6{color:var(--nick-6)}.nick.n7{color:var(--nick-7)}.nick.n8{color:var(--nick-8)}
#messages .notice{color:var(--muted);font-style:italic;padding:2px 0}
#messages .join .body{color:var(--nick-5)}#messages .part .body{color:var(--nick-6)}
#member-panel .pfx.op{color:var(--self)}
#status .dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--muted);margin-right:4px}
#status.connected .dot{background:var(--self);box-shadow:0 0 5px var(--self)}
#messages a{color:#7ab7ff}
.reactions{display:inline-flex;flex-wrap:wrap;gap:3px;margin-left:6px;vertical-align:middle}
.reaction-chip{display:inline-flex;align-items:center;gap:2px;padding:1px 6px;background:rgba(255,255,255,.07);border:1px solid var(--border);border-radius:999px;font-size:.75rem;cursor:pointer}
.react-btn{opacity:.5;border:1px dashed var(--border);border-radius:999px;width:1.2rem;height:1.2rem;background:transparent;color:var(--muted);cursor:pointer}
#messages .msg:hover .react-btn{opacity:1}
#react-picker{position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);display:none;z-index:100;background:var(--bg);border:1px solid var(--border);border-radius:.5rem;padding:.4rem;gap:4px}
#react-picker.open{display:flex}
#react-picker button{background:transparent;border:0;padding:.25rem .4rem;font-size:1.25rem;cursor:pointer}
#mobile-backdrop{display:none;position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:90}
#mobile-backdrop.open{display:block}
#policy-modal{display:none;position:fixed;inset:0;z-index:120;align-items:center;justify-content:center;background:rgba(0,0,0,.7)}
#policy-modal.open{display:flex}
.sidebar-toggle{cursor:pointer;user-select:none}
.sidebar-toggle.collapsed::before{transform:rotate(-90deg)}
@media(max-width:1024px){
  #sidebar,#member-panel{position:fixed;top:0;bottom:0;width:260px;max-width:80vw;background:var(--bg);z-index:100;transition:transform .2s ease}
  #sidebar{left:0;transform:translateX(-110%);border-right:1px solid var(--border)}
  #member-panel{right:0;transform:translateX(110%);border-left:1px solid var(--border)}
  #sidebar.open,#member-panel.open{transform:translateX(0)}
  .mobile-btn{display:flex!important}
}
"#
                </style>
            </head>
            <body class="h-full bg-[#0e1116] text-[#d6d6d6] font-sans antialiased">
                (slot.await?)
            </body>
        </html>
    }
}

#[page("/")]
async fn home() -> Result {
    Err(redirect("/chat").into())
}
