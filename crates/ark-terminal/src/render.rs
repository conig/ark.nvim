use unicode_segmentation::UnicodeSegmentation;

use crate::input::EditorSnapshot;
use crate::prompt::PromptState;

#[derive(Debug, Default)]
pub struct LocalInputRenderer {
    rendered: Option<RenderedInput>,
}

#[derive(Debug)]
struct RenderedInput {
    text: String,
}

impl LocalInputRenderer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn redraw(&mut self, snapshot: &EditorSnapshot, prompt_state: PromptState) -> Vec<u8> {
        let had_rendered = self.rendered.is_some();
        let mut out = self.clear();
        if had_rendered {
            out.extend_from_slice(prompt_for_state(prompt_state).as_bytes());
        }
        out.extend_from_slice(snapshot.text.as_bytes());

        if !snapshot.text.contains('\n') {
            let end = snapshot.text.graphemes(true).count();
            if end > snapshot.display_cursor {
                out.extend_from_slice(
                    format!("\x1b[{}D", end - snapshot.display_cursor).as_bytes(),
                );
            }
        }

        if had_rendered || !snapshot.text.is_empty() {
            self.rendered = Some(RenderedInput {
                text: snapshot.text.clone(),
            });
        }
        out
    }

    pub fn clear(&mut self) -> Vec<u8> {
        let Some(rendered) = self.rendered.take() else {
            return Vec::new();
        };

        let line_count = rendered.text.split('\n').count().max(1);
        let mut out = Vec::new();
        out.extend_from_slice(b"\r\x1b[2K");
        for _ in 1..line_count {
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

fn prompt_for_state(prompt_state: PromptState) -> &'static str {
    match prompt_state {
        PromptState::TopLevel => "> ",
        PromptState::Continuation => "+ ",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(text: &str, display_cursor: usize) -> EditorSnapshot {
        EditorSnapshot {
            text: text.to_string(),
            cursor: text.len(),
            display_cursor,
            is_complete: true,
        }
    }

    #[test]
    fn appends_first_redraw_after_existing_prompt() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw(&snapshot("abc", 3), PromptState::TopLevel),
            b"abc".to_vec()
        );
    }

    #[test]
    fn redraw_clears_previous_line() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("abc", 3), PromptState::TopLevel);

        assert_eq!(
            renderer.redraw(&snapshot("x", 1), PromptState::TopLevel),
            b"\r\x1b[2K> x".to_vec()
        );
    }

    #[test]
    fn empty_first_redraw_is_noop() {
        let mut renderer = LocalInputRenderer::new();

        assert!(renderer
            .redraw(&snapshot("", 0), PromptState::TopLevel)
            .is_empty());
        assert!(renderer.clear().is_empty());
    }

    #[test]
    fn positions_single_line_cursor_before_end() {
        let mut renderer = LocalInputRenderer::new();

        assert_eq!(
            renderer.redraw(&snapshot("abc", 1), PromptState::TopLevel),
            b"abc\x1b[2D".to_vec()
        );
    }

    #[test]
    fn clear_removes_multiline_render() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("a\nb", 3), PromptState::Continuation);

        assert_eq!(renderer.clear(), b"\r\x1b[2K\x1b[1A\r\x1b[2K".to_vec());
        assert!(renderer.clear().is_empty());
    }

    #[test]
    fn clear_to_prompt_restores_prompt_for_child_echo() {
        let mut renderer = LocalInputRenderer::new();
        renderer.redraw(&snapshot("abc", 3), PromptState::TopLevel);

        assert_eq!(
            renderer.clear_to_prompt(PromptState::TopLevel),
            b"\r\x1b[2K> ".to_vec()
        );
    }
}
