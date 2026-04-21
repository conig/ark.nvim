use std::ops::Range;

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
use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;
use crate::lsp::document_context::DocumentContext;

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

    let row = context.point.row;
    let Some(frontmatter_rows) = frontmatter_row_range(context.document) else {
        return Ok(None);
    };

    if !frontmatter_rows.contains(&row) {
        return Ok(None);
    }

    let Some((start, end)) = output_value_edit_range(context)? else {
        return Ok(None);
    };

    let mut completions = Vec::with_capacity(BUILTIN_OUTPUTS.len());
    for builtin in BUILTIN_OUTPUTS {
        completions.push(completion_item_from_builtin_output(builtin, context, start, end)?);
    }

    Ok(Some(completions))
}

fn frontmatter_row_range(document: &Document) -> Option<Range<usize>> {
    let first = line_without_newline(document.get_line(0)?).trim();
    if first != "---" {
        return None;
    }

    let line_count: usize = document.line_index.len().try_into().ok()?;
    for row in 1..line_count {
        let line = line_without_newline(document.get_line(row)?).trim();
        if line == "---" || line == "..." {
            return Some(1..row);
        }
    }

    None
}

fn output_value_edit_range(
    context: &DocumentContext,
) -> anyhow::Result<Option<(Point, Point)>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };
    let line = line_without_newline(line);
    let trimmed = line.trim_start();
    let indent = line.len() - trimmed.len();

    let Some((key, after_colon)) = trimmed.split_once(':') else {
        return Ok(None);
    };
    if key.trim() != "output" {
        return Ok(None);
    }

    let value_prefix = after_colon.trim_start_matches(|ch: char| ch.is_ascii_whitespace());
    if value_prefix.starts_with('[') || value_prefix.starts_with('{') {
        return Ok(None);
    }

    let colon_index = trimmed.find(':').unwrap_or_default();
    let value_start = indent +
        colon_index +
        1 +
        (after_colon.len() - value_prefix.len());
    let value_end = context.point.column.min(line.len());

    if value_end < value_start {
        return Ok(None);
    }

    if line[value_start..value_end].contains(['[', ']', '{', '}', ',']) {
        return Ok(None);
    }

    Ok(Some((
        Point::new(context.point.row, value_start),
        Point::new(context.point.row, value_end),
    )))
}

fn completion_item_from_builtin_output(
    builtin: &BuiltinOutput,
    context: &DocumentContext,
    start: Point,
    end: Point,
) -> anyhow::Result<CompletionItem> {
    let package_ref = format!("rmarkdown::{}", builtin.output);
    let mut item = completion_item(package_ref.clone(), CompletionData::Unknown)?;

    item.kind = Some(CompletionItemKind::MODULE);
    item.detail = Some(builtin.name.to_string());
    item.documentation = Some(Documentation::MarkupContent(MarkupContent {
        kind: MarkupKind::Markdown,
        value: builtin.description.to_string(),
    }));
    item.text_edit = Some(CompletionTextEdit::Edit(TextEdit {
        range: LspRange::new(
            context.document.lsp_position_from_tree_sitter_point(start)?,
            context.document.lsp_position_from_tree_sitter_point(end)?,
        ),
        new_text: package_ref,
    }));

    Ok(item)
}

fn line_without_newline(line: &str) -> &str {
    line.strip_suffix('\n').unwrap_or(line)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::completions::tests::utils::assert_text_edit;

    fn frontmatter_output_completions(cursor_text: &str) -> Option<Vec<CompletionItem>> {
        let (text, point) = point_from_cursor(cursor_text);
        let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, None);
        completions_from_frontmatter_output(&context).unwrap()
    }

    #[test]
    fn test_frontmatter_output_completion_offers_builtin_starters() {
        let completions = frontmatter_output_completions(
            "---\noutput: @\ntitle: \"Report\"\n---\n\nBody\n",
        )
        .unwrap();
        let labels: Vec<&str> = completions.iter().map(|item| item.label.as_str()).collect();

        assert_eq!(labels, vec![
            "rmarkdown::html_document",
            "rmarkdown::pdf_document",
            "rmarkdown::word_document",
            "rmarkdown::beamer_presentation",
            "rmarkdown::ioslides_presentation",
            "rmarkdown::slidy_presentation",
        ]);

        let html = completions
            .iter()
            .find(|item| item.label == "rmarkdown::html_document")
            .unwrap();

        assert_eq!(html.detail.as_deref(), Some("HTML Document"));
        assert_text_edit(html, "rmarkdown::html_document");
    }

    #[test]
    fn test_frontmatter_output_completion_replaces_partial_prefix() {
        let completions = frontmatter_output_completions(
            "---\noutput: rmarkdown::ht@\n---\n\nBody\n",
        )
        .unwrap();

        let html = completions
            .iter()
            .find(|item| item.label == "rmarkdown::html_document")
            .unwrap();

        assert_text_edit(html, "rmarkdown::html_document");

        match html.text_edit.as_ref().unwrap() {
            CompletionTextEdit::Edit(edit) => {
                assert_eq!(edit.range.start.line, 1);
                assert_eq!(edit.range.start.character, 8);
                assert_eq!(edit.range.end.line, 1);
                assert_eq!(edit.range.end.character, 21);
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
}
