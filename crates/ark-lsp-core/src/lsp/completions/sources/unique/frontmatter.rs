use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::CompletionTextEdit;
use tower_lsp::lsp_types::Documentation;
use tower_lsp::lsp_types::MarkupContent;
use tower_lsp::lsp_types::MarkupKind;
use tower_lsp::lsp_types::Range as LspRange;
use tower_lsp::lsp_types::TextEdit;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::CompletionData;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::frontmatter::semantic::cursor_context;
use crate::lsp::frontmatter::semantic::ContextKind;
use crate::lsp::frontmatter::semantic::CursorContext;

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
    BuiltinOutput {
        output: "rmarkdown::html_document",
        name: "R Markdown HTML",
        description: "Namespaced HTML report (requires rmarkdown).",
    },
    BuiltinOutput {
        output: "rmarkdown::pdf_document",
        name: "R Markdown PDF",
        description: "Namespaced PDF report (requires rmarkdown).",
    },
    BuiltinOutput {
        output: "rmarkdown::word_document",
        name: "R Markdown Word",
        description: "Namespaced Word report (requires rmarkdown).",
    },
    BuiltinOutput {
        output: "papaja::apa6_pdf",
        name: "papaja APA PDF",
        description: "APA manuscript PDF (requires papaja).",
    },
    BuiltinOutput {
        output: "papaja::apa6_docx",
        name: "papaja APA Word",
        description: "APA manuscript Word document (requires papaja).",
    },
    BuiltinOutput {
        output: "bookdown::html_document2",
        name: "Bookdown HTML",
        description: "HTML report with cross-references (requires bookdown).",
    },
    BuiltinOutput {
        output: "bookdown::pdf_document2",
        name: "Bookdown PDF",
        description: "PDF report with cross-references (requires bookdown).",
    },
    BuiltinOutput {
        output: "bookdown::word_document2",
        name: "Bookdown Word",
        description: "Word report with cross-references (requires bookdown).",
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

// Static schemas intentionally do not claim package installation or invoke R. Keep the
// dialects separate: R Markdown options use underscores; Quarto uses hyphens.
// Sources: rmarkdown.rstudio.com/docs/reference/{html,pdf,word}_document.html,
// quarto.org/docs/reference/formats/{html,pdf,docx}.html, papaja's apa6_pdf help.
const RMD_KEYS: &[&str] = &[
    "title",
    "author",
    "date",
    "abstract",
    "keywords",
    "bibliography",
    "csl",
    "output",
    "params",
];
const QUARTO_KEYS: &[&str] = &[
    "title",
    "author",
    "date",
    "abstract",
    "keywords",
    "bibliography",
    "csl",
    "format",
    "execute",
];
const QUARTO_FORMATS: &[&str] = &[
    "html", "pdf", "docx", "revealjs", "beamer", "pptx", "gfm", "epub",
];
const RMD_COMMON: &[&str] = &[
    "toc",
    "toc_depth",
    "number_sections",
    "fig_width",
    "fig_height",
    "fig_caption",
    "keep_md",
    "pandoc_args",
];
const RMD_HTML: &[&str] = &[
    "theme",
    "highlight",
    "css",
    "self_contained",
    "code_folding",
    "toc_float",
];
const RMD_PDF: &[&str] = &[
    "keep_tex",
    "latex_engine",
    "citation_package",
    "template",
    "includes",
];
const QUARTO_COMMON: &[&str] = &[
    "toc",
    "toc-depth",
    "number-sections",
    "fig-width",
    "fig-height",
    "keep-md",
];
const QUARTO_HTML: &[&str] = &[
    "theme",
    "css",
    "code-fold",
    "embed-resources",
    "toc-location",
];
const QUARTO_PDF: &[&str] = &[
    "keep-tex",
    "pdf-engine",
    "documentclass",
    "include-in-header",
];

fn option_names(renderer: &str, quarto: bool) -> Vec<&'static str> {
    if quarto {
        if !QUARTO_FORMATS.contains(&renderer) {
            return vec![];
        }
        let specific = match renderer {
            "html" | "revealjs" => QUARTO_HTML,
            "pdf" | "beamer" => QUARTO_PDF,
            "docx" => &["reference-doc"] as &[&str],
            _ => &[],
        };
        return QUARTO_COMMON.iter().chain(specific).copied().collect();
    }
    if builtin_output_from_value(renderer).is_none() {
        return vec![];
    }
    let common = if renderer.ends_with("_presentation") {
        &[
            "number_sections",
            "fig_width",
            "fig_height",
            "fig_caption",
            "keep_md",
            "pandoc_args",
        ] as &[&str]
    } else {
        RMD_COMMON
    };
    let specific: &[&str] = match renderer {
        "beamer_presentation" => &[
            "toc",
            "slide_level",
            "incremental",
            "keep_tex",
            "latex_engine",
            "theme",
        ],
        "ioslides_presentation" => &[
            "logo",
            "slide_level",
            "incremental",
            "self_contained",
            "css",
            "widescreen",
        ],
        "slidy_presentation" => &[
            "slide_level",
            "incremental",
            "self_contained",
            "css",
            "highlight",
        ],
        renderer if renderer.contains("pdf") => RMD_PDF,
        renderer if renderer.contains("html") => RMD_HTML,
        renderer if renderer.contains("word") || renderer.contains("docx") => &["reference_docx"],
        _ => &[],
    };
    common.iter().chain(specific).copied().collect()
}

