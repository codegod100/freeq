//! freeq-bots: AI agent platform for freeq IRC.
//!
//! Provides LLM-powered bots that perform real, observable work:
//! - Software Factory: multi-agent development team
//! - Architecture Auditor: repo analysis and recommendations
//! - Spec-to-Prototype: idea → deployed app in minutes

pub mod auditor;
pub mod context;
pub mod factory;
pub mod llm;
pub mod memory;
pub mod output;
pub mod prototype;
pub mod tools;
