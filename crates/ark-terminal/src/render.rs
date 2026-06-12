use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::input::EditorSnapshot;
use crate::input::ReverseSearchSnapshot;
use crate::prompt::PromptState;

#[derive(Debug)]
pub struct LocalInputRenderer {
    rendered: Option<RenderedInput>,
    terminal_cols: usize,
}

#[derive(Debug)]
struct RenderedInput {
    layout: RenderLayout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RenderLayout {
    end: TerminalPosition,
    cursor: TerminalPosition,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TerminalPosition {
    row: usize,
    col: usize,
}

impl LocalInputRenderer {
    pub fn new() -> Self {
        Self {
            rendered: None,
            terminal_cols: 80,
        }
    }

    #[cfg(test)]
    fn with_terminal_cols(terminal_cols: usize) -> Self {
        Self {
            rendered: None,
            terminal_cols: terminal_cols.max(1),
        }
    }

    pub fn set_terminal_cols(&mut self, terminal_cols: usize) {
        self.terminal_cols = terminal_cols.max(1);
    }

    pub fn redraw(&mut self, snapshot: &EditorSnapshot, prompt_state: PromptState) -> Vec<u8> {
        let had_rendered = self.rendered.is_some();
        let mut out = self.clear();
        if had_rendered {
            out.extend_from_slice(prompt_for_state(prompt_state).as_bytes());
        }
        out.extend_from_slice(&render_input_bytes(&snapshot.text));

        let layout = layout_for_snapshot(snapshot, prompt_state, self.terminal_cols);
        out.extend_from_slice(&move_cursor(layout.end, layout.cursor));

        if had_rendered || !snapshot.text.is_empty() {
            self.rendered = Some(RenderedInput { layout });
        }
        out
    }

    pub fn redraw_reverse_search(
        &mut self,
        snapshot: &ReverseSearchSnapshot,
        prompt_state: PromptState,
    ) -> Vec<u8> {
        let had_rendered = self.rendered.is_some();
        let mut out = self.clear();
        if had_rendered {
            out.extend_from_slice(prompt_for_state(prompt_state).as_bytes());
        }

        let text = reverse_search_text(snapshot);
        out.extend_from_slice(text.as_bytes());
        let layout = layout_for_text(&text, prompt_state, self.terminal_cols);
        self.rendered = Some(RenderedInput { layout });

        out
    }

    pub fn clear(&mut self) -> Vec<u8> {
        let Some(rendered) = self.rendered.take() else {
            return Vec::new();
        };

        let mut out = Vec::new();
        if rendered.layout.cursor.row < rendered.layout.end.row {
            out.extend_from_slice(
                format!(
                    "\x1b[{}B",
                    rendered.layout.end.row - rendered.layout.cursor.row
                )
                .as_bytes(),
            );
        }
        out.extend_from_slice(b"\r\x1b[2K");
        for _ in 0..rendered.layout.end.row {
            out.extend_from_slice(b"\x1b[1A\r\x1b[2K");
        }
        out
    }

    pub fn clear_to_prompt(&mut self, prompt_state: PromptState) -> Vec<u8> {
        let mut out = self.clear();
        if !out.is_empty() {
            out.extend_from_slice(prompt_for_state(prompt_state).as_bytes());
        }
        out
    }
}

fn render_input_bytes(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    for (index, line) in text.split('\n').enumerate() {
        if index > 0 {
            out.extend_from_slice(b"\r\n");
            out.extend_from_slice(continuation_prompt().as_bytes());
        }
        out.extend_from_slice(line.as_bytes());
    }
    out
}

fn reverse_search_text(snapshot: &ReverseSearchSnapshot) -> String {
    let result = snapshot
        .result
        .as_deref()
        .unwrap_or("failed reverse-i-search");
    format!("(reverse-i-search)`{}': {}", snapshot.query, result)
}

fn layout_for_snapshot(
    snapshot: &EditorSnapshot,
    prompt_state: PromptState,
    terminal_cols: usize,
) -> RenderLayout {
    layout_with_cursor(
        &snapshot.text,
        snapshot.cursor,
        prompt_state,
        terminal_cols,
        true,
    )
}

fn layout_for_text(text: &str, prompt_state: PromptState, terminal_cols: usize) -> RenderLayout {
    layout_with_cursor(text, text.len(), prompt_state, terminal_cols, false)
}

fn layout_with_cursor(
    text: &str,
    cursor_byte_offset: usize,
    prompt_state: PromptState,
    terminal_cols: usize,
    continuation_prompts: bool,
) -> RenderLayout {
    let terminal_cols = terminal_cols.max(1);
    let first_prompt_width = display_width(prompt_for_state(prompt_state));
    let continuation_prompt_width = display_width(continuation_prompt());

    let mut position = TerminalPosition {
        row: 0,
        col: first_prompt_width,
    };
    let mut cursor = None;
    let mut absolute_offset = 0;

    for (line_index, line) in text.split('\n').enumerate() {
        if line_index > 0 {
            position.row += 1;
            position.col = if continuation_prompts {
                continuation_prompt_width
            } else {
                0
            };
        }

        if cursor_byte_offset == absolute_offset {
            cursor = Some(position);
        }

        for (relative_offset, grapheme) in line.grapheme_indices(true) {
            let grapheme_offset = absolute_offset + relative_offset;
            if cursor_byte_offset == grapheme_offset {
                cursor = Some(position);
            }
            position = advance_position(position, display_width(grapheme), terminal_cols);
        }

        absolute_offset += line.len();
        if cursor_byte_offset == absolute_offset {
            cursor = Some(position);
        }
        absolute_offset += 1;
    }

    RenderLayout {
        end: position,
        cursor: cursor.unwrap_or(position),
    }
}

fn advance_position(
    mut position: TerminalPosition,
    width: usize,
    terminal_cols: usize,
) -> TerminalPosition {
    if width == 0 {
        return position;
    }

    if position.col >= terminal_cols {
        position.row += 1;
        position.col = 0;
    }

    if position.col > 0 && position.col + width > terminal_cols {
        position.row += 1;
        position.col = 0;
    }

    position.col += width;
    position
}

fn move_cursor(from: TerminalPosition, to: TerminalPosition) -> Vec<u8> {
    let mut out = Vec::new();

    if from.row > to.row {
        out.extend_from_slice(format!("\x1b[{}A", from.row - to.row).as_bytes());
        out.extend_from_slice(b"\r");
        if to.col > 0 {
            out.extend_from_slice(format!("\x1b[{}C", to.col).as_bytes());
        }
        return out;
    }

    if from.row == to.row && from.col > to.col {
        out.extend_from_slice(format!("\x1b[{}D", from.col - to.col).as_bytes());
    }

    out
}

fn display_width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

fn prompt_for_state(prompt_state: PromptState) -> &'static str {
    match prompt_state {
        PromptState::TopLevel => "> ",
        PromptState::Continuation => "+ ",
        _ => "",
    }
}

fn continuation_prompt() -> &'static str {
    "+ "
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(text: &str) -> EditorSnapshot {
        snapshot_at(text, text.len())
    }

