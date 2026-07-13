//! Static/PWA asset routes.

use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};

/// Serve the PWA web app manifest.
pub async fn get_manifest_json() -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/manifest+json; charset=utf-8")],
        include_str!("../../static/manifest.json"),
    )
        .into_response()
}

/// Serve the service worker.
pub async fn get_service_worker() -> Response {
    (
        StatusCode::OK,
        [(
            header::CONTENT_TYPE,
            "application/javascript; charset=utf-8",
        )],
        include_str!("../../static/sw.js"),
    )
        .into_response()
}

/// Serve the 192x192 PWA icon.
pub async fn get_icon_192() -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "image/png")],
        include_bytes!("../../static/icon-192.png"),
    )
        .into_response()
}

/// Serve the 512x512 PWA icon.
pub async fn get_icon_512() -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "image/png")],
        include_bytes!("../../static/icon-512.png"),
    )
        .into_response()
}

/// Serve the wasm-bindgen JS shim for the freeq-webui-client crate.
/// Built by `buck2 build //:freeq-webui-client` (or via the script in
/// `freeq-webui-client/build.sh`); the file is copied into `static/`
/// at build time so it embeds via `include_str!`.
pub async fn get_freeq_client_js() -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-cache, no-store, must-revalidate"),
        ],
        include_str!("../../static/freeq_webui_client.js"),
    )
        .into_response()
}

/// Built by `buck2 build //:freeq-webui-client` (or via the script in
/// `freeq-webui-client/build.sh`); the file is copied into `static/`
/// at build time so it embeds via `include_bytes!`.
pub async fn get_freeq_client_wasm() -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/wasm"),
            (header::CACHE_CONTROL, "no-cache, no-store, must-revalidate"),
        ],
        include_bytes!("../../static/freeq_webui_client_bg.wasm"),
    )
        .into_response()
}
