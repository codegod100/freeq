use topcoat::router::{Body, IntoResponse, Response, route};
use topcoat::Result;
use topcoat::context::Cx;

struct StaticFile {
    content_type: &'static str,
    body: &'static [u8],
}

impl IntoResponse for StaticFile {
    fn into_response(self, _cx: &Cx) -> Result<Response> {
        Ok(Response::builder()
            .status(200)
            .header("Content-Type", self.content_type)
            .header("Cache-Control", "public, max-age=3600")
            .body(Body::from(self.body))?)
    }
}

#[route(GET "/manifest.json")]
async fn manifest() -> Result<StaticFile> {
    Ok(StaticFile {
        content_type: "application/manifest+json",
        body: include_bytes!("../../static/manifest.json"),
    })
}

#[route(GET "/sw.js")]
async fn service_worker() -> Result<StaticFile> {
    Ok(StaticFile {
        content_type: "application/javascript",
        body: include_bytes!("../../static/sw.js"),
    })
}

#[route(GET "/icon-192.png")]
async fn icon_192() -> Result<StaticFile> {
    Ok(StaticFile {
        content_type: "image/png",
        body: include_bytes!("../../static/icon-192.png"),
    })
}

#[route(GET "/icon-512.png")]
async fn icon_512() -> Result<StaticFile> {
    Ok(StaticFile {
        content_type: "image/png",
        body: include_bytes!("../../static/icon-512.png"),
    })
}
