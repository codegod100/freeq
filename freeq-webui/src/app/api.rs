use topcoat::context::Cx;
use topcoat::router::{Json, path_param, route};
use topcoat::Result;

use crate::app::state;
use crate::irc_render::canonical_channel;
use crate::upstream::{fetch_channels, UpstreamChannel};

#[path_param]
struct Channel(str);

#[path_param]
struct Hash(str);

#[route(GET "/api/channels")]
async fn api_channels(cx: &Cx) -> Result<Json<Vec<UpstreamChannel>>> {
    let app = state(cx);
    let channels = fetch_channels(&app).await.unwrap_or_default();
    Ok(Json(channels))
}

#[route(GET "/api/policy/{channel}")]
async fn api_policy(cx: &Cx) -> Result<String> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let url = app
        .upstream
        .base
        .join(&format!(
            "api/v1/channels/{}/policy",
            urlencoding_channel(&channel)
        ))
        .unwrap();
    match app.http.get(url).send().await {
        Ok(r) => Ok(r.text().await.unwrap_or_default()),
        Err(e) => Ok(format!("upstream error: {e}")),
    }
}

#[route(GET "/api/policy/{channel}/rules")]
async fn api_policy_rules(cx: &Cx) -> Result<String> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let url = app
        .upstream
        .base
        .join(&format!(
            "api/v1/channels/{}/policy/rules",
            urlencoding_channel(&channel)
        ))
        .unwrap();
    match app.http.get(url).send().await {
        Ok(r) => Ok(r.text().await.unwrap_or_default()),
        Err(e) => Ok(format!("upstream error: {e}")),
    }
}

#[route(GET "/api/rules/{hash}")]
async fn api_rule(cx: &Cx) -> Result<String> {
    let hash = path_param::<Hash>(cx);
    let app = state(cx);
    let url = app
        .upstream
        .base
        .join(&format!("api/v1/rules/{hash}"))
        .unwrap();
    match app.http.get(url).send().await {
        Ok(r) => Ok(r.text().await.unwrap_or_default()),
        Err(e) => Ok(format!("upstream error: {e}")),
    }
}

fn urlencoding_channel(channel: &str) -> String {
    // REST path uses channel without #, percent-encoded if needed.
    let bare = channel.trim_start_matches('#');
    bare.replace('/', "%2F")
}
