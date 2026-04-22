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
    let completion_context = CompletionContext::new(document_context, state);
    match plan_detached_static_completions(&completion_context)? {
        CompletionPlan::Unique(plan) if plan.kind.is_detached_pre_bridge() => Ok(Some(plan.items)),
        _ => Ok(None),
    }
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