fn completions_from_frontmatter_output(
    context: &DocumentContext,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    let Some(cursor) = cursor_context(context.document, context.point) else {
        return Ok(None);
    };
    let mut items = Vec::new();
    match &cursor.kind {
        ContextKind::Outputs {
            quarto: false,
            mapping,
        } => {
            if !mapping && builtin_output_from_value(&cursor.prefix).is_some() {
                return Ok(Some(items));
            }
            for builtin in BUILTIN_OUTPUTS {
                let mut item = make_item(
                    context,
                    &cursor,
                    builtin.output,
                    CompletionItemKind::MODULE,
                    builtin.name,
                    *mapping,
                )?;
                item.documentation = Some(Documentation::MarkupContent(MarkupContent {
                    kind: MarkupKind::Markdown,
                    value: builtin.description.to_string(),
                }));
                items.push(item);
            }
        },
        ContextKind::Outputs {
            quarto: true,
            mapping,
        } => {
            if !mapping && QUARTO_FORMATS.contains(&cursor.prefix.trim()) {
                return Ok(Some(items));
            }
            for format in QUARTO_FORMATS {
                items.push(make_item(
                    context,
                    &cursor,
                    format,
                    CompletionItemKind::MODULE,
                    "Quarto format",
                    *mapping,
                )?);
            }
        },
        ContextKind::Keys { quarto } => {
            for key in if *quarto { QUARTO_KEYS } else { RMD_KEYS } {
                items.push(make_item(
                    context,
                    &cursor,
                    key,
                    CompletionItemKind::FIELD,
                    "Document metadata",
                    true,
                )?);
            }
        },
        ContextKind::Options { quarto, renderer } => {
            for option in option_names(renderer, *quarto) {
                items.push(make_item(
                    context,
                    &cursor,
                    option,
                    CompletionItemKind::FIELD,
                    "Static format option",
                    true,
                )?);
            }
        },
        ContextKind::Path { extension } => {
            return Ok(Some(path_completions(context, &cursor, extension)?))
        },
    }
    Ok(Some(items))
}

fn builtin_output_from_value(value: &str) -> Option<&'static BuiltinOutput> {
    BUILTIN_OUTPUTS
        .iter()
        .find(|builtin| value.trim_end() == builtin.output)
}

fn yaml_insert(value: &str, quote: Option<char>) -> String {
    match quote {
        Some('\'') => value.replace('\'', "''"),
        Some('"') => value.replace('\\', "\\\\").replace('"', "\\\""),
        _ if value
            .chars()
            .any(|ch| ch.is_whitespace() || "#,:[]{}&*!|>'\'\"%@`".contains(ch)) =>
        {
            format!("'{}'", value.replace('\'', "''"))
        },
        _ => value.to_string(),
    }
}

