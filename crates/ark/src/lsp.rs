//
// mod.rs
//
// Copyright (C) 2022-2024 Posit Software, PBC. All rights reserved.
//
//

pub mod backend;
#[path = "../../ark-lsp-core/src/lsp/capabilities.rs"]
pub mod capabilities;
#[path = "../../ark-lsp-core/src/lsp/code_action/mod.rs"]
pub mod code_action;
#[path = "../../ark-lsp-core/src/lsp/comm.rs"]
pub mod comm;
#[path = "../../ark-lsp-core/src/lsp/completions/mod.rs"]
pub mod completions;
#[path = "../../ark-lsp-core/src/lsp/config.rs"]
mod config;
#[path = "../../ark-lsp-core/src/lsp/declarations.rs"]
mod declarations;
#[path = "../../ark-lsp-core/src/lsp/definitions.rs"]
pub mod definitions;
#[path = "../../ark-lsp-core/src/lsp/diagnostics.rs"]
pub mod diagnostics;
#[path = "../../ark-lsp-core/src/lsp/diagnostics_syntax.rs"]
pub mod diagnostics_syntax;
#[path = "../../ark-lsp-core/src/lsp/document.rs"]
pub mod document;
#[path = "../../ark-lsp-core/src/lsp/document_context.rs"]
pub mod document_context;
#[path = "../../ark-lsp-core/src/lsp/folding_range.rs"]
pub mod folding_range;
#[path = "../../ark-lsp-core/src/lsp/handler.rs"]
pub mod handler;
#[path = "../../ark-lsp-core/src/lsp/handlers.rs"]
pub mod handlers;
#[path = "../../ark-lsp-core/src/lsp/help.rs"]
pub mod help;
#[path = "../../ark-lsp-core/src/lsp/help_topic.rs"]
pub mod help_topic;
#[path = "../../ark-lsp-core/src/lsp/hover.rs"]
pub mod hover;
#[path = "../../ark-lsp-core/src/lsp/indent.rs"]
pub mod indent;
#[path = "../../ark-lsp-core/src/lsp/indexer.rs"]
pub mod indexer;
#[path = "../../ark-lsp-core/src/lsp/input_boundaries.rs"]
pub mod input_boundaries;
#[path = "../../ark-lsp-core/src/lsp/inputs/mod.rs"]
pub mod inputs;
pub mod main_loop;
#[path = "../../ark-lsp-core/src/lsp/markdown.rs"]
pub mod markdown;

#[path = "../../ark-lsp-core/src/lsp/references.rs"]
pub mod references;
#[path = "../../ark-lsp-core/src/lsp/selection_range.rs"]
pub mod selection_range;
#[path = "../../ark-lsp-core/src/lsp/session_bridge.rs"]
pub mod session_bridge;
#[path = "../../ark-lsp-core/src/lsp/signature_help.rs"]
pub mod signature_help;
#[path = "../../ark-lsp-core/src/lsp/state.rs"]
pub mod state;
pub mod state_handlers;
#[path = "../../ark-lsp-core/src/lsp/statement_range.rs"]
pub mod statement_range;
#[path = "../../ark-lsp-core/src/lsp/symbols.rs"]
pub mod symbols;
#[path = "../../ark-lsp-core/src/lsp/util.rs"]
pub mod util;
pub use ark_lsp_support::events;
pub use ark_lsp_support::notifications;
pub use ark_lsp_support::traits;

// These send LSP messages in a non-async and non-blocking way.
// The LOG level is not timestamped so we're not using it.
macro_rules! log_info {
    ($($arg:tt)+) => ($crate::lsp::_log!(tower_lsp::lsp_types::MessageType::INFO, $($arg)+))
}
macro_rules! log_warn {
    ($($arg:tt)+) => ($crate::lsp::_log!(tower_lsp::lsp_types::MessageType::WARNING, $($arg)+))
}
macro_rules! log_error {
    ($($arg:tt)+) => ($crate::lsp::_log!(tower_lsp::lsp_types::MessageType::ERROR, $($arg)+))
}
macro_rules! _log {
    ($lvl:expr, $($arg:tt)+) => ({
        $crate::lsp::main_loop::log($lvl, format!($($arg)+));
    });
}

pub(crate) use _log;
pub(crate) use log_error;
pub(crate) use log_info;
pub(crate) use log_warn;
pub(crate) use main_loop::diagnostics_refresh_all_from_state as diagnostics_refresh_all;
pub(crate) use main_loop::publish_diagnostics;
pub(crate) use main_loop::spawn_blocking;
