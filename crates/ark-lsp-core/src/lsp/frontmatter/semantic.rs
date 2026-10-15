//! A deliberately small, tolerant cursor classifier, not a YAML language server.
//! Completed metadata is validated by yaml-rust2 before filesystem diagnostics.
use std::collections::HashSet;
use std::io::ErrorKind;
use std::ops::Range;

use tower_lsp::lsp_types::Diagnostic;
use tower_lsp::lsp_types::DiagnosticSeverity;
use tower_lsp::lsp_types::NumberOrString;
use tree_sitter::Point;
use yaml_rust2::scanner::Scanner;
use yaml_rust2::scanner::TokenType;
use yaml_rust2::Yaml;
use yaml_rust2::YamlLoader;

use super::line_without_newline;
use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;

// Bound both parsing work and IO. A pathological header should not stall editing.
const MAX_HEADER_BYTES: usize = 128 * 1024;
const MAX_HEADER_LINES: usize = 2048;
const MAX_PATH_DIAGNOSTICS: usize = 64;
const MAX_YAML_NESTING: usize = 64;

#[derive(Debug)]
pub(crate) enum ContextKind {
    Keys { quarto: bool },
    Outputs { quarto: bool, mapping: bool },
    Options { quarto: bool, renderer: String },
    Path { extension: &'static str },
}

#[derive(Debug)]
pub(crate) struct CursorContext {
    pub kind: ContextKind,
    pub start: Point,
    pub end: Point,
    pub prefix: String,
    pub quote: Option<char>,
    pub needs_space: bool,
    pub needs_colon: bool,
}

/// Closing delimiters may be absent while typing, but stop at a Markdown fence.
fn header_rows(document: &Document) -> Option<Range<usize>> {
    if document.kind != DocumentKind::LiterateR || document.get_line(0)?.trim() != "---" {
        return None;
    }
    let line_count: usize = document.line_index.len().try_into().ok()?;
    let mut bytes = 0;
    let mut end = 1;
    for row in 1..MAX_HEADER_LINES.min(line_count) {
        let Some(line) = document.get_line(row) else {
            break;
        };
        bytes += line.len();
        if bytes > MAX_HEADER_BYTES {
            return None;
        }
        if matches!(line.trim(), "---" | "...") {
            return Some(1..row);
        }
        if line.trim_start().starts_with("```") {
            break;
        }
        end = row + 1;
    }
    Some(1..end)
}

fn quarto_document(document: &Document) -> Option<bool> {
    let extension = document.path.as_ref()?.extension()?.to_str()?;
    match extension.to_ascii_lowercase().as_str() {
        "qmd" | "quarto" => Some(true),
        "rmd" => Some(false),
        _ => None,
    }
}

// Mapping separators must be followed by whitespace/end: `pkg::format:` is one key.
fn mapping_separator(line: &str) -> Option<usize> {
    let mut quote = None;
    let mut escaped = false;
    for (index, ch) in line.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if quote == Some('"') && ch == '\\' {
            escaped = true;
            continue;
        }
        if matches!(ch, '\'' | '"') {
            if quote == Some(ch) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(ch);
            }
        }
        if quote.is_none() &&
            ch == ':' &&
            line[index + 1..]
                .chars()
                .next()
                .is_none_or(char::is_whitespace)
        {
            return Some(index);
        }
    }
    None
}

#[derive(Debug)]
struct Parent {
    indent: usize,
    key: String,
    blocked: bool,
}

fn parents(document: &Document, start: usize, row: usize, indent: usize) -> Vec<Parent> {
    let mut stack: Vec<Parent> = Vec::new();
    for previous in start..row {
        let line = document.get_line(previous).unwrap_or("").trim_end();
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let spaces = line.len() - trimmed.len();
        while stack.last().is_some_and(|parent| parent.indent >= spaces) {
            stack.pop();
        }
        if stack.last().is_some_and(|parent| parent.blocked) {
            continue;
        }
        if let Some(colon) = mapping_separator(trimmed) {
            let value = trimmed[colon + 1..].trim();
            stack.push(Parent {
                indent: spaces,
                key: trimmed[..colon].trim_matches(['\'', '"']).to_string(),
                // Only empty mapping values open a supported nested context. This also
                // prevents literal/folded scalar contents from being treated as metadata.
                blocked: !value.is_empty() && !value.starts_with('#'),
            });
        }
    }
    while stack.last().is_some_and(|parent| parent.indent >= indent) {
        stack.pop();
    }
    stack
}

