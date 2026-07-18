//! LLM-backed structured-understanding layer for the agent assistance
//! interface.
//!
//! ## What this layer does (and doesn't)
//!
//! This is **not** a chat layer. The model's job is to parse messy,
//! ambiguously-shaped agent input into a structured tool call:
//!
//! - "After reconnect msg X comes before msg Y" → `diagnose_message_ordering`
//!   with `{channel, message_ids: [X, Y]}` extracted from the prose.
//! - "Here's my client manifest [json] — does this match the spec?"
//!   → `validate_client_config` with the embedded JSON extracted into
//!   the typed `ClientSupports` struct, then validated by the
//!   deterministic tool.
//!
//! The deterministic tools in [`super::tools`] are still the source of
//! truth for diagnosis logic. The LLM is a flexible adapter from
//! free-form input to typed tool input.
//!
//! ## Pluggable providers
//!
//! [`LlmProvider`] is a small trait with two methods. Implementations:
//!
//! - [`openai::OpenAiCompatible`] — works with **any** server that
//!   exposes an OpenAI-style `/chat/completions` endpoint: OpenAI,
//!   Together, Fireworks, Groq, Anyscale, vLLM, llama.cpp server,
//!   Ollama (with the OpenAI compat layer), TGI, LMDeploy, etc.
//! - [`mock::MockProvider`] — deterministic regex-based fallback. Lets
//!   the `/agent/session` endpoint work without a network or API key,
//!   and lets tests assert routing behaviour.
//!
//! Choice of provider is wired at server boot (env-driven) into a
//! process-wide [`global`] slot. Tests inject directly via
//! [`global::set_provider`].
//!
//! ## Safety properties enforced here
//!
//! - The LLM is given the user's raw message inside a `<user_message>`
//!   delimiter, never as system instructions. Caller content cannot
//!   change the system prompt.
//! - The model returns a strict JSON object. Unparseable output, or
//!   output that picks an unknown tool, downgrades to the
//!   `INTENT_UNCLEAR` diagnosis — never to a tool execution.
//! - The model never sees server state. It sees the message, an
//!   advertised list of tool names + descriptions, and the caller's
//!   coarse permission tier.

pub mod mock;
pub mod openai;
pub mod prompts;
pub mod router;

use super::types::{Confidence, FactBundle};
use serde::{Deserialize, Serialize};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// Convenience: `dyn`-compatible boxed future.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

// ─── Types ───────────────────────────────────────────────────────────────

/// Description of a tool advertised to the model.
///
/// `args_hint` is a brief, human-readable schema sketch (not JSON
/// Schema) that the model sees in the system prompt to know what to
/// extract into `ToolIntent::args`.
#[derive(Debug, Clone, Serialize)]
pub struct ToolDescriptor {
    pub name: String,
    pub description: String,
    pub args_hint: String,
}

/// Context passed to the model for classification.
#[derive(Debug, Clone, Serialize)]
pub struct ClassificationContext {
    pub available_tools: Vec<ToolDescriptor>,
    /// Coarse caller tier as a lowercase string. The model uses this to
    /// decide whether a tool is reachable, not to enforce permissions
    /// (the deterministic layer does that).
    pub caller_tier: &'static str,
}

/// Structured intent extracted from the agent's free-form message.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ToolIntent {
    /// Tool name. Validated against the advertised list before any
    /// execution; an unknown name short-circuits to `INTENT_UNCLEAR`.
    pub tool: String,
    /// Args extracted from the message. Validated by the tool's typed
    /// input struct (`serde_json::from_value::<TypedInput>`) before
    /// the tool runs. Invalid args also short-circuit.
    pub args: serde_json::Value,
    /// Model's self-reported confidence.
    #[serde(default = "default_confidence")]
    pub confidence: Confidence,
    /// Brief one-line description of what the model thinks the user is
    /// asking. Surfaced to the caller alongside the diagnosis so the
    /// agent knows which tool ran and why.
    #[serde(default)]
    pub summary: Option<String>,
}

fn default_confidence() -> Confidence {
    Confidence::Low
}

/// Errors a provider can raise. Always recoverable — the router turns
/// them into `INTENT_UNCLEAR`, never a 500.
#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("provider not configured")]
    NotConfigured,
    #[error("provider transport error: {0}")]
    Transport(String),
    #[error("provider timeout after {0}s")]
    Timeout(u64),
    #[error("provider returned unparseable response: {0}")]
    Unparseable(String),
}

// ─── Trait ───────────────────────────────────────────────────────────────

/// Pluggable LLM provider.
///
/// Implementors return `Ok(None)` when the model declined to classify
/// (low confidence, off-topic, etc.) — that's a different signal from
/// a transport error.
pub trait LlmProvider: Send + Sync {
    /// Short identifier shown in audit logs and the discovery payload.
    fn name(&self) -> &str;

    /// Parse a free-form agent message into a structured tool call.
    fn classify_intent<'a>(
        &'a self,
        message: &'a str,
        ctx: &'a ClassificationContext,
    ) -> BoxFuture<'a, Result<Option<ToolIntent>, LlmError>>;

    /// Optionally refine a deterministic [`FactBundle::summary`] into
    /// a friendlier sentence. Implementations may return `Ok(None)` to
    /// keep the deterministic summary verbatim. The model only ever
    /// sees `bundle.safe_facts` — never raw server state.
    fn refine_summary<'a>(
        &'a self,
        bundle: &'a FactBundle,
    ) -> BoxFuture<'a, Result<Option<String>, LlmError>>;
}

// ─── Process-wide pluggable slot ─────────────────────────────────────────

/// Global slot for the active provider. Initialized at server boot from
/// env config; tests may override.
pub mod global {
    use super::LlmProvider;
    use parking_lot::RwLock;
    use std::sync::{Arc, LazyLock};

    static PROVIDER: LazyLock<RwLock<Option<Arc<dyn LlmProvider>>>> =
        LazyLock::new(|| RwLock::new(None));

    /// Install a provider. Replaces any previous one.
    pub fn set_provider(provider: Arc<dyn LlmProvider>) {
        *PROVIDER.write() = Some(provider);
    }

    /// Clear the active provider (back to "not configured" behaviour).
    pub fn clear_provider() {
        *PROVIDER.write() = None;
    }

    /// Snapshot the current provider, if any.
    pub fn provider() -> Option<Arc<dyn LlmProvider>> {
        PROVIDER.read().clone()
    }

    /// True if a provider is configured. Cheap; doesn't take an Arc.
    pub fn is_configured() -> bool {
        PROVIDER.read().is_some()
    }
}

/// Helper: fetch a provider or yield a structured `NotConfigured` error.
pub fn require() -> Result<Arc<dyn LlmProvider>, LlmError> {
    global::provider().ok_or(LlmError::NotConfigured)
}
