use std::ops::Range;

use tree_sitter::Point;

use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;
use crate::lsp::document::Fence;
use crate::lsp::frontmatter::semantic::header_rows;

pub(crate) struct MathCommand<'a> {
    /// Editable name, excluding the leading backslash.
    pub(crate) range: Range<usize>,
    pub(crate) prefix: &'a str,
    pub(crate) close_inline: bool,
}

/// Scan the original Markdown, not the R projection, only after a command-like
/// token is found at the cursor. The prefix need not be a complete equation.
pub(crate) fn command_at(document: &Document, point: Point) -> Option<MathCommand<'_>> {
    if document.kind != DocumentKind::LiterateR {
        return None;
    }

    let line = document.get_line(point.row)?;
    let before = line.get(..point.column)?;
    let name_start = before
        .trim_end_matches(|ch: char| ch.is_ascii_alphabetic())
        .len();
    let slash = name_start.checked_sub(1)?;
    if line.as_bytes()[slash] != b'\\' || is_escaped(line, slash) {
        return None;
    }

    let body_start = header_rows(document).map_or(0, |rows| rows.end);
    if point.row < body_start {
        return None;
    }

    let mut fence: Option<Fence> = None;
    let mut span = Span::Prose;
    for row in body_start..=point.row {
        let current = document.get_line(row)?;
        if let Some(active) = fence {
            if active.closes(current) {
                fence = None;
            }
            continue;
        }
        if current.trim().is_empty() {
            span = Span::Prose;
            continue;
        }
        if span == Span::Prose && (current.starts_with("    ") || current.starts_with('\t')) {
            continue;
        }
        if let Some(opening) = Fence::markdown_opening(current) {
            fence = Some(opening);
            span = Span::Prose;
            continue;
        }

        if row == point.row {
            span.scan(current, slash);
            match span {
                Span::Display | Span::Inline { digit_led: false } => {},
                // An unclosed "$20 ..." is more likely a price than math.
                // With a closing dollar on this line, "$2 \times x$" is fine.
                Span::Inline { digit_led: true } if has_inline_closer(line, point.column) => {},
                _ => return None,
            }
            let suffix_len = line[point.column..]
                .bytes()
                .take_while(u8::is_ascii_alphabetic)
                .count();
            let end = point.column + suffix_len;
            let close_inline = matches!(span, Span::Inline { digit_led: false }) &&
                line[end..].trim().is_empty() &&
                !inline_closes_on_following_line(document, point.row);
            return Some(MathCommand {
                range: name_start..end,
                prefix: &before[name_start..],
                close_inline,
            });
        }

        span.scan(current, current.len());
    }

    None
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Span {
    Prose,
    Code(usize),
    Inline { digit_led: bool },
    Display,
}

