//! `freeq-verify` — offline verifier for a channel evidence bundle.
//!
//! Reads a bundle JSON (as produced by the `/api/v1/channels/{name}/evidence`
//! export endpoint), and checks two things with no server contact:
//!
//! 1. **Bundle integrity** — the server's signature over the canonical bundle
//!    (every field except `bundle_signature`), proving the export wasn't altered.
//! 2. **Per-message authenticity** — each message's client signature over
//!    `{sender_did}\0{channel}\0{text}\0{timestamp}`, using the client public key
//!    carried in `did_keys`.
//!
//! Prints a human summary and exits 0 only if everything verifies. On any failure
//! it prints `INVALID`/`TAMPERED` (to stdout, so tooling can scrape it) and exits 1.
//!
//! Usage: `freeq-verify [--verbose] <bundle.json>`

use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use std::process::exit;

fn b64() -> base64::engine::general_purpose::GeneralPurpose {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
}

fn decode_key(s: &str) -> Result<VerifyingKey, String> {
    let bytes = b64().decode(s).map_err(|e| format!("bad base64 public key: {e}"))?;
    let arr: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| "public key is not 32 bytes".to_string())?;
    VerifyingKey::from_bytes(&arr).map_err(|e| format!("not a valid ed25519 key: {e}"))
}

fn decode_sig(s: &str) -> Result<Signature, String> {
    let bytes = b64().decode(s).map_err(|e| format!("bad base64 signature: {e}"))?;
    let arr: [u8; 64] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| "signature is not 64 bytes".to_string())?;
    Ok(Signature::from_bytes(&arr))
}

fn field<'a>(v: &'a serde_json::Value, key: &str) -> Result<&'a str, String> {
    v.get(key)
        .and_then(|x| x.as_str())
        .ok_or_else(|| format!("missing string field `{key}`"))
}

fn verify(bundle: &serde_json::Value, verbose: bool) -> Result<(), String> {
    // 1. Bundle integrity: server signature over the canonical bundle sans the
    //    signature field itself (the exact bytes the exporter signed).
    let server_key = decode_key(field(bundle, "server_public_key")?)?;
    let bundle_sig = decode_sig(field(bundle, "bundle_signature")?)?;
    let mut unsigned = bundle.clone();
    unsigned
        .as_object_mut()
        .ok_or("bundle is not a JSON object")?
        .remove("bundle_signature");
    let canonical =
        freeq_sdk::canonical::canonicalize(&unsigned).map_err(|e| format!("canonicalize: {e}"))?;
    server_key
        .verify(canonical.as_bytes(), &bundle_sig)
        .map_err(|_| "bundle signature INVALID — the export was altered".to_string())?;
    if verbose {
        println!("bundle signature VERIFIED (server key)");
    }

    // 2. Per-message authenticity: each client signature over the message canonical.
    let did_keys = bundle
        .get("did_keys")
        .and_then(|v| v.as_object())
        .ok_or("missing object field `did_keys`")?;
    let messages = bundle
        .get("messages")
        .and_then(|v| v.as_array())
        .ok_or("missing array field `messages`")?;
    for (i, m) in messages.iter().enumerate() {
        let did = field(m, "sender_did")?;
        let channel = field(m, "channel")?;
        let text = field(m, "text")?;
        let ts = m
            .get("timestamp")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| format!("message {i}: missing integer field `timestamp`"))?;
        let sig = decode_sig(field(m, "signature")?)?;
        let key_b64 = did_keys
            .get(did)
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("message {i}: no public key in did_keys for {did}"))?;
        let client_key = decode_key(key_b64)?;
        let msg_canonical = format!("{did}\0{channel}\0{text}\0{ts}");
        client_key
            .verify(msg_canonical.as_bytes(), &sig)
            .map_err(|_| format!("message {i} ({did}): TAMPERED — signature does not verify"))?;
        if verbose {
            println!("message {i} ({did}): VERIFIED (client key)");
        }
    }
    Ok(())
}

fn main() {
    let mut verbose = false;
    let mut path: Option<String> = None;
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--verbose" | "-v" => verbose = true,
            _ => path = Some(arg),
        }
    }
    let Some(path) = path else {
        eprintln!("usage: freeq-verify [--verbose] <bundle.json>");
        exit(2);
    };

    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(e) => {
            println!("cannot read {path}: {e}");
            exit(1);
        }
    };
    let bundle: serde_json::Value = match serde_json::from_str(&data) {
        Ok(v) => v,
        Err(e) => {
            println!("INVALID — not valid JSON: {e}");
            exit(1);
        }
    };

    match verify(&bundle, verbose) {
        Ok(()) => {
            let count = bundle
                .get("messages")
                .and_then(|v| v.as_array())
                .map(|a| a.len())
                .unwrap_or(0);
            println!("✓ VERIFIED — bundle intact, {count} message(s) authentic");
        }
        Err(msg) => {
            println!("{msg}");
            exit(1);
        }
    }
}