/// Single-line YAML scalar spans, retaining quotes. Flow-list punctuation is outside spans.
fn scalar_spans(line: &str, start: usize) -> Vec<Range<usize>> {
    let mut spans = Vec::new();
    let mut scalar_start = start;
    let mut quote = None;
    let mut escaped = false;
    for (offset, ch) in line[start..].char_indices() {
        let index = start + offset;
        if escaped {
            escaped = false;
            continue;
        }
        if quote == Some('"') && ch == '\\' {
            escaped = true;
            continue;
        }
        if matches!(ch, '\'' | '"') {
            if quote == Some(ch) {
                quote = None;
            } else if quote.is_none() {
                quote = Some(ch);
            }
        }
        if quote.is_none() {
            if ch == '#' && (index == start || line[..index].ends_with(char::is_whitespace)) {
                spans.push(scalar_start..index);
                return spans;
            }
            if matches!(ch, '[' | ']' | ',') {
                spans.push(scalar_start..index);
                scalar_start = index + ch.len_utf8();
            }
        }
    }
    spans.push(scalar_start..line.len());
    spans
}

fn scalar_context(
    line: &str,
    start: usize,
    point: Point,
    kind: ContextKind,
) -> Option<CursorContext> {
    for span in scalar_spans(line, start) {
        let raw = &line[span.clone()];
        let mut begin = span.start + raw.len() - raw.trim_start().len();
        let mut end = span.end - (raw.len() - raw.trim_end().len());
        end = end.max(begin);
        let quote = line[begin..end]
            .chars()
            .next()
            .filter(|ch| matches!(ch, '\'' | '"'));
        let mut closed = false;
        if let Some(quote) = quote {
            begin += 1;
            if end > begin && line[..end].ends_with(quote) {
                end -= 1;
                closed = true;
            }
        }
        if point.column < begin || point.column > if closed { end } else { span.end } {
            continue;
        }
        let prefix_end = point.column.min(end);
        let raw_prefix = &line[begin..prefix_end];
        let prefix = match quote {
            Some('"') => decode_scalar(&format!("\"{raw_prefix}\""))?,
            Some('\'') => raw_prefix.replace("''", "'"),
            _ => raw_prefix.to_string(),
        };
        if !is_local_literal(&prefix) {
            return None;
        }
        return Some(CursorContext {
            kind,
            start: Point::new(point.row, begin),
            end: Point::new(point.row, end),
            prefix,
            quote,
            needs_space: begin == start && start > 0 && line[..start].ends_with(':'),
            needs_colon: false,
        });
    }
    None
}

