//! Web + loopback OAuth helpers for freeq-webui.
//!
//! main's freeq-sdk exposes `OAuthSession` + `DpopKey` but not `PreparedLogin`.
//! This module reimplements the PAR / code-exchange dance for multi-user web UI.

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use freeq_sdk::did::DidResolver;
use freeq_sdk::oauth::{DpopKey, OAuthSession};
use freeq_sdk::pds;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[derive(Debug, Clone, Deserialize)]
struct AuthServerMetadata {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    #[serde(default)]
    pushed_authorization_request_endpoint: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct ProtectedResourceMetadata {
    #[serde(default)]
    authorization_servers: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    sub: Option<String>,
}

/// In-flight OAuth login (loopback or public web redirect).
pub struct PreparedLogin {
    auth_url: String,
    redirect_uri: String,
    client_id: String,
    state: String,
    code_verifier: String,
    token_endpoint: String,
    pds_url: String,
    dpop_key: DpopKey,
    listener: Option<TcpListener>,
    did: String,
    handle: String,
}

impl PreparedLogin {
    /// Loopback OAuth: binds `127.0.0.1:0` for the callback.
    pub async fn new(handle: &str) -> Result<Self> {
        let (did, pds_url, auth_meta) = resolve_identity(handle).await?;
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let redirect_uri = format!("http://127.0.0.1:{port}/callback");
        let scope = "atproto transition:generic";
        let client_id = format!(
            "http://localhost?redirect_uri={}&scope={}",
            urlencode(&redirect_uri),
            urlencode(scope),
        );
        Self::finish_prepare(
            handle,
            did,
            pds_url,
            auth_meta,
            redirect_uri,
            client_id,
            Some(listener),
        )
        .await
    }

    /// Public-web OAuth when `FREEQ_PUBLIC_URL` is set.
    ///
    /// Caller must serve `/.well-known/oauth-client-metadata` and
    /// `/auth/callback`, then call [`handle_callback`].
    pub async fn for_web(handle: &str, public_url: &str) -> Result<Self> {
        let public_url = public_url.trim_end_matches('/');
        let (did, pds_url, auth_meta) = resolve_identity(handle).await?;
        let redirect_uri = format!("{public_url}/auth/callback");
        let client_id = format!("{public_url}/.well-known/oauth-client-metadata");
        Self::finish_prepare(
            handle,
            did,
            pds_url,
            auth_meta,
            redirect_uri,
            client_id,
            None,
        )
        .await
    }

    async fn finish_prepare(
        handle: &str,
        did: String,
        pds_url: String,
        auth_meta: AuthServerMetadata,
        redirect_uri: String,
        client_id: String,
        listener: Option<TcpListener>,
    ) -> Result<Self> {
        let (code_verifier, code_challenge) = generate_pkce();
        let dpop_key = DpopKey::generate();
        let state = generate_random_string(16);
        let par_endpoint = auth_meta
            .pushed_authorization_request_endpoint
            .as_deref()
            .context("Authorization server does not support PAR")?;
        let auth_url = push_authorization_request(
            par_endpoint,
            &auth_meta.authorization_endpoint,
            &client_id,
            &redirect_uri,
            &code_challenge,
            &state,
            handle,
            &dpop_key,
        )
        .await?;
        Ok(Self {
            auth_url,
            redirect_uri,
            client_id,
            state,
            code_verifier,
            token_endpoint: auth_meta.token_endpoint,
            pds_url,
            dpop_key,
            listener,
            did,
            handle: handle.to_string(),
        })
    }

    pub fn auth_url(&self) -> &str {
        &self.auth_url
    }

    pub fn state(&self) -> &str {
        &self.state
    }

    pub async fn wait(mut self) -> Result<OAuthSession> {
        let listener = self
            .listener
            .take()
            .expect("wait() called on web PreparedLogin; use handle_callback()");
        let auth_code = wait_for_callback(listener, &self.state).await?;
        self.exchange_and_finish(&auth_code).await
    }

    pub async fn handle_callback(self, code: &str, callback_state: &str) -> Result<OAuthSession> {
        if callback_state != self.state {
            bail!(
                "State mismatch in OAuth callback: expected {}, got {}",
                self.state,
                callback_state
            );
        }
        self.exchange_and_finish(code).await
    }

