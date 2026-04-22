use tower_lsp::lsp_types::CompletionItem;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::sources::composite;
use crate::lsp::completions::sources::unique;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum UniqueSourceKind {
    SingleColon,
    Frontmatter,
    Comment,
    String,
    Namespace,
    Custom,
    Dollar,
    At,
}

impl UniqueSourceKind {
    pub(crate) fn is_detached_pre_bridge(self) -> bool {
        matches!(self, Self::SingleColon | Self::Frontmatter | Self::Comment)
    }

    pub(crate) fn is_detached_post_bridge(self) -> bool {
        matches!(self, Self::String)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CompositeSourceKind {
    Call,
    Pipe,
    Subset,
    Keyword,
    SearchPath,
    Document,
    Workspace,
}

impl CompositeSourceKind {
    pub(crate) fn is_detached_static(self) -> bool {
        matches!(self, Self::Keyword | Self::Document | Self::Workspace)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct UniqueSourcePlan {
    pub(crate) kind: UniqueSourceKind,
    pub(crate) items: Vec<CompletionItem>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct CompositeSourcePlan {
    pub(crate) kinds: Vec<CompositeSourceKind>,
}

impl CompositeSourcePlan {
    pub(crate) fn detached_static_kinds(&self) -> Vec<CompositeSourceKind> {
        self.kinds
            .iter()
            .copied()
            .filter(|kind| kind.is_detached_static())
            .collect()
    }
}

#[derive(Clone, Debug)]
pub(crate) enum CompletionPlan {
    HandledEmpty,
    Unique(UniqueSourcePlan),
    Composite(CompositeSourcePlan),
}

pub(crate) fn plan_completions(
    completion_context: &CompletionContext,
) -> anyhow::Result<CompletionPlan> {
    if completion_context
        .document_context
        .is_empty_assignment_rhs()
    {
        return Ok(CompletionPlan::HandledEmpty);
    }

    if let Some(plan) = unique::first_matching_source_plan(completion_context)? {
        return Ok(CompletionPlan::Unique(plan));
    }

    Ok(CompletionPlan::Composite(CompositeSourcePlan {
        kinds: composite::composite_source_kinds(completion_context),
    }))
}

pub(crate) fn plan_detached_static_completions(
    completion_context: &CompletionContext,
) -> anyhow::Result<CompletionPlan> {
    if completion_context
        .document_context
        .is_empty_assignment_rhs()
    {
        return Ok(CompletionPlan::HandledEmpty);
    }

    if let Some(plan) = unique::first_detached_static_source_plan(completion_context)? {
        return Ok(CompletionPlan::Unique(plan));
    }

    Ok(CompletionPlan::Composite(CompositeSourcePlan {
        kinds: composite::composite_source_kinds(completion_context),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::document::Document;
    use crate::lsp::document::DocumentKind;
    use crate::lsp::document_context::DocumentContext;
    use crate::lsp::state::WorldState;

    #[test]
    fn test_plan_handles_empty_assignment_rhs() {
        let (text, point) = point_from_cursor("x <- @");
        let document = Document::new(text.as_str(), None);
        let document_context = DocumentContext::new(&document, point, None);
        let state = WorldState::default();
        let completion_context = CompletionContext::new(&document_context, &state);

        let plan = plan_completions(&completion_context).unwrap();

        assert!(matches!(plan, CompletionPlan::HandledEmpty));
    }

    #[test]
    fn test_plan_routes_frontmatter_to_unique_source() {
        let (text, point) = point_from_cursor("---\noutput: html_document@\n---\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let document_context = DocumentContext::new(&document, point, Some(String::from("t")));
        let state = WorldState::default();
        let completion_context = CompletionContext::new(&document_context, &state);

        let plan = plan_completions(&completion_context).unwrap();
        let CompletionPlan::Unique(plan) = plan else {
            panic!("expected frontmatter completion to route to a unique source");
        };

        assert_eq!(plan.kind, UniqueSourceKind::Frontmatter);
        assert!(plan.kind.is_detached_pre_bridge());
    }

    #[test]
    fn test_plan_filters_detached_static_composite_sources() {
        let (text, point) = point_from_cursor("n@");
        let document = Document::new(text.as_str(), None);
        let document_context = DocumentContext::new(&document, point, None);
        let state = WorldState::default();
        let completion_context = CompletionContext::new(&document_context, &state);

        let plan = plan_completions(&completion_context).unwrap();
        let CompletionPlan::Composite(plan) = plan else {
            panic!("expected identifier completion to route to composite sources");
        };

        assert_eq!(plan.kinds, vec![
            CompositeSourceKind::Call,
            CompositeSourceKind::Pipe,
            CompositeSourceKind::Subset,
            CompositeSourceKind::Keyword,
            CompositeSourceKind::SearchPath,
            CompositeSourceKind::Document,
            CompositeSourceKind::Workspace,
        ]);
        assert_eq!(plan.detached_static_kinds(), vec![
            CompositeSourceKind::Keyword,
            CompositeSourceKind::Document,
            CompositeSourceKind::Workspace,
        ]);
    }

    #[test]
    fn test_detached_static_plan_does_not_claim_extractor_context() {
        let (text, point) = point_from_cursor("foo$@");
        let document = Document::new(text.as_str(), None);
        let document_context = DocumentContext::new(&document, point, Some(String::from("$")));
        let state = WorldState::default();
        let completion_context = CompletionContext::new(&document_context, &state);

        let plan = plan_detached_static_completions(&completion_context).unwrap();

        assert!(matches!(plan, CompletionPlan::Composite(_)));
    }
}