pub(crate) fn cursor_context(document: &Document, point: Point) -> Option<CursorContext> {
    let rows = header_rows(document)?;
    if !rows.contains(&point.row) {
        return None;
    }
    let line = line_without_newline(document.get_line(point.row)?).trim_end_matches('\r');
    if point.column > line.len() || !line.is_char_boundary(point.column) {
        return None;
    }
    let trimmed = line.trim_start();
    let indent = line.len() - trimmed.len();
    if point.column < indent || trimmed.starts_with('#') || line[..indent].contains('\t') {
        return None;
    }
    let parents = parents(document, rows.start, point.row, indent);
    if parents.iter().any(|parent| parent.blocked) {
        return None;
    }
    let root = parents.first().map(|parent| parent.key.as_str());
    let dialect = quarto_document(document);
    let quarto = dialect.unwrap_or(root == Some("format") || trimmed.starts_with("format:"));
    let output_key = if quarto { "format" } else { "output" };

    if parents.is_empty() && indent == 0 {
        if let Some(colon) = mapping_separator(line) {
            let key = line[..colon].trim_matches(['\'', '"']);
            if point.column > colon {
                let kind = match key {
                    "bibliography" => ContextKind::Path { extension: "bib" },
                    "csl" => ContextKind::Path { extension: "csl" },
                    key if key == output_key => ContextKind::Outputs {
                        quarto,
                        mapping: false,
                    },
                    _ => return None,
                };
                return scalar_context(line, colon + 1, point, kind);
            }
        }
    }
    if parents.len() == 1 && matches!(root, Some("bibliography")) && trimmed.starts_with("- ") {
        return scalar_context(line, indent + 2, point, ContextKind::Path {
            extension: "bib",
        });
    }
    let kind = if parents.is_empty() && indent == 0 {
        ContextKind::Keys { quarto }
    } else if root == Some(output_key) && parents.len() == 1 {
        ContextKind::Outputs {
            quarto,
            mapping: true,
        }
    } else if root == Some(output_key) && parents.len() == 2 {
        ContextKind::Options {
            quarto,
            renderer: parents[1].key.clone(),
        }
    } else {
        return None;
    };
    let colon = mapping_separator(line);
    let end = colon.unwrap_or(line.len());
    if point.column > end || line[indent..end].contains(['#', '[', ']', '{', '}', '\'', '"']) {
        return None;
    }
    Some(CursorContext {
        kind,
        start: Point::new(point.row, indent),
        end: Point::new(point.row, end),
        prefix: line[indent..point.column].to_string(),
        quote: None,
        needs_space: false,
        needs_colon: colon.is_none(),
    })
}

// YamlLoader clones anchored subtrees when processing aliases. Byte/line limits
// alone therefore do not bound its memory or work. Scan tokens without building
// a value tree first; quoted '&'/'*' characters remain ordinary scalar tokens.
// Also cap nesting before the loader can build recursively dropped structures.
fn load_literal_yaml(text: &str) -> Option<Vec<Yaml>> {
    if text.len() > MAX_HEADER_BYTES {
        return None;
    }
    let mut scanner = Scanner::new(text.chars());
    let mut depth: usize = 0;
    while let Some(token) = scanner.next_token().ok()? {
        match token.1 {
            TokenType::Anchor(_) | TokenType::Alias(_) => return None,
            TokenType::BlockSequenceStart |
            TokenType::BlockMappingStart |
            TokenType::FlowSequenceStart |
            TokenType::FlowMappingStart => {
                depth += 1;
                if depth > MAX_YAML_NESTING {
                    return None;
                }
            },
            TokenType::BlockEnd | TokenType::FlowSequenceEnd | TokenType::FlowMappingEnd => {
                depth = depth.saturating_sub(1);
            },
            _ => {},
        }
    }
    YamlLoader::load_from_str(text).ok()
}

fn decode_scalar(text: &str) -> Option<String> {
    let documents = load_literal_yaml(text)?;
    documents.first()?.as_str().map(str::to_string)
}

pub(crate) fn is_local_literal(value: &str) -> bool {
    !value.starts_with(['!', '&', '*', '|', '>', '~', '$']) &&
        !value.contains("://") &&
        !value.contains(['\n', '\r', '\0'])
}