    async fn exchange_and_finish(self, auth_code: &str) -> Result<OAuthSession> {
        let (access_token, token_did) = exchange_code(
            &self.token_endpoint,
            auth_code,
            &self.code_verifier,
            &self.redirect_uri,
            &self.client_id,
            &self.dpop_key,
        )
        .await?;
        if let Some(ref token_did) = token_did
            && token_did != &self.did
        {
            bail!(
                "DID mismatch: resolved {} but token is for {token_did}",
                self.did
            );
        }
        let dpop_nonce = probe_dpop_nonce(&self.pds_url, &access_token, &self.dpop_key).await;
        Ok(OAuthSession {
            did: self.did,
            handle: self.handle,
            access_token,
            pds_url: self.pds_url,
            dpop_key: self.dpop_key,
            dpop_nonce,
        })
    }
}

async fn resolve_identity(handle: &str) -> Result<(String, String, AuthServerMetadata)> {
    let resolver = DidResolver::http();
    tracing::info!("Resolving handle: {handle}");
    let did = resolver
        .resolve_handle(handle)
        .await
        .context("Failed to resolve handle")?;
    let did_doc = resolver
        .resolve(&did)
        .await
        .context("Failed to resolve DID document")?;
    let pds_url = pds::pds_endpoint(&did_doc).context("No PDS service endpoint in DID document")?;
    tracing::info!(did = %did, pds = %pds_url, "Resolved identity");
    let auth_meta = discover_auth_server(&pds_url).await?;
    tracing::info!(issuer = %auth_meta.issuer, "Found authorization server");
    Ok((did, pds_url, auth_meta))
}

async fn discover_auth_server(pds_url: &str) -> Result<AuthServerMetadata> {
    let client = reqwest::Client::new();
    let pr_url = format!(
        "{}/.well-known/oauth-protected-resource",
        pds_url.trim_end_matches('/')
    );
    let pr_meta: ProtectedResourceMetadata = client
        .get(&pr_url)
        .send()
        .await
        .context("Failed to fetch protected resource metadata")?
        .error_for_status()
        .context("Protected resource metadata request failed")?
        .json()
        .await
        .context("Failed to parse protected resource metadata")?;
    let auth_server = pr_meta
        .authorization_servers
        .first()
        .context("No authorization servers listed")?;
    let as_url = format!(
        "{}/.well-known/oauth-authorization-server",
        auth_server.trim_end_matches('/')
    );
    let auth_meta: AuthServerMetadata = client
        .get(&as_url)
        .send()
        .await
        .context("Failed to fetch authorization server metadata")?
        .error_for_status()
        .context("Authorization server metadata request failed")?
        .json()
        .await
        .context("Failed to parse authorization server metadata")?;
    Ok(auth_meta)
}

#[allow(clippy::too_many_arguments)]
async fn push_authorization_request(
    par_endpoint: &str,
    authorization_endpoint: &str,
    client_id: &str,
    redirect_uri: &str,
    code_challenge: &str,
    state: &str,
    login_hint: &str,
    dpop_key: &DpopKey,
) -> Result<String> {
    let client = reqwest::Client::new();
    let params = [
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", redirect_uri),
        ("code_challenge", code_challenge),
        ("code_challenge_method", "S256"),
        ("scope", "atproto transition:generic"),
        ("state", state),
        ("login_hint", login_hint),
    ];
    let dpop_proof = dpop_key.proof("POST", par_endpoint, None, None)?;
    let resp = client
        .post(par_endpoint)
        .header("DPoP", &dpop_proof)
        .form(&params)
        .send()
        .await
        .context("PAR request failed")?;
    let status = resp.status();
    let dpop_nonce = resp
        .headers()
        .get("dpop-nonce")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    if status.as_u16() == 400
        && let Some(ref nonce) = dpop_nonce
    {
        let dpop_proof_retry = dpop_key.proof("POST", par_endpoint, Some(nonce), None)?;
        let resp2 = client
            .post(par_endpoint)
            .header("DPoP", &dpop_proof_retry)
            .form(&params)
            .send()
            .await
            .context("PAR retry request failed")?;
        if !resp2.status().is_success() {
            let status = resp2.status();
            let text = resp2.text().await.unwrap_or_default();
            bail!("PAR failed ({status}): {text}");
        }
        let par_resp: serde_json::Value = resp2.json().await?;
        let request_uri = par_resp["request_uri"]
            .as_str()
            .context("No request_uri in PAR response")?;
        return Ok(format!(
            "{authorization_endpoint}?client_id={}&request_uri={}",
            urlencode(client_id),
            urlencode(request_uri),
        ));
    }
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        bail!("PAR failed ({status}): {text}");
    }
    let par_resp: serde_json::Value = resp.json().await?;
    let request_uri = par_resp["request_uri"]
        .as_str()
        .context("No request_uri in PAR response")?;
    Ok(format!(
        "{authorization_endpoint}?client_id={}&request_uri={}",
        urlencode(client_id),
        urlencode(request_uri),
    ))
}

