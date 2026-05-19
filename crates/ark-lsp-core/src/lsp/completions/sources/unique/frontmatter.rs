use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::CompletionTextEdit;
use tower_lsp::lsp_types::Documentation;
use tower_lsp::lsp_types::MarkupContent;
use tower_lsp::lsp_types::MarkupKind;
use tower_lsp::lsp_types::Range as LspRange;
use tower_lsp::lsp_types::TextEdit;
use tree_sitter::Point;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::CompletionData;
use crate::lsp::document::DocumentKind;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::frontmatter::frontmatter_output_value_edit_range;

const BUILTIN_OUTPUTS: &[BuiltinOutput] = &[
    BuiltinOutput {
        output: "html_document",
        name: "HTML Document",
        description: "Basic HTML report.",
    },
    BuiltinOutput {
        output: "pdf_document",
        name: "PDF Document",
        description: "Basic PDF report.",
    },
    BuiltinOutput {
        output: "word_document",
        name: "Word Document",
        description: "Basic Word report.",
    },
    BuiltinOutput {
        output: "beamer_presentation",
        name: "Beamer Presentation",
        description: "Basic Beamer slides.",
    },
    BuiltinOutput {
        output: "ioslides_presentation",
        name: "ioslides Presentation",
        description: "Basic ioslides deck.",
    },
    BuiltinOutput {
        output: "slidy_presentation",
        name: "Slidy Presentation",
        description: "Basic Slidy deck.",
    },
];

#[derive(Clone, Copy)]
struct BuiltinOutput {
    output: &'static str,
    name: &'static str,
    description: &'static str,
}

pub(super) struct FrontmatterSource;

impl CompletionSource for FrontmatterSource {
    fn name(&self) -> &'static str {
        "frontmatter"
    }

    fn provide_completions(
        &self,
        completion_context: &CompletionContext,
    ) -> anyhow::Result<Option<Vec<CompletionItem>>> {
        completions_from_frontmatter_output(completion_context.document_context)
    }
}

fn completions_from_frontmatter_output(
    context: &DocumentContext,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    if context.document.kind != DocumentKind::LiterateR {
        return Ok(None);
    }

    let Some(edit_range) = frontmatter_output_value_edit_range(context.document, context.point)
    else {
        return Ok(None);
    };

    if builtin_output_from_value(&edit_range.value).is_some() {
        return Ok(Some(vec![]));
    }

    let mut completions = Vec::with_capacity(BUILTIN_OUTPUTS.len());
    for builtin in BUILTIN_OUTPUTS {
        completions.push(completion_item_from_builtin_output(
            builtin,
            context,
            edit_range.start,
            edit_range.end,
            edit_range.needs_leading_space,
        )?);
    }

    Ok(Some(completions))
}

fn builtin_output_from_value(value: &str) -> Option<&'static BuiltinOutput> {
    let trimmed = value.trim_end_matches(|ch: char| ch.is_ascii_whitespace());
    BUILTIN_OUTPUTS
        .iter()
        .find(|builtin| trimmed == builtin.output)
}

fn completion_item_from_builtin_output(
    builtin: &BuiltinOutput,
    context: &DocumentContext,
    start: Point,
    end: Point,
    needs_leading_space: bool,
) -> anyhow::Result<CompletionItem> {
    let output_ref = builtin.output.to_string();
    let mut item = completion_item(output_ref.clone(), CompletionData::Unknown)?;

    item.kind = Some(CompletionItemKind::MODULE);
    item.detail = Some(builtin.name.to_string());
    item.documentation = Some(Documentation::MarkupContent(MarkupContent {
        kind: MarkupKind::Markdown,
        value: builtin.description.to_string(),
    }));
    item.text_edit = Some(CompletionTextEdit::Edit(TextEdit {
        range: LspRange::new(
            context
                .document
                .lsp_position_from_tree_sitter_point(start)?,
            context.document.lsp_position_from_tree_sitter_point(end)?,
        ),
        new_text: if needs_leading_space {
            format!(" {output_ref}")
        } else {
            output_ref
        },
    }));

    Ok(item)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::completions::tests::utils::assert_text_edit;
    use crate::lsp::document::Document;

    fn frontmatter_output_completions(cursor_text: &str) -> Option<Vec<CompletionItem>> {
        let (text, point) = point_from_cursor(cursor_text);
        let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, None);
        completions_from_frontmatter_output(&context).unwrap()
    }

    #[test]
    fn test_frontmatter_output_completion_offers_builtin_starters() {
        let completions =
            frontmatter_output_completions("---\noutput: @\ntitle: \"Report\"\n---\n\nBody\n")
                .unwrap();
        let labels: Vec<&str> = completions.iter().map(|item| item.label.as_str()).collect();

        assert_eq!(labels, vec![
            "html_document",
            "pdf_document",
            "word_document",
            "beamer_presentation",
            "ioslides_presentation",
            "slidy_presentation",
        ]);

        let html = completions
            .iter()
            .find(|item| item.label == "html_document")
            .unwrap();

        assert_eq!(html.detail.as_deref(), Some("HTML Document"));
        assert_text_edit(html, "html_document");
    }

    #[test]
    fn test_frontmatter_output_completion_after_colon_inserts_leading_space() {
        let completions = frontmatter_output_completions("---\noutput:@\n---\n\nBody\n").unwrap();

        let html = completions
            .iter()
            .find(|item| item.label == "html_document")
            .unwrap();

        assert_text_edit(html, " html_document");

        match html.text_edit.as_ref().unwrap() {
            CompletionTextEdit::Edit(edit) => {
                assert_eq!(edit.range.start.line, 1);
                assert_eq!(edit.range.start.character, 7);
                assert_eq!(edit.range.end.line, 1);
                assert_eq!(edit.range.end.character, 7);
            },
            _ => panic!("Unexpected TextEdit variant"),
        }
    }

    #[test]
    fn test_frontmatter_output_completion_replaces_partial_prefix() {
        let completions =
            frontmatter_output_completions("---\noutput: ht@\n---\n\nBody\n").unwrap();

        let html = completions
            .iter()
            .find(|item| item.label == "html_document")
            .unwrap();

        assert_text_edit(html, "html_document");

        match html.text_edit.as_ref().unwrap() {
            CompletionTextEdit::Edit(edit) => {
                assert_eq!(edit.range.start.line, 1);
                assert_eq!(edit.range.start.character, 8);
                assert_eq!(edit.range.end.line, 1);
                assert_eq!(edit.range.end.character, 10);
            },
            _ => panic!("Unexpected TextEdit variant"),
        }
    }

    #[test]
    fn test_frontmatter_output_completion_ignores_non_output_keys() {
        assert!(
            frontmatter_output_completions("---\ntitle: @\noutput: html_document\n---\n").is_none()
        );
    }

    #[test]
    fn test_frontmatter_output_completion_ignores_body_lines() {
        assert!(
            frontmatter_output_completions("---\noutput: html_document\n---\n\n@body\n").is_none()
        );
    }

    #[test]
    fn test_frontmatter_output_completion_claims_exact_builtin_without_items() {
        let completions = frontmatter_output_completions("---\noutput: html_document@\n---\n");

        assert!(matches!(completions, Some(ref items) if items.is_empty()));
    }

    #[test]
    fn test_frontmatter_output_completion_claims_exact_builtin_with_trailing_space_without_items() {
        let completions = frontmatter_output_completions("---\noutput: html_document @\n---\n");

        assert!(matches!(completions, Some(ref items) if items.is_empty()));
    }
}
