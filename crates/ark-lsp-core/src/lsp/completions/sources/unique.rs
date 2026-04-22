//
// unique.rs
//
// Copyright (C) 2023-2025 Posit Software, PBC. All rights reserved.
//
//

mod colon;
mod comment;
mod custom;
mod extractor;
mod file_path;
mod frontmatter;
mod namespace;
mod string;
mod subset;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::plan::UniqueSourceKind;
use crate::lsp::completions::plan::UniqueSourcePlan;
use crate::lsp::completions::sources::collect_completions;
use crate::lsp::completions::sources::unique::colon::SingleColonSource;
use crate::lsp::completions::sources::unique::comment::CommentSource;
use crate::lsp::completions::sources::unique::custom::CustomSource;
use crate::lsp::completions::sources::unique::extractor::AtSource;
use crate::lsp::completions::sources::unique::extractor::DollarSource;
use crate::lsp::completions::sources::unique::frontmatter::FrontmatterSource;
use crate::lsp::completions::sources::unique::namespace::NamespaceSource;
use crate::lsp::completions::sources::unique::string::StringSource;
use crate::lsp::completions::sources::CompletionSource;

fn collect_source_plan<S>(
    kind: UniqueSourceKind,
    source: S,
    completion_context: &CompletionContext,
) -> anyhow::Result<Option<UniqueSourcePlan>>
where
    S: CompletionSource,
{
    Ok(collect_completions(source, completion_context)?
        .map(|items| UniqueSourcePlan { kind, items }))
}

pub(crate) fn first_matching_source_plan(
    completion_context: &CompletionContext,
) -> anyhow::Result<Option<UniqueSourcePlan>> {
    log::info!("Getting completions from unique sources");

    // Try to detect a single colon first, which is a special case where we
    // don't provide any completions
    if let Some(plan) = collect_source_plan(
        UniqueSourceKind::SingleColon,
        SingleColonSource,
        completion_context,
    )? {
        return Ok(Some(plan));
    }

    if let Some(plan) = collect_source_plan(
        UniqueSourceKind::Frontmatter,
        FrontmatterSource,
        completion_context,
    )? {
        return Ok(Some(plan));
    }

    // really about roxygen2 tags
    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::Comment, CommentSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    // could be a file path
    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::String, StringSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    // pkg::xxx or pkg:::xxx
    if let Some(plan) = collect_source_plan(
        UniqueSourceKind::Namespace,
        NamespaceSource,
        completion_context,
    )? {
        return Ok(Some(plan));
    }

    // custom completions for, e.g., options or env vars
    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::Custom, CustomSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    // as in foo$bar
    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::Dollar, DollarSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    // as in foo@bar
    if let Some(plan) = collect_source_plan(UniqueSourceKind::At, AtSource, completion_context)? {
        return Ok(Some(plan));
    }

    log::info!("No unique source provided completions");
    Ok(None)
}

pub(crate) fn first_detached_static_source_plan(
    completion_context: &CompletionContext,
) -> anyhow::Result<Option<UniqueSourcePlan>> {
    if let Some(plan) = collect_source_plan(
        UniqueSourceKind::SingleColon,
        SingleColonSource,
        completion_context,
    )? {
        return Ok(Some(plan));
    }

    if let Some(plan) = collect_source_plan(
        UniqueSourceKind::Frontmatter,
        FrontmatterSource,
        completion_context,
    )? {
        return Ok(Some(plan));
    }

    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::Comment, CommentSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    if let Some(plan) =
        collect_source_plan(UniqueSourceKind::String, StringSource, completion_context)?
    {
        return Ok(Some(plan));
    }

    Ok(None)
}

/// Each unique source is tried in order until one returns completions
#[cfg(test)]
pub(crate) fn get_completions(
    completion_context: &CompletionContext,
) -> anyhow::Result<Option<Vec<tower_lsp::lsp_types::CompletionItem>>> {
    Ok(first_matching_source_plan(completion_context)?.map(|plan| plan.items))
}