async fn wait_for_callback(listener: TcpListener, expected_state: &str) -> Result<String> {
    loop {
        let (mut stream, _) = listener.accept().await?;
        let mut buf = vec![0u8; 4096];
        let n = stream.read(&mut buf).await.unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let path = req
            .lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .unwrap_or("/");
        if let Some(query) = path.split('?').nth(1) {
            let mut code = None;
            let mut state = None;
            for pair in query.split('&') {
                if let Some((k, v)) = pair.split_once('=') {
                    match k {
                        "code" => code = Some(v.to_string()),
                        "state" => state = Some(v.to_string()),
                        _ => {}
                    }
                }
            }
            if state.as_deref() == Some(expected_state)
                && let Some(code) = code
            {
                let body =
                    "<html><body><h1>Signed in</h1><p>You can close this window.</p></body></html>";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                return Ok(code);
            }
        }
        let body = "bad request";
        let resp = format!(
            "HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(resp.as_bytes()).await;
    }
}

async fn exchange_code(
    token_endpoint: &str,
    code: &str,
    code_verifier: &str,
    redirect_uri: &str,
    client_id: &str,
    dpop_key: &DpopKey,
) -> Result<(String, Option<String>)> {
    let client = reqwest::Client::new();
    let params = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", redirect_uri),
        ("client_id", client_id),
        ("code_verifier", code_verifier),
    ];
    let dpop_proof = dpop_key.proof("POST", token_endpoint, None, None)?;
    let resp = client
        .post(token_endpoint)
        .header("DPoP", &dpop_proof)
        .form(&params)
        .send()
        .await
        .context("Token exchange request failed")?;
    let status = resp.status();
    let dpop_nonce = resp
        .headers()
        .get("dpop-nonce")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    if (status.as_u16() == 400 || status.as_u16() == 401)
        && let Some(ref nonce) = dpop_nonce
    {
        let dpop_proof_retry = dpop_key.proof("POST", token_endpoint, Some(nonce), None)?;
        let resp2 = client
            .post(token_endpoint)
            .header("DPoP", &dpop_proof_retry)
            .form(&params)
            .send()
            .await
            .context("Token exchange retry failed")?;
        if !resp2.status().is_success() {
            let status = resp2.status();
            let text = resp2.text().await.unwrap_or_default();
            bail!("Token exchange failed ({status}): {text}");
        }
        let token_resp: TokenResponse = resp2
            .json()
            .await
            .context("Failed to parse token response")?;
        return Ok((token_resp.access_token, token_resp.sub));
    }
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        bail!("Token exchange failed ({status}): {text}");
    }
    let token_resp: TokenResponse = resp
        .json()
        .await
        .context("Failed to parse token response")?;
    Ok((token_resp.access_token, token_resp.sub))
}

async fn probe_dpop_nonce(pds_url: &str, access_token: &str, dpop_key: &DpopKey) -> Option<String> {
    let client = reqwest::Client::new();
    let url = format!(
        "{}/xrpc/com.atproto.server.getSession",
        pds_url.trim_end_matches('/')
    );
    let proof = dpop_key.proof("GET", &url, None, Some(access_token)).ok()?;
    let resp = client
        .get(&url)
        .header("Authorization", format!("DPoP {access_token}"))
        .header("DPoP", &proof)
        .send()
        .await
        .ok()?;
    resp.headers()
        .get("dpop-nonce")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

fn generate_pkce() -> (String, String) {
    let verifier = generate_random_string(32);
    let hash = Sha256::digest(verifier.as_bytes());
    let challenge = URL_SAFE_NO_PAD.encode(hash);
    (verifier, challenge)
}

fn generate_random_string(len: usize) -> String {
    use rand::RngCore;
    let mut bytes = vec![0u8; len];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(&bytes)
}

fn urlencode(s: &str) -> String {
    let mut result = String::with_capacity(s.len() * 2);
    for byte in s.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char);
            }
            _ => {
                result.push_str(&format!("%{:02X}", byte));
            }
        }
    }
    result
}