/// Only inspect literal known fields in syntactically complete, valid YAML. Never evaluate tags,
/// expand aliases, resolve URLs, or treat permission/IO failures as a missing file.
pub(crate) fn path_diagnostics(document: &Document) -> Vec<Diagnostic> {
    let Some(directory) = document.path.as_ref().and_then(|path| path.parent()) else {
        return vec![];
    };
    let Some(rows) = header_rows(document) else {
        return vec![];
    };
    // An unfinished header ends at the document boundary. get_line() treats an
    // out-of-bounds index as an internal error and captures a backtrace; normal
    // typing must not take that logging path.
    if rows.end >= document.line_index.newlines.len() ||
        !document
            .get_line(rows.end)
            .is_some_and(|line| matches!(line.trim(), "---" | "..."))
    {
        return vec![];
    }
    let header: String = rows
        .clone()
        .filter_map(|row| document.get_line(row))
        .collect();
    let Some(parsed) = load_literal_yaml(&header) else {
        return vec![];
    };
    let Some(mapping) = parsed.first() else {
        return vec![];
    };
    let mut references = HashSet::new();
    for field in ["bibliography", "csl"] {
        match &mapping[field] {
            Yaml::String(path) => {
                references.insert(path.as_str());
            },
            Yaml::Array(paths) if field == "bibliography" => {
                references.extend(paths.iter().filter_map(Yaml::as_str));
            },
            _ => {},
        }
    }
    if references.is_empty() {
        return vec![];
    }
    let mut diagnostics = Vec::new();
    let mut checked = 0;
    for row in rows.clone() {
        let line = document.get_line(row).unwrap_or("").trim_end();
        let trimmed = line.trim_start();
        let indent = line.len() - trimmed.len();
        let value_start = if indent == 0 {
            let Some(colon) = mapping_separator(line) else {
                continue;
            };
            if !matches!(
                line[..colon].trim_matches(['\'', '"']),
                "bibliography" | "csl"
            ) {
                continue;
            }
            colon + 1
        } else if trimmed.starts_with("- ") {
            let parents = parents(document, rows.start, row, indent);
            if parents.len() != 1 || parents[0].key != "bibliography" || parents[0].blocked {
                continue;
            }
            indent + 2
        } else {
            continue;
        };
        for span in scalar_spans(line, value_start) {
            let start = span.start;
            let raw = line[start..span.end].trim();
            if raw.is_empty() || !is_local_literal(raw) {
                continue;
            }
            let Some(value) = decode_scalar(raw) else {
                continue;
            };
            if value.is_empty() || !is_local_literal(&value) || !references.contains(value.as_str())
            {
                continue;
            }
            let raw_start =
                start + (line[start..span.end].len() - line[start..span.end].trim_start().len());
            let end = raw_start + raw.len();
            let cursor_column = if raw.starts_with(['\'', '"']) {
                end - 1
            } else {
                end
            };
            let Some(context) = cursor_context(document, Point::new(row, cursor_column)) else {
                continue;
            };
            if !matches!(context.kind, ContextKind::Path { .. }) {
                continue;
            }
            checked += 1;
            if checked > MAX_PATH_DIAGNOSTICS {
                return diagnostics;
            }
            let Err(error) = std::fs::metadata(directory.join(&value)) else {
                continue;
            };
            if error.kind() != ErrorKind::NotFound {
                continue;
            }
            let (Ok(start), Ok(end)) = (
                document.lsp_position_from_tree_sitter_point(Point::new(row, raw_start)),
                document.lsp_position_from_tree_sitter_point(Point::new(row, end)),
            ) else {
                continue;
            };
            diagnostics.push(Diagnostic {
                range: tower_lsp::lsp_types::Range::new(start, end),
                severity: Some(DiagnosticSeverity::WARNING),
                source: Some("ark".to_string()),
                code: Some(NumberOrString::String(
                    "frontmatter-missing-file".to_string(),
                )),
                message: format!(
                    "Frontmatter file `{value}` was not found relative to the document directory."
                ),
                ..Default::default()
            });
        }
    }
    diagnostics
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document(text: &str, path: &std::path::Path) -> Document {
        let mut document = Document::new_with_kind(text, None, DocumentKind::LiterateR);
        document.path = Some(path.to_path_buf());
        document
    }

    #[test]
    fn frontmatter_diagnostics_skip_alias_graphs_before_expansion() {
        let directory = tempfile::tempdir().unwrap();
        // A tiny header expands superlinearly in YamlLoader. Keep this regression
        // fixture small enough to run safely on the old implementation.
        let text = "---\nv0: &v0 [x, x, x, x]\nv1: &v1 [*v0, *v0, *v0, *v0]\nv2: &v2 [*v1, *v1, *v1, *v1]\ncsl: missing.csl\n---\n";
        assert!(path_diagnostics(&document(text, &directory.path().join("report.Rmd"))).is_empty());
        // Literal punctuation in quoted filenames is not an anchor or alias.
        let text = "---\nbibliography: 'a&b.bib'\ncsl: 'a*b.csl'\n---\n";
        assert_eq!(
            path_diagnostics(&document(text, &directory.path().join("report.Rmd"))).len(),
            2
        );
    }

    #[test]
    fn frontmatter_literal_yaml_caps_nesting_without_expanding_aliases() {
        let nested = format!("{}x{}", "[".repeat(1000), "]".repeat(1000));
        assert!(load_literal_yaml(&nested).is_none());
        assert!(load_literal_yaml("value: &anchor [one, two]\ncopy: *anchor").is_none());
        assert!(load_literal_yaml("value: \"&anchor *alias\"").is_some());
        assert!(load_literal_yaml("value: [unclosed").is_none());
    }

    #[test]
    fn frontmatter_unfinished_headers_stop_at_document_boundary() {
        let path = std::path::Path::new("/tmp/report.Rmd");
        for text in ["---", "---\n", "---\ncsl: missing.csl", "---\noutput: pa"] {
            let document = document(text, path);
            let rows = header_rows(&document).unwrap();
            assert_eq!(rows.end, document.line_index.newlines.len());
            assert!(path_diagnostics(&document).is_empty());
        }
        let document = document("---\noutput: pa", path);
        assert!(cursor_context(&document, Point::new(1, 10)).is_some());
    }

    #[test]
    fn frontmatter_missing_paths_validate_yaml_and_preserve_positions() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("exists.bib"), "").unwrap();
        let document = document("---\nbibliography: [\"exists.bib\", \"références.bib\"]\ncsl: missing.csl # comment\n---\n", &directory.path().join("report.Rmd"));
        let diagnostics = path_diagnostics(&document);
        assert_eq!(diagnostics.len(), 2, "{diagnostics:?}");
        assert_eq!(diagnostics[0].range.start.line, 1);
        assert_eq!(diagnostics[0].range.start.character, 29);
        assert_eq!(diagnostics[0].range.end.character, 45);
        assert_eq!(diagnostics[1].range.start.line, 2);
        assert!(diagnostics[1].message.contains("missing.csl"));
    }

    #[test]
    fn frontmatter_path_diagnostics_skip_dynamic_remote_and_malformed_values() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("report.Rmd");
        for text in [
            "---\nbibliography: !r paste0('a', '.bib')\ncsl: https://example.invalid/apa.csl\n---\n",
            "---\nbibliography: [\"unfinished\n---\n",
            "---\nbibliography: absent.bib\n",
            "---\nabstract: |\n  bibliography: absent.bib\n---\n",
            "---\ncustom:\n  bibliography: absent.bib\n---\n",
            "---\nbibliography: null\ncsl: ~\n---\n",
        ] {
            assert!(path_diagnostics(&document(text, &path)).is_empty(), "{text}");
        }
        let document = Document::new_with_kind(
            "---\nbibliography: absent.bib\n---\n",
            None,
            DocumentKind::LiterateR,
        );
        assert!(path_diagnostics(&document).is_empty());
    }

    #[test]
    fn frontmatter_path_diagnostics_support_block_lists_and_cap_work() {
        let directory = tempfile::tempdir().unwrap();
        let text = format!(
            "---\nbibliography:\n{}---\n",
            (0..100)
                .map(|index| format!("  - missing{index}.bib\n"))
                .collect::<String>()
        );
        let diagnostics = path_diagnostics(&document(&text, &directory.path().join("report.Rmd")));
        assert_eq!(diagnostics.len(), MAX_PATH_DIAGNOSTICS);
        assert_eq!(diagnostics[0].range.start.line, 2);
        assert_eq!(diagnostics[0].range.start.character, 4);
    }
}
