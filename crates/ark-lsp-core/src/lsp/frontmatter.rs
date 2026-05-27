use std::ops::Range;

use tree_sitter::Point;

use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;

pub(crate) struct FrontmatterOutputValue {
    pub(crate) start: Point,
    pub(crate) end: Point,
    pub(crate) value: String,
    pub(crate) needs_leading_space: bool,
}

pub(crate) fn frontmatter_row_range(document: &Document) -> Option<Range<usize>> {
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

pub(crate) fn frontmatter_has_top_level_key(document: &Document, key: &str) -> bool {
    if document.kind != DocumentKind::LiterateR || key.is_empty() {
        return false;
    }

    let Some(frontmatter_rows) = frontmatter_row_range(document) else {
        return false;
    };

    for row in frontmatter_rows {
        let Some(line) = document.get_line(row).map(line_without_newline) else {
            continue;
        };
        if line.chars().next().is_some_and(char::is_whitespace) {
            continue;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let Some((raw_key, _)) = trimmed.split_once(':') else {
            continue;
        };
        if clean_scalar_value(raw_key).as_deref() == Some(key) || raw_key.trim() == key {
            return true;
        }
    }

    false
}

pub(crate) fn frontmatter_output_value_edit_range(
    document: &Document,
    point: Point,
) -> Option<FrontmatterOutputValue> {
    if document.kind != DocumentKind::LiterateR {
        return None;
    }

    let frontmatter_rows = frontmatter_row_range(document)?;
    if !frontmatter_rows.contains(&point.row) {
        return None;
    }

    let line = line_without_newline(document.get_line(point.row)?);
    let parsed = parse_scalar_output_line(line)?;
    let value_end = point.column.min(line.len());

    if value_end < parsed.value_start {
        return None;
    }

    if line[parsed.value_start..value_end].contains(['[', ']', '{', '}', ',']) {
        return None;
    }

    Some(FrontmatterOutputValue {
        start: Point::new(point.row, parsed.value_start),
        end: Point::new(point.row, value_end),
        value: line[parsed.value_start..value_end].to_string(),
        needs_leading_space: parsed.value_start == parsed.raw_value_start,
    })
}

pub(crate) fn frontmatter_output_help_topic(document: &Document, point: Point) -> Option<String> {
    if document.kind != DocumentKind::LiterateR {
        return None;
    }

    let frontmatter_rows = frontmatter_row_range(document)?;
    if !frontmatter_rows.contains(&point.row) {
        return None;
    }

    let line = line_without_newline(document.get_line(point.row)?);
    let parsed = parse_scalar_output_line(line)?;
    let value_end = scalar_value_end(line, parsed.value_start);

    if point.column < parsed.value_start || point.column > value_end {
        return None;
    }

    clean_scalar_value(&line[parsed.value_start..value_end])
}

pub(crate) fn line_without_newline(line: &str) -> &str {
    line.strip_suffix('\n').unwrap_or(line)
}

struct ParsedOutputLine {
    raw_value_start: usize,
    value_start: usize,
}

fn parse_scalar_output_line(line: &str) -> Option<ParsedOutputLine> {
    let trimmed = line.trim_start();
    let indent = line.len() - trimmed.len();

    let (key, after_colon) = trimmed.split_once(':')?;
    if key.trim() != "output" {
        return None;
    }

    let value_prefix = after_colon.trim_start_matches(|ch: char| ch.is_ascii_whitespace());
    if value_prefix.starts_with('[') || value_prefix.starts_with('{') {
        return None;
    }

    let colon_index = trimmed.find(':').unwrap_or_default();
    let raw_value_start = indent + colon_index + 1;
    let value_start = raw_value_start + (after_colon.len() - value_prefix.len());

    if value_start > line.len() {
        return None;
    }

    Some(ParsedOutputLine {
        raw_value_start,
        value_start,
    })
}

fn scalar_value_end(line: &str, value_start: usize) -> usize {
    let value = &line[value_start..];
    let mut in_single_quotes = false;
    let mut in_double_quotes = false;
    let mut previous_was_whitespace = true;

    for (offset, ch) in value.char_indices() {
        match ch {
            '\'' if !in_double_quotes => {
                in_single_quotes = !in_single_quotes;
                previous_was_whitespace = false;
            },
            '"' if !in_single_quotes => {
                in_double_quotes = !in_double_quotes;
                previous_was_whitespace = false;
            },
            '#' if !in_single_quotes && !in_double_quotes && previous_was_whitespace => {
                return value_start + offset;
            },
            _ => {
                previous_was_whitespace = ch.is_ascii_whitespace();
            },
        }
    }

    line.len()
}

fn clean_scalar_value(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    let unquoted = if trimmed.len() >= 2 {
        let bytes = trimmed.as_bytes();
        let first = bytes[0];
        let last = bytes[bytes.len() - 1];
        if (first == b'\'' && last == b'\'') || (first == b'"' && last == b'"') {
            &trimmed[1..trimmed.len() - 1]
        } else {
            trimmed
        }
    } else {
        trimmed
    };

    let topic = unquoted.trim();
    if topic.is_empty() || topic.contains(['[', ']', '{', '}', ',']) {
        return None;
    }

    Some(topic.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;

    #[test]
    fn test_frontmatter_output_help_topic_extracts_namespaced_scalar() {
        let (text, point) = point_from_cursor("---\noutput: revise::revise_letter_@pdf\n---\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);

        let topic = frontmatter_output_help_topic(&document, point);

        assert_eq!(topic.as_deref(), Some("revise::revise_letter_pdf"));
    }

    #[test]
    fn test_frontmatter_output_help_topic_strips_quotes() {
        let (text, point) = point_from_cursor("---\noutput: \"stats::@lm\"\n---\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);

        let topic = frontmatter_output_help_topic(&document, point);

        assert_eq!(topic.as_deref(), Some("stats::lm"));
    }

    #[test]
    fn test_frontmatter_output_help_topic_ignores_non_output_keys() {
        let (text, point) = point_from_cursor("---\ntitle: revise::@revise_letter_pdf\n---\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);

        assert!(frontmatter_output_help_topic(&document, point).is_none());
    }

    #[test]
    fn test_frontmatter_has_top_level_key_detects_params() {
        let document = Document::new_with_kind(
            "---\ntitle: \"Report\"\nparams:\n  value: !r NULL\n---\n",
            None,
            DocumentKind::LiterateR,
        );

        assert!(frontmatter_has_top_level_key(&document, "params"));
    }

    #[test]
    fn test_frontmatter_has_top_level_key_ignores_nested_key() {
        let document = Document::new_with_kind(
            "---\noutput:\n  params: html_document\n---\n",
            None,
            DocumentKind::LiterateR,
        );

        assert!(!frontmatter_has_top_level_key(&document, "params"));
    }
}
