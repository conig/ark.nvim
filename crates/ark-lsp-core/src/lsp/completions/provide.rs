//
// provide.rs
//
// Copyright (C) 2023-2025 Posit Software, PBC. All rights reserved.
//
//

use tower_lsp::lsp_types::CompletionItem;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::plan::plan_completions;
use crate::lsp::completions::plan::plan_detached_static_completions;
use crate::lsp::completions::plan::CompletionPlan;
use crate::lsp::completions::sources::composite;
use crate::lsp::completions::sources::unique;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::state::WorldState;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::NodeTypeExt;

// Entry point for completions.
// Must be within an `r_task()`.
pub(crate) fn provide_completions(
    document_context: &DocumentContext,
    state: &WorldState,
) -> anyhow::Result<Vec<CompletionItem>> {
    log::info!(
        "provide_completions() - Completion node text: '{node_text}', Node type: '{node_type:?}'",
        node_text = document_context
            .node
            .node_as_str(&document_context.document.contents)
            .unwrap_or_default(),
        node_type = document_context.node.node_type()
    );

    let completion_context = CompletionContext::new(document_context, state);
    match plan_completions(&completion_context)? {
        CompletionPlan::HandledEmpty => Ok(vec![]),
        CompletionPlan::Unique(plan) => Ok(plan.items),
        CompletionPlan::Composite(plan) => Ok(composite::get_completions_from_kinds(
            &plan.kinds,
            &completion_context,
        )?
        .unwrap_or_default()),
    }
}

pub(crate) fn provide_detached_pre_bridge_completions(
    document_context: &DocumentContext,
    state: &WorldState,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    // Static package metadata contains only exports. Let `pkg:::member` go to
    // the managed R session, which can enumerate namespace internals. The
    // later static fallback still claims this context with an empty result
    // when a session bridge is unavailable.
    if unique::is_internal_namespace_member_completion(document_context) {
        return Ok(None);
    }

    let completion_context = CompletionContext::new(document_context, state);
    match plan_detached_static_completions(&completion_context)? {
        CompletionPlan::HandledEmpty => Ok(Some(vec![])),
        CompletionPlan::Unique(plan) if plan.kind.is_detached_pre_bridge() => Ok(Some(plan.items)),
        _ => Ok(None),
    }
}

pub(crate) fn has_detached_static_path_completion_context(
    document_context: &DocumentContext,
    state: &WorldState,
) -> bool {
    let completion_context = CompletionContext::new(document_context, state);
    unique::string_path_preempts_bridge(&completion_context)
}

pub(crate) fn provide_detached_post_bridge_completions(
    document_context: &DocumentContext,
    state: &WorldState,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    let completion_context = CompletionContext::new(document_context, state);
    match plan_detached_static_completions(&completion_context)? {
        CompletionPlan::Unique(plan) if plan.kind.is_detached_post_bridge() => Ok(Some(plan.items)),
        _ => Ok(None),
    }
}

pub(crate) fn provide_detached_static_completions(
    document_context: &DocumentContext,
    state: &WorldState,
) -> anyhow::Result<Vec<CompletionItem>> {
    let completion_context = CompletionContext::new(document_context, state);
    match plan_detached_static_completions(&completion_context)? {
        CompletionPlan::HandledEmpty => Ok(vec![]),
        CompletionPlan::Composite(plan) => Ok(composite::get_completions_from_kinds(
            &plan.detached_static_kinds(),
            &completion_context,
        )?
        .unwrap_or_default()),
        CompletionPlan::Unique(_) => Ok(vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::document::Document;
    use crate::lsp::state::RuntimeMode;

    #[test]
    fn test_detached_internal_namespace_completion_defers_to_bridge_but_static_fallback_is_empty() {
        let (text, point) = point_from_cursor("utils:::as.bibentry@");
        let document = Document::new(&text, None);
        let document_context = DocumentContext::new(&document, point, None);
        let state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            ..Default::default()
        };

        let pre_bridge = provide_detached_pre_bridge_completions(&document_context, &state)
            .expect("expected pre-bridge completion result");
        assert!(pre_bridge.is_none());

        let fallback = provide_detached_static_completions(&document_context, &state)
            .expect("expected static completion result");
        assert!(fallback.is_empty());
    }
}
