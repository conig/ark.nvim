use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditCommand {
    Insert(String),
    Enter,
    Backspace,
    Delete,
    MoveLeft,
    MoveRight,
    MoveWordLeft,
    MoveWordRight,
    Home,
    End,
    KillToEnd,
    Yank,
    HistoryPrevious,
    HistoryNext,
    ReverseSearch(String),
    BracketedPaste(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditAction {
    Redraw,
    Submit(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditorSnapshot {
    pub text: String,
    pub cursor: usize,
    pub display_cursor: usize,
    pub is_complete: bool,
}

#[derive(Debug, Clone)]
pub struct LineEditor {
    buffer: String,
    cursor: usize,
    history: Vec<String>,
    history_position: Option<usize>,
    draft_before_history: Option<String>,
    yank: String,
}

impl Default for LineEditor {
    fn default() -> Self {
        Self::new()
    }
}

impl LineEditor {
    pub fn new() -> Self {
        Self {
            buffer: String::new(),
            cursor: 0,
            history: Vec::new(),
            history_position: None,
            draft_before_history: None,
            yank: String::new(),
        }
    }

    pub fn snapshot(&self) -> EditorSnapshot {
        EditorSnapshot {
            text: self.buffer.clone(),
            cursor: self.cursor,
            display_cursor: display_width(&self.buffer[..self.cursor]),
            is_complete: is_complete_r_input(&self.buffer),
        }
    }

    pub fn history(&self) -> &[String] {
        &self.history
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
        self.cursor = 0;
        self.history_position = None;
        self.draft_before_history = None;
    }

    pub fn handle(&mut self, command: EditCommand) -> EditAction {
        match command {
            EditCommand::Insert(text) => {
                self.cancel_history_navigation();
                self.insert_text(&text);
                EditAction::Redraw
            },
            EditCommand::Enter => self.handle_enter(),
            EditCommand::Backspace => {
                self.cancel_history_navigation();
                self.backspace();
                EditAction::Redraw
            },
            EditCommand::Delete => {
                self.cancel_history_navigation();
                self.delete();
                EditAction::Redraw
            },
            EditCommand::MoveLeft => {
                self.cursor = previous_grapheme_boundary(&self.buffer, self.cursor);
                EditAction::Redraw
            },
            EditCommand::MoveRight => {
                self.cursor = next_grapheme_boundary(&self.buffer, self.cursor);
                EditAction::Redraw
            },
            EditCommand::MoveWordLeft => {
                self.cursor = previous_word_boundary(&self.buffer, self.cursor);
                EditAction::Redraw
            },
            EditCommand::MoveWordRight => {
                self.cursor = next_word_boundary(&self.buffer, self.cursor);
                EditAction::Redraw
            },
            EditCommand::Home => {
                self.cursor = 0;
                EditAction::Redraw
            },
            EditCommand::End => {
                self.cursor = self.buffer.len();
                EditAction::Redraw
            },
            EditCommand::KillToEnd => {
                self.cancel_history_navigation();
                self.yank = self.buffer[self.cursor..].to_string();
                self.buffer.truncate(self.cursor);
                EditAction::Redraw
            },
            EditCommand::Yank => {
                self.cancel_history_navigation();
                let yank = self.yank.clone();
                self.insert_text(&yank);
                EditAction::Redraw
            },
            EditCommand::HistoryPrevious => {
                self.history_previous();
                EditAction::Redraw
            },
            EditCommand::HistoryNext => {
                self.history_next();
                EditAction::Redraw
            },
            EditCommand::ReverseSearch(query) => {
                self.reverse_search(&query);
                EditAction::Redraw
            },
            EditCommand::BracketedPaste(text) => {
                self.cancel_history_navigation();
                self.insert_text(&normalize_paste(&text));
                EditAction::Redraw
            },
        }
    }

    fn insert_text(&mut self, text: &str) {
        self.buffer.insert_str(self.cursor, text);
        self.cursor += text.len();
    }

    fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }

        let previous = previous_grapheme_boundary(&self.buffer, self.cursor);
        self.buffer.replace_range(previous..self.cursor, "");
        self.cursor = previous;
    }

    fn delete(&mut self) {
        if self.cursor == self.buffer.len() {
            return;
        }

        let next = next_grapheme_boundary(&self.buffer, self.cursor);
        self.buffer.replace_range(self.cursor..next, "");
    }

    fn handle_enter(&mut self) -> EditAction {
        if self.buffer.trim().is_empty() {
            self.buffer.clear();
            self.cursor = 0;
            return EditAction::Submit(String::new());
        }

        if !is_complete_r_input(&self.buffer) {
            self.insert_text("\n");
            return EditAction::Redraw;
        }

        let submitted = self.buffer.clone();
        self.push_history(submitted.clone());
        self.buffer.clear();
        self.cursor = 0;
        self.history_position = None;
        self.draft_before_history = None;
        EditAction::Submit(submitted)
    }

    fn push_history(&mut self, submitted: String) {
        if submitted.trim().is_empty() {
            return;
        }
        if self.history.last() == Some(&submitted) {
            return;
        }
        self.history.push(submitted);
    }

    fn history_previous(&mut self) {
        if self.history.is_empty() {
            return;
        }

        let next_position = match self.history_position {
            Some(0) => 0,
            Some(position) => position - 1,
            None => {
                self.draft_before_history = Some(self.buffer.clone());
                self.history.len() - 1
            },
        };

        self.history_position = Some(next_position);
        self.buffer = self.history[next_position].clone();
        self.cursor = self.buffer.len();
    }

    fn history_next(&mut self) {
        let Some(position) = self.history_position else {
            return;
        };

        if position + 1 < self.history.len() {
            let next = position + 1;
            self.history_position = Some(next);
            self.buffer = self.history[next].clone();
        } else {
            self.history_position = None;
            self.buffer = self.draft_before_history.take().unwrap_or_default();
        }

        self.cursor = self.buffer.len();
    }

    fn reverse_search(&mut self, query: &str) {
        if query.is_empty() {
            return;
        }

        let Some(index) = self.history.iter().rposition(|entry| entry.contains(query)) else {
            return;
        };

        if self.history_position.is_none() {
            self.draft_before_history = Some(self.buffer.clone());
        }
        self.history_position = Some(index);
        self.buffer = self.history[index].clone();
        self.cursor = self.buffer.len();
    }

    fn cancel_history_navigation(&mut self) {
        self.history_position = None;
        self.draft_before_history = None;
    }
}

pub fn is_complete_r_input(input: &str) -> bool {
    let mut stack = Vec::new();
    let mut string: Option<char> = None;
    let mut escaped = false;
    let mut in_comment = false;

    for ch in input.chars() {
        if in_comment {
            if ch == '\n' {
                in_comment = false;
            }
            continue;
        }

        if let Some(quote) = string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == quote {
                string = None;
            }
            continue;
        }

        match ch {
            '\'' | '"' => string = Some(ch),
            '#' => in_comment = true,
            '(' | '[' | '{' => stack.push(ch),
            ')' => {
                if stack.pop() != Some('(') {
                    return true;
                }
            },
            ']' => {
                if stack.pop() != Some('[') {
                    return true;
                }
            },
            '}' if stack.pop() != Some('{') => return true,
            '}' => {},
            _ => {},
        }
    }

    stack.is_empty() && string.is_none()
}

fn normalize_paste(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn display_width(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

fn previous_grapheme_boundary(text: &str, cursor: usize) -> usize {
    UnicodeSegmentation::grapheme_indices(text, true)
        .map(|(index, _)| index)
        .take_while(|index| *index < cursor)
        .last()
        .unwrap_or(0)
}

fn next_grapheme_boundary(text: &str, cursor: usize) -> usize {
    UnicodeSegmentation::grapheme_indices(text, true)
        .map(|(index, grapheme)| index + grapheme.len())
        .find(|index| *index > cursor)
        .unwrap_or(text.len())
}

fn previous_word_boundary(text: &str, cursor: usize) -> usize {
    let before = &text[..cursor];
    let mut seen_word = false;

    for (index, grapheme) in UnicodeSegmentation::grapheme_indices(before, true).rev() {
        if grapheme.chars().all(char::is_whitespace) {
            if seen_word {
                return index + grapheme.len();
            }
        } else {
            seen_word = true;
        }
    }

    0
}

fn next_word_boundary(text: &str, cursor: usize) -> usize {
    let after = &text[cursor..];
    let mut seen_word = false;

    for (offset, grapheme) in UnicodeSegmentation::grapheme_indices(after, true) {
        if grapheme.chars().all(char::is_whitespace) {
            if seen_word {
                return cursor + offset;
            }
        } else {
            seen_word = true;
        }
    }

    text.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn insert(editor: &mut LineEditor, text: &str) {
        assert_eq!(
            editor.handle(EditCommand::Insert(text.to_string())),
            EditAction::Redraw
        );
    }

    #[test]
    fn inserts_and_submits_complete_input() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "mean(x)");

        assert_eq!(
            editor.handle(EditCommand::Enter),
            EditAction::Submit("mean(x)".to_string())
        );
        assert_eq!(editor.snapshot().text, "");
        assert_eq!(editor.history(), &["mean(x)".to_string()]);
    }

    #[test]
    fn enter_extends_incomplete_multiline_input() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "if (TRUE) {");

        assert_eq!(editor.handle(EditCommand::Enter), EditAction::Redraw);
        assert_eq!(editor.snapshot().text, "if (TRUE) {\n");
        assert!(!editor.snapshot().is_complete);

        insert(&mut editor, "1\n}");
        assert_eq!(
            editor.handle(EditCommand::Enter),
            EditAction::Submit("if (TRUE) {\n1\n}".to_string())
        );
    }

    #[test]
    fn bracketed_paste_normalizes_newlines_without_submitting() {
        let mut editor = LineEditor::new();
        assert_eq!(
            editor.handle(EditCommand::BracketedPaste(
                "if (TRUE) {\r\n1\r\n}".to_string()
            )),
            EditAction::Redraw
        );

        assert_eq!(editor.snapshot().text, "if (TRUE) {\n1\n}");
        assert_eq!(
            editor.handle(EditCommand::Enter),
            EditAction::Submit("if (TRUE) {\n1\n}".to_string())
        );
    }

    #[test]
    fn moves_and_deletes_by_grapheme() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "a\u{301}b");

        assert_eq!(editor.snapshot().display_cursor, 2);
        editor.handle(EditCommand::MoveLeft);
        assert_eq!(editor.snapshot().display_cursor, 1);
        editor.handle(EditCommand::Backspace);

        assert_eq!(editor.snapshot().text, "b");
        assert_eq!(editor.snapshot().display_cursor, 0);
    }

    #[test]
    fn display_cursor_uses_terminal_cell_width() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "a語b");

        assert_eq!(editor.snapshot().display_cursor, 4);
        editor.handle(EditCommand::MoveLeft);
        assert_eq!(editor.snapshot().display_cursor, 3);
    }

    #[test]
    fn delete_removes_next_grapheme() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "a\u{301}b");
        editor.handle(EditCommand::Home);
        editor.handle(EditCommand::Delete);

        assert_eq!(editor.snapshot().text, "b");
        assert_eq!(editor.snapshot().cursor, 0);
    }

    #[test]
    fn supports_word_movement_and_kill_yank() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "alpha beta gamma");
        editor.handle(EditCommand::MoveWordLeft);
        assert_eq!(
            editor.snapshot().text[editor.snapshot().cursor..].to_string(),
            "gamma"
        );

        editor.handle(EditCommand::KillToEnd);
        assert_eq!(editor.snapshot().text, "alpha beta ");
        editor.handle(EditCommand::Yank);
        assert_eq!(editor.snapshot().text, "alpha beta gamma");
    }

    #[test]
    fn navigates_history_and_restores_draft() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "first");
        editor.handle(EditCommand::Enter);
        insert(&mut editor, "second");
        editor.handle(EditCommand::Enter);
        insert(&mut editor, "draft");

        editor.handle(EditCommand::HistoryPrevious);
        assert_eq!(editor.snapshot().text, "second");
        editor.handle(EditCommand::HistoryPrevious);
        assert_eq!(editor.snapshot().text, "first");
        editor.handle(EditCommand::HistoryNext);
        assert_eq!(editor.snapshot().text, "second");
        editor.handle(EditCommand::HistoryNext);
        assert_eq!(editor.snapshot().text, "draft");
    }

    #[test]
    fn reverse_search_selects_latest_matching_history() {
        let mut editor = LineEditor::new();
        insert(&mut editor, "alpha()");
        editor.handle(EditCommand::Enter);
        insert(&mut editor, "beta()");
        editor.handle(EditCommand::Enter);
        insert(&mut editor, "alpha(2)");
        editor.handle(EditCommand::Enter);

        editor.handle(EditCommand::ReverseSearch("alpha".to_string()));
        assert_eq!(editor.snapshot().text, "alpha(2)");
    }

    #[test]
    fn completeness_ignores_comments_and_escaped_quotes() {
        assert!(is_complete_r_input(r#"x <- "quote\"""#));
        assert!(is_complete_r_input("x <- 1 # {"));
        assert!(!is_complete_r_input("list("));
        assert!(!is_complete_r_input(r#"x <- "unterminated"#));
    }
}