    fn snapshot_at(text: &str, cursor: usize) -> EditorSnapshot {
        EditorSnapshot {
            text: text.to_string(),
            cursor,
            display_cursor: text[..cursor].width(),
            is_complete: true,
        }
    }

    #[test]
    fn appends_first_redraw_after_existing_prompt() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw(&snapshot("abc"), PromptState::TopLevel),
            b"abc".to_vec()
        );
    }

    #[test]
    fn redraw_clears_previous_line() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("abc"), PromptState::TopLevel);

        assert_eq!(
            renderer.redraw(&snapshot("x"), PromptState::TopLevel),
            b"\r\x1b[2K> x".to_vec()
        );
    }

    #[test]
    fn empty_first_redraw_is_noop() {
        let mut renderer = LocalInputRenderer::new();

        assert!(renderer
            .redraw(&snapshot(""), PromptState::TopLevel)
            .is_empty());
        assert!(renderer.clear().is_empty());
    }

    #[test]
    fn positions_single_line_cursor_before_end() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw(&snapshot_at("abc", 1), PromptState::TopLevel),
            b"abc\x1b[2D".to_vec()
        );
    }

    #[test]
    fn clear_removes_multiline_render() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("a\nb"), PromptState::Continuation);

        assert_eq!(renderer.clear(), b"\r\x1b[2K\x1b[1A\r\x1b[2K".to_vec());
        assert!(renderer.clear().is_empty());
    }

    #[test]
    fn clear_to_prompt_restores_prompt_for_child_echo() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("abc"), PromptState::TopLevel);

        assert_eq!(
            renderer.clear_to_prompt(PromptState::TopLevel),
            b"\r\x1b[2K> ".to_vec()
        );
    }

    #[test]
    fn redraws_reverse_search_after_existing_prompt() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw_reverse_search(
                &ReverseSearchSnapshot {
                    query: "alp".to_string(),
                    result: Some("alpha()".to_string()),
                },
                PromptState::TopLevel,
            ),
            b"(reverse-i-search)`alp': alpha()".to_vec()
        );
    }

    #[test]
    fn redraws_reverse_search_failure() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw_reverse_search(
                &ReverseSearchSnapshot {
                    query: "zzz".to_string(),
                    result: None,
                },
                PromptState::TopLevel,
            ),
            b"(reverse-i-search)`zzz': failed reverse-i-search".to_vec()
        );
    }

    #[test]
    fn redraws_multiline_with_continuation_prompt_and_cursor_position() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw(&snapshot_at("alpha\nbeta", 3), PromptState::TopLevel),
            b"alpha\r\n+ beta\x1b[1A\r\x1b[5C".to_vec()
        );
    }

    #[test]
    fn clear_starts_from_cursor_and_removes_all_visual_rows() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot_at("alpha\nbeta", 3), PromptState::TopLevel);

        assert_eq!(
            renderer.clear(),
            b"\x1b[1B\r\x1b[2K\x1b[1A\r\x1b[2K".to_vec()
        );
    }

    #[test]
    fn cursor_position_uses_display_width_and_terminal_columns() {
        let mut renderer = LocalInputRenderer::with_terminal_cols(5);

        assert_eq!(
            renderer.redraw(&snapshot_at("a語bc", "a語".len()), PromptState::TopLevel),
            b"a\xe8\xaa\x9ebc\x1b[1A\r\x1b[5C".to_vec()
        );
    }
}