impl Span {
    // An editor-oriented subset of Pandoc's tex_math_dollars syntax. Keep
    // paragraph state for wrapped equations and code spans. The cursor stops
    // scanning delimiters, but a delimiter can still inspect an adjacent byte.
    fn scan(&mut self, line: &str, stop: usize) {
        let bytes = line.as_bytes();
        let mut index = 0;
        while index < stop {
            let marker = bytes[index];
            let start = index;
            index += 1;
            match marker {
                b'\\' if !matches!(self, Self::Code(_)) => {
                    if bytes.get(index).is_some_and(u8::is_ascii_punctuation) {
                        index += 1;
                    }
                },
                b'`' if matches!(self, Self::Prose | Self::Code(_)) => {
                    index += bytes[index..]
                        .iter()
                        .take_while(|&&byte| byte == marker)
                        .count();
                    let width = index - start;
                    match *self {
                        Self::Prose => *self = Self::Code(width),
                        Self::Code(opening_width) if opening_width == width => *self = Self::Prose,
                        _ => {},
                    }
                },
                b'$' if !matches!(self, Self::Code(_)) => {
                    // The first dollar may close inline math even when the
                    // next one starts a new span: "$x$$y$".
                    if matches!(self, Self::Inline { .. }) && is_inline_closer(line, start) {
                        *self = Self::Prose;
                        continue;
                    }
                    index += bytes[index..]
                        .iter()
                        .take_while(|&&byte| byte == marker)
                        .count();
                    match (*self, index - start) {
                        (Self::Prose | Self::Inline { digit_led: true }, 2) => {
                            *self = Self::Display;
                        },
                        (Self::Display, 2) => *self = Self::Prose,
                        // If a dollar can open but not close, it can also
                        // start a new span after a literal price.
                        (Self::Prose | Self::Inline { digit_led: true }, 1)
                            if line[index..].starts_with(|ch: char| !ch.is_whitespace()) =>
                        {
                            *self = Self::Inline {
                                digit_led: bytes[index].is_ascii_digit(),
                            };
                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        }
    }
}

fn is_escaped(line: &str, index: usize) -> bool {
    line.as_bytes()[..index]
        .iter()
        .rev()
        .take_while(|&&byte| byte == b'\\')
        .count() %
        2 !=
        0
}

fn is_inline_closer(line: &str, index: usize) -> bool {
    line[..index].ends_with(|ch: char| !ch.is_whitespace()) &&
        !line
            .as_bytes()
            .get(index + 1)
            .is_some_and(u8::is_ascii_digit)
}

fn has_inline_closer(line: &str, from: usize) -> bool {
    line[from..]
        .match_indices('$')
        .map(|(offset, _)| from + offset)
        .any(|index| is_inline_closer(line, index) && !is_escaped(line, index))
}

fn inline_closes_on_following_line(document: &Document, row: usize) -> bool {
    (row + 1..document.line_index.len() as usize)
        .map_while(|row| document.get_line(row))
        .take_while(|line| !line.trim().is_empty() && Fence::markdown_opening(line).is_none())
        .any(|line| has_inline_closer(line, 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::point_from_cursor;

    fn command(cursor_text: &str) -> Option<(String, String)> {
        let (text, point) = point_from_cursor(cursor_text);
        let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
        let MathCommand { range, prefix, .. } = command_at(&document, point)?;
        Some((
            prefix.to_string(),
            document.get_line(point.row)?[range].to_string(),
        ))
    }

    #[test]
    fn math_command_detects_incomplete_and_paired_equations() {
        for (input, prefix, token) in [
            (r"$\@", "", ""),
            (r"$\kap@", "kap", "kap"),
            (r"κ 🧪 $\kap@pa$.", "kap", "kappa"),
            ("$x +\n\\kap@$", "kap", "kap"),
            ("$$\n    \\kap@\n$$ {#eq-kappa}", "kap", "kap"),
            (r"$$\kap@$$", "kap", "kap"),
            (r"$2 \ti@mes x$", "ti", "times"),
            (r"$C = \$20 + \kap@$", "kap", "kap"),
            (r"$a \\ \kap@$", "kap", "kap"),
            (r"$x$$\kap@$", "kap", "kap"),
            (r"Pay $20 for $x + \kap@", "kap", "kap"),
            ("---\ntitle: Paper\n...\n$\\kap@$", "kap", "kap"),
            ("~~~\ncode\n~~~~\n$\\kap@$", "kap", "kap"),
        ] {
            assert_eq!(
                command(input),
                Some((prefix.to_string(), token.to_string())),
                "{input}"
            );
        }
    }

    #[test]
    fn math_command_stays_out_of_prose_and_code() {
        for input in [
            r"\kap@",
            r"$ @",
            r"$ \kap@",
            r"$20 and $30 \kap@",
            r"Pay $20 for a \kap@.",
            r"\$\kap@",
            r"$x \\kap@",
            r"$x$ and \kap@",
            r"$x$$y$ and \kap@",
            r"$\$$ and \kap@",
            r"$$x$$ and \kap@",
            "$$x\n\n\\kap@",
            r"§ `$\kap@`",
            r"```$\kap@```",
            "`code\n$\\kap@`",
            "`r '$\\kap@'`",
            "    $\\kap@$",
            "\t$\\kap@$",
            "~~~{r}\n'$\\kap@'\n~~~",
            "```python\n'$\\kap@'\n```",
            "```\n$\\kap@\n```",
            "---\ntitle: '$\\kap@'\n---",
            "---\ntitle: '$\\kap@'",
        ] {
            assert_eq!(command(input), None, "{input}");
        }
    }

    #[test]
    fn math_command_only_adds_inline_closer_at_end_of_unpaired_math() {
        for (input, close_inline) in [
            (r"$\kap@", true),
            (r"Text $x + \ka@p  ", true),
            (r"$\kap@$", false),
            (r"$\kap@ + x$", false),
            (r"$\kap@ + x", false),
            ("$\\kap@\n+ x$", false),
            ("$\\kap@\n\nNew paragraph", true),
            ("$$\n\\kap@\n$$", false),
            (r"$$\kap@", false),
        ] {
            let (text, point) = point_from_cursor(input);
            let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);
            assert_eq!(
                command_at(&document, point).unwrap().close_inline,
                close_inline,
                "{input}"
            );
        }
    }
}