fn make_item(
    context: &DocumentContext,
    cursor: &CursorContext,
    label: &str,
    kind: CompletionItemKind,
    detail: &str,
    key: bool,
) -> anyhow::Result<CompletionItem> {
    let mut item = completion_item(label, CompletionData::Unknown)?;
    item.kind = Some(kind);
    item.detail = Some(detail.to_string());
    let mut inserted = yaml_insert(label, cursor.quote);
    // Namespaced renderer strings are valid plain YAML scalars/keys (no whitespace after `:`).
    if matches!(cursor.kind, ContextKind::Outputs { .. }) && cursor.quote.is_none() {
        inserted = label.to_string();
    }
    if key && cursor.needs_colon {
        inserted.push_str(": ");
    }
    if cursor.needs_space {
        inserted.insert(0, ' ');
    }
    item.text_edit = Some(CompletionTextEdit::Edit(TextEdit {
        range: LspRange::new(
            context
                .document
                .lsp_position_from_tree_sitter_point(cursor.start)?,
            context
                .document
                .lsp_position_from_tree_sitter_point(cursor.end)?,
        ),
        new_text: inserted,
    }));
    Ok(item)
}

// Non-recursive and bounded. Reading only the directory the user is completing avoids
// traversing huge workspaces or depending on the live R working directory.
fn path_completions(
    context: &DocumentContext,
    cursor: &CursorContext,
    extension: &str,
) -> anyhow::Result<Vec<CompletionItem>> {
    let Some(base) = context
        .document
        .path
        .as_ref()
        .and_then(|path| path.parent())
    else {
        return Ok(vec![]);
    };
    let (parent, prefix) = cursor
        .prefix
        .rsplit_once('/')
        .map(|(parent, prefix)| (format!("{parent}/"), prefix))
        .unwrap_or_else(|| (String::new(), cursor.prefix.as_str()));
    let directory = base.join(&parent);
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Ok(vec![]);
    };
    let mut items = Vec::new();
    let mut incomplete = false;
    for (index, entry) in entries.enumerate() {
        if index >= 4096 {
            incomplete = true;
            break;
        }
        let Ok(entry) = entry else {
            continue;
        };
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !name.starts_with(prefix) || (name.starts_with('.') && !prefix.starts_with('.')) {
            continue;
        }
        let Ok(metadata) = entry.file_type() else {
            continue;
        };
        // DirEntry avoids per-file stat calls; follow only symlinks, never traverse them.
        let is_directory = metadata.is_dir() || (metadata.is_symlink() && entry.path().is_dir());
        if !is_directory &&
            !entry
                .path()
                .extension()
                .and_then(|value| value.to_str())
                .is_some_and(|value| value.eq_ignore_ascii_case(extension))
        {
            continue;
        }
        let label = format!("{parent}{name}{}", if is_directory { "/" } else { "" });
        let mut item = make_item(
            context,
            cursor,
            &label,
            if is_directory {
                CompletionItemKind::FOLDER
            } else {
                CompletionItemKind::FILE
            },
            "Relative to document directory",
            false,
        )?;
        item.filter_text = Some(label);
        items.push(item);
        if items.len() >= 256 {
            incomplete = true;
            break;
        }
    }
    items.sort_by(|left, right| left.label.cmp(&right.label));
    if incomplete {
        if let Some(item) = items.first_mut() {
            item.data = Some(serde_json::to_value(CompletionData::Incomplete)?);
        }
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::completions::tests::utils::assert_text_edit;
    use crate::lsp::document::Document;
    use crate::lsp::document::DocumentKind;

    fn frontmatter_output_completions(cursor_text: &str) -> Option<Vec<CompletionItem>> {
        let (text, point) = point_from_cursor(cursor_text);
        let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, None);
        completions_from_frontmatter_output(&context).unwrap()
    }

    // The cursor is before delimiters inserted by the editor, not at an unclosed token.
    fn path_items(text: &str, path: &std::path::Path) -> Vec<CompletionItem> {
        let (text, point) = point_from_cursor(text);
        let mut document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
        document.path = Some(path.to_path_buf());
        let context = DocumentContext::new(&document, point, None);
        completions_from_frontmatter_output(&context)
            .unwrap()
            .unwrap_or_default()
    }

    #[test]
    fn test_frontmatter_paths_are_document_relative_and_field_specific() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::create_dir(directory.path().join("references")).unwrap();
        std::fs::create_dir(directory.path().join("chapters")).unwrap();
        for name in ["références.bib", "other.txt", "apa.csl", "a'b.bib"] {
            std::fs::write(directory.path().join("references").join(name), "").unwrap();
        }
        let path = directory.path().join("chapters/report.Rmd");
        for text in [
            "---\nbibliography: \"../references/ré@\"\n---\n",
            "---\nbibliography: [\"existing.bib\", \"../references/ré@\"]\n---\n",
            "---\nbibliography:\n  - \"../references/ré@\"\n---\n",
        ] {
            let items = path_items(text, &path);
            assert_eq!(items.len(), 1, "{text}: {items:?}");
            assert_eq!(items[0].label, "../references/références.bib");
            assert_text_edit(&items[0], "../references/références.bib");
        }
        let items = path_items("---\ncsl: '../references/@'\n---\n", &path);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].label, "../references/apa.csl");
        let items = path_items("---\nbibliography: '../references/a@'\n---\n", &path);
        assert_text_edit(&items[0], "../references/a''b.bib");
    }

    #[test]
    fn test_frontmatter_edit_replaces_suffix_preserves_comments_and_quotes() {
        let items =
            frontmatter_output_completions("---\noutput: \"papaja::ap@_pdf\" # retain\n---\n")
                .unwrap();
        let item = items
            .iter()
            .find(|item| item.label == "papaja::apa6_pdf")
            .unwrap();
        assert_text_edit(item, "papaja::apa6_pdf");
        let CompletionTextEdit::Edit(edit) = item.text_edit.as_ref().unwrap() else {
            panic!()
        };
        assert_eq!(edit.range.start.character, 9);
        assert_eq!(edit.range.end.character, 23);
        let items = frontmatter_output_completions("---\noutput:\n  papaja::ap@:\n---\n").unwrap();
        assert_text_edit(
            items
                .iter()
                .find(|item| item.label == "papaja::apa6_pdf")
                .unwrap(),
            "papaja::apa6_pdf",
        );
    }

    #[test]
    fn test_frontmatter_dialects_and_incomplete_header() {
        let items = path_items(
            "---\nformat:\n  html:\n    code-@\n---\n",
            std::path::Path::new("/tmp/report.qmd"),
        );
        assert!(items.iter().any(|item| item.label == "code-fold"));
        assert!(!items.iter().any(|item| item.label == "code_folding"));
        assert!(path_items(
            "---\noutput: ht@\n---\n",
            std::path::Path::new("/tmp/report.qmd")
        )
        .is_empty());
        assert!(path_items(
            "---\nformat: ht@\n---\n",
            std::path::Path::new("/tmp/report.Rmd")
        )
        .is_empty());
        let items = frontmatter_output_completions("---\noutput: pa@").unwrap();
        assert!(items.iter().any(|item| item.label == "papaja::apa6_pdf"));
        assert!(frontmatter_output_completions("---\nabstract: |\n  output: pa@\n---\n").is_none());
    }

    #[test]
    fn test_frontmatter_path_completion_is_bounded() {
        let directory = tempfile::tempdir().unwrap();
        for index in 0..400 {
            std::fs::write(directory.path().join(format!("{index}.bib")), "").unwrap();
        }
        let items = path_items(
            "---\nbibliography: @\n---\n",
            &directory.path().join("report.Rmd"),
        );
        assert_eq!(items.len(), 256);
        assert!(items.iter().all(|item| item.label.ends_with(".bib")));
        assert!(crate::lsp::completions::completion_items_require_requery(
            &items
        ));
    }

    #[test]
    fn test_frontmatter_namespaced_renderer_and_nested_options() {
        let items = frontmatter_output_completions("---\noutput: papaja::apa@\n---\n").unwrap();
        assert!(items.iter().any(|item| item.label == "papaja::apa6_pdf"));
        let items =
            frontmatter_output_completions("---\noutput:\n  papaja::apa6_pdf:\n    keep_@\n---\n")
                .unwrap();
        let keep_tex = items.iter().find(|item| item.label == "keep_tex").unwrap();
        assert_text_edit(keep_tex, "keep_tex: ");
    }

    #[test]
    fn test_frontmatter_quarto_format_is_not_rmarkdown_output() {
        let items = frontmatter_output_completions("---\nformat: ht@\n---\n").unwrap();
        assert!(items.iter().any(|item| item.label == "html"));
        assert!(!items.iter().any(|item| item.label == "html_document"));
    }

    #[test]
    fn test_frontmatter_output_completion_offers_builtin_starters() {
        let completions =
            frontmatter_output_completions("---\noutput: @\ntitle: \"Report\"\n---\n\nBody\n")
                .unwrap();
        let labels: Vec<&str> = completions.iter().map(|item| item.label.as_str()).collect();

        assert_eq!(&labels[..6], &[
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
