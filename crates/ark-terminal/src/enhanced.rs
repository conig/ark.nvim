use unicode_segmentation::UnicodeSegmentation;

use crate::input::EditAction;
use crate::input::EditCommand;
use crate::input::EditorSnapshot;
use crate::input::LineEditor;
use crate::input::ReverseSearchSnapshot;
use crate::keys::ControlInput;
use crate::keys::DecodedInput;
use crate::keys::InputDecoder;
use crate::lsp_client::completion_trigger_from_inserted_text;
use crate::prompt::PromptState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEffect {
    Forward(Vec<u8>),
    Redraw(EditorSnapshot),
    ReverseSearch(ReverseSearchSnapshot),
    Completion {
        snapshot: EditorSnapshot,
        trigger_character: String,
    },
}

#[derive(Debug, Default)]
pub struct EnhancedInputRuntime {
    decoder: InputDecoder,
    editor: LineEditor,
    reverse_search: Option<ReverseSearchState>,
}

#[derive(Debug, Clone)]
struct ReverseSearchState {
    original: EditorSnapshot,
    query: String,
    match_index: Option<usize>,
    result: Option<String>,
}

impl ReverseSearchState {
    fn new(original: EditorSnapshot) -> Self {
        Self {
            original,
            query: String::new(),
            match_index: None,
            result: None,
        }
    }

    fn snapshot(&self) -> ReverseSearchSnapshot {
        ReverseSearchSnapshot {
            query: self.query.clone(),
            result: self.result.clone(),
        }
    }
}

impl EnhancedInputRuntime {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn handle_bytes(&mut self, bytes: &[u8], prompt_state: PromptState) -> Vec<InputEffect> {
        if !is_editable_prompt(prompt_state) {
            self.reverse_search = None;
            return vec![InputEffect::Forward(bytes.to_vec())];
        }

        let mut effects = Vec::new();
        for decoded in self.decoder.push_bytes(bytes) {
            self.handle_decoded(decoded, &mut effects);
        }

        compact_batch_effects(effects)
    }

    pub fn snapshot(&self) -> EditorSnapshot {
        self.editor.snapshot()
    }

    pub fn replace_text_and_cursor(&mut self, text: String, cursor: usize) -> EditorSnapshot {
        self.reverse_search = None;
        self.editor.replace_text_and_cursor(text, cursor);
        self.editor.snapshot()
    }

    fn handle_decoded(&mut self, decoded: DecodedInput, effects: &mut Vec<InputEffect>) {
        match decoded {
            decoded if self.reverse_search.is_some() => {
                self.handle_reverse_search(decoded, effects);
            },
            DecodedInput::Edit(command) => self.handle_edit(command, effects),
            DecodedInput::Control(control) => self.handle_control(control, effects),
            DecodedInput::Raw(bytes) => effects.push(InputEffect::Forward(bytes)),
        }
    }

    fn handle_edit(&mut self, command: EditCommand, effects: &mut Vec<InputEffect>) {
        let completion_trigger = match &command {
            EditCommand::Insert(text) => completion_trigger_from_inserted_text(text),
            _ => None,
        };

        match self.editor.handle(command) {
            EditAction::Redraw => {
                let snapshot = self.editor.snapshot();
                effects.push(InputEffect::Redraw(snapshot.clone()));
                if let Some(trigger_character) = completion_trigger {
                    effects.push(InputEffect::Completion {
                        snapshot,
                        trigger_character: trigger_character.to_string(),
                    });
                }
            },
            EditAction::Submit(input) => {
                let mut bytes = input.into_bytes();
                bytes.push(b'\n');
                effects.push(InputEffect::Forward(bytes));
                effects.push(InputEffect::Redraw(self.editor.snapshot()));
            },
        }
    }

    fn handle_control(&mut self, control: ControlInput, effects: &mut Vec<InputEffect>) {
        match control {
            ControlInput::Interrupt => {
                self.editor.clear();
                effects.push(InputEffect::Forward(vec![0x03]));
                effects.push(InputEffect::Redraw(self.editor.snapshot()));
            },
            ControlInput::Suspend => effects.push(InputEffect::Forward(vec![0x1a])),
            ControlInput::Cancel => {},
            ControlInput::EofOrDelete => {
                if self.editor.snapshot().text.is_empty() {
                    effects.push(InputEffect::Forward(vec![0x04]));
                } else {
                    self.handle_edit(EditCommand::Delete, effects);
                }
            },
            ControlInput::ReverseSearch => self.start_reverse_search(effects),
        }
    }

    fn start_reverse_search(&mut self, effects: &mut Vec<InputEffect>) {
        self.reverse_search = Some(ReverseSearchState::new(self.editor.snapshot()));
        self.redraw_reverse_search(effects);
    }

    fn handle_reverse_search(&mut self, decoded: DecodedInput, effects: &mut Vec<InputEffect>) {
        match decoded {
            DecodedInput::Edit(EditCommand::Insert(text)) => {
                let Some(state) = &mut self.reverse_search else {
                    return;
                };
                state.query.push_str(&text);
                self.refresh_reverse_search(None);
                self.redraw_reverse_search(effects);
            },
            DecodedInput::Edit(EditCommand::Backspace) => {
                let Some(state) = &mut self.reverse_search else {
                    return;
                };
                pop_grapheme(&mut state.query);
                self.refresh_reverse_search(None);
                self.redraw_reverse_search(effects);
            },
            DecodedInput::Edit(EditCommand::Enter) => {
                self.accept_reverse_search_and_submit(effects);
            },
            DecodedInput::Control(ControlInput::ReverseSearch) => {
                let before = self
                    .reverse_search
                    .as_ref()
                    .and_then(|state| state.match_index);
                self.refresh_reverse_search(before);
                self.redraw_reverse_search(effects);
            },
            DecodedInput::Control(ControlInput::Cancel) => {
                self.cancel_reverse_search(effects);
            },
            DecodedInput::Control(ControlInput::Interrupt) => {
                self.reverse_search = None;
                self.editor.clear();
                effects.push(InputEffect::Forward(vec![0x03]));
                effects.push(InputEffect::Redraw(self.editor.snapshot()));
            },
            DecodedInput::Control(ControlInput::Suspend) => {
                self.reverse_search = None;
                effects.push(InputEffect::Forward(vec![0x1a]));
            },
            DecodedInput::Control(ControlInput::EofOrDelete) => {
                self.cancel_reverse_search(effects);
            },
            DecodedInput::Edit(command) => {
                self.accept_reverse_search(effects);
                self.handle_edit(command, effects);
            },
            DecodedInput::Raw(bytes) => {
                self.reverse_search = None;
                effects.push(InputEffect::Forward(bytes));
            },
        }
    }

    fn refresh_reverse_search(&mut self, before_index: Option<usize>) {
        let Some(state) = &mut self.reverse_search else {
            return;
        };

        if let Some((index, result)) = self.editor.history_match_before(&state.query, before_index)
        {
            state.match_index = Some(index);
            state.result = Some(result.clone());
            self.editor.replace_text(result);
        } else {
            state.match_index = None;
            state.result = None;
            self.editor.restore(&state.original);
        }
    }

    fn redraw_reverse_search(&mut self, effects: &mut Vec<InputEffect>) {
        let Some(state) = &self.reverse_search else {
            return;
        };
        effects.push(InputEffect::ReverseSearch(state.snapshot()));
    }

    fn accept_reverse_search(&mut self, effects: &mut Vec<InputEffect>) {
        self.reverse_search = None;
        effects.push(InputEffect::Redraw(self.editor.snapshot()));
    }

    fn accept_reverse_search_and_submit(&mut self, effects: &mut Vec<InputEffect>) {
        self.reverse_search = None;
        self.handle_edit(EditCommand::Enter, effects);
    }

    fn cancel_reverse_search(&mut self, effects: &mut Vec<InputEffect>) {
        let Some(state) = self.reverse_search.take() else {
            return;
        };
        self.editor.restore(&state.original);
        effects.push(InputEffect::Redraw(self.editor.snapshot()));
    }
}

fn is_editable_prompt(prompt_state: PromptState) -> bool {
    matches!(
        prompt_state,
        PromptState::TopLevel | PromptState::Continuation
    )
}

fn compact_batch_effects(effects: Vec<InputEffect>) -> Vec<InputEffect> {
    let mut compacted = Vec::with_capacity(effects.len());

    for effect in effects {
        match effect {
            InputEffect::Redraw(snapshot) => {
                if matches!(compacted.last(), Some(InputEffect::Completion { .. })) {
                    compacted.pop();
                }
                if let Some(InputEffect::Redraw(previous)) = compacted.last_mut() {
                    *previous = snapshot;
                } else {
                    compacted.push(InputEffect::Redraw(snapshot));
                }
            },
            InputEffect::Forward(bytes) => {
                if matches!(compacted.last(), Some(InputEffect::Completion { .. })) {
                    compacted.pop();
                }
                if matches!(compacted.last(), Some(InputEffect::Redraw(_))) {
                    compacted.pop();
                }
                compacted.push(InputEffect::Forward(bytes));
            },
            InputEffect::ReverseSearch(snapshot) => {
                compacted.push(InputEffect::ReverseSearch(snapshot));
            },
            InputEffect::Completion {
                snapshot,
                trigger_character,
            } => {
                if let Some(InputEffect::Completion {
                    snapshot: previous_snapshot,
                    trigger_character: previous_trigger,
                }) = compacted.last_mut()
                {
                    *previous_snapshot = snapshot;
                    *previous_trigger = trigger_character;
                } else {
                    compacted.push(InputEffect::Completion {
                        snapshot,
                        trigger_character,
                    });
                }
            },
        }
    }

    compacted
}

fn pop_grapheme(text: &mut String) {
    let Some((index, _)) = text.grapheme_indices(true).next_back() else {
        return;
    };
    text.truncate(index);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(effect: &InputEffect) -> Option<&str> {
        match effect {
            InputEffect::Redraw(snapshot) => Some(snapshot.text.as_str()),
            _ => None,
        }
    }

    fn completion(effect: &InputEffect) -> Option<(&str, &str)> {
        match effect {
            InputEffect::Completion {
                snapshot,
                trigger_character,
            } => Some((snapshot.text.as_str(), trigger_character.as_str())),
            _ => None,
        }
    }

    #[test]
    fn forwards_bytes_when_prompt_is_not_editable() {
        let mut runtime = EnhancedInputRuntime::new();

        assert_eq!(
            runtime.handle_bytes(b"abc", PromptState::PassThrough),
            vec![InputEffect::Forward(b"abc".to_vec())]
        );
    }

    #[test]
    fn edits_locally_and_submits_complete_input() {
        let mut runtime = EnhancedInputRuntime::new();

        assert_eq!(
            text(&runtime.handle_bytes(b"a", PromptState::TopLevel)[0]),
            Some("a")
        );
        assert_eq!(
            text(&runtime.handle_bytes(b"b", PromptState::TopLevel)[0]),
            Some("ab")
        );
        assert_eq!(
            text(&runtime.handle_bytes(b"c", PromptState::TopLevel)[0]),
            Some("abc")
        );
        assert_eq!(
            text(&runtime.handle_bytes(b"\x08", PromptState::TopLevel)[0]),
            Some("ab")
        );
        assert_eq!(
            text(&runtime.handle_bytes(b"d", PromptState::TopLevel)[0]),
            Some("abd")
        );

        let effects = runtime.handle_bytes(b"\n", PromptState::TopLevel);
        assert_eq!(effects[0], InputEffect::Forward(b"abd\n".to_vec()));
        assert_eq!(text(&effects[1]), Some(""));
    }

    #[test]
    fn batched_submit_skips_intermediate_redraws() {
        let mut runtime = EnhancedInputRuntime::new();

        let effects = runtime.handle_bytes(b"abc\x08d\n", PromptState::TopLevel);

        assert_eq!(effects[0], InputEffect::Forward(b"abd\n".to_vec()));
        assert_eq!(text(&effects[1]), Some(""));
    }

    #[test]
    fn reports_completion_after_trigger_character_insert() {
        let mut runtime = EnhancedInputRuntime::new();

        let effects = runtime.handle_bytes(b"mtcars$", PromptState::TopLevel);

        assert_eq!(effects.len(), 2);
        assert_eq!(text(&effects[0]), Some("mtcars$"));
        assert_eq!(completion(&effects[1]), Some(("mtcars$", "$")));
    }

    #[test]
    fn drops_stale_completion_when_batch_continues_after_trigger() {
        let mut runtime = EnhancedInputRuntime::new();

        let effects = runtime.handle_bytes(b"mtcars$x", PromptState::TopLevel);

        assert_eq!(effects.len(), 1);
        assert_eq!(text(&effects[0]), Some("mtcars$x"));
    }

    #[test]
    fn replaces_text_and_cursor_for_completion_acceptance() {
        let mut runtime = EnhancedInputRuntime::new();
        runtime.handle_bytes(b"mtcars$m", PromptState::TopLevel);

        let snapshot =
            runtime.replace_text_and_cursor("mtcars$mpg".to_string(), "mtcars$mpg".len());

        assert_eq!(snapshot.text, "mtcars$mpg");
        assert_eq!(snapshot.cursor, "mtcars$mpg".len());
    }

    #[test]
    fn keeps_incomplete_input_local_until_complete() {
        let mut runtime = EnhancedInputRuntime::new();

        let effects = runtime.handle_bytes(b"if (TRUE) {\n1\n}", PromptState::TopLevel);

        assert!(!effects
            .iter()
            .any(|effect| matches!(effect, InputEffect::Forward(_))));
        assert_eq!(runtime.snapshot().text, "if (TRUE) {\n1\n}");

        let effects = runtime.handle_bytes(b"\n", PromptState::Continuation);
        assert_eq!(
            effects[0],
            InputEffect::Forward(b"if (TRUE) {\n1\n}\n".to_vec())
        );
    }

    #[test]
    fn bracketed_paste_is_local_until_enter() {
        let mut runtime = EnhancedInputRuntime::new();

        let effects = runtime.handle_bytes(b"\x1b[200~x <- 1\nx\x1b[201~", PromptState::TopLevel);

        assert_eq!(effects.len(), 1);
        assert_eq!(text(&effects[0]), Some("x <- 1\nx"));
        let effects = runtime.handle_bytes(b"\n", PromptState::TopLevel);
        assert_eq!(effects[0], InputEffect::Forward(b"x <- 1\nx\n".to_vec()));
    }

    #[test]
    fn eof_deletes_forward_when_buffer_is_not_empty() {
        let mut runtime = EnhancedInputRuntime::new();

        runtime.handle_bytes(b"ab", PromptState::TopLevel);
        runtime.handle_bytes(b"\x1b[D", PromptState::TopLevel);
        let effects = runtime.handle_bytes(&[0x04], PromptState::TopLevel);

        assert_eq!(text(&effects[0]), Some("a"));
    }

    #[test]
    fn eof_forwards_when_buffer_is_empty() {
        let mut runtime = EnhancedInputRuntime::new();

        assert_eq!(runtime.handle_bytes(&[0x04], PromptState::TopLevel), vec![
            InputEffect::Forward(vec![0x04])
        ]);
    }

    #[test]
    fn interrupt_clears_local_buffer_and_forwards_control_c() {
        let mut runtime = EnhancedInputRuntime::new();

        runtime.handle_bytes(b"abc", PromptState::TopLevel);
        let effects = runtime.handle_bytes(&[0x03], PromptState::TopLevel);

        assert_eq!(effects[0], InputEffect::Forward(vec![0x03]));
        assert_eq!(text(&effects[1]), Some(""));
    }

    #[test]
    fn reverse_search_is_reported_as_explicit_effect() {
        let mut runtime = EnhancedInputRuntime::new();

        assert_eq!(runtime.handle_bytes(&[0x12], PromptState::TopLevel), vec![
            InputEffect::ReverseSearch(ReverseSearchSnapshot {
                query: String::new(),
                result: None,
            })
        ]);
    }

    #[test]
    fn reverse_search_submits_latest_matching_history() {
        let mut runtime = EnhancedInputRuntime::new();
        runtime.handle_bytes(b"alpha()\n", PromptState::TopLevel);
        runtime.handle_bytes(b"beta()\n", PromptState::TopLevel);
        runtime.handle_bytes(b"alpha(2)\n", PromptState::TopLevel);

        let effects = runtime.handle_bytes(b"\x12alpha\n", PromptState::TopLevel);

        assert!(
            effects.contains(&InputEffect::ReverseSearch(ReverseSearchSnapshot {
                query: "alpha".to_string(),
                result: Some("alpha(2)".to_string()),
            }))
        );
        assert_eq!(
            effects
                .iter()
                .find(|effect| matches!(effect, InputEffect::Forward(_))),
            Some(&InputEffect::Forward(b"alpha(2)\n".to_vec()))
        );
    }

    #[test]
    fn reverse_search_repeats_to_older_match() {
        let mut runtime = EnhancedInputRuntime::new();
        runtime.handle_bytes(b"alpha()\n", PromptState::TopLevel);
        runtime.handle_bytes(b"alpha(2)\n", PromptState::TopLevel);

        let effects = runtime.handle_bytes(b"\x12alpha\x12\n", PromptState::TopLevel);

        assert!(
            effects.contains(&InputEffect::ReverseSearch(ReverseSearchSnapshot {
                query: "alpha".to_string(),
                result: Some("alpha()".to_string()),
            }))
        );
        assert!(effects.contains(&InputEffect::Forward(b"alpha()\n".to_vec())));
    }

    #[test]
    fn reverse_search_cancel_restores_original_draft() {
        let mut runtime = EnhancedInputRuntime::new();
        runtime.handle_bytes(b"alpha()\n", PromptState::TopLevel);
        runtime.handle_bytes(b"draft", PromptState::TopLevel);

        let effects = runtime.handle_bytes(b"\x12alpha\x07", PromptState::TopLevel);

        assert_eq!(text(effects.last().unwrap()), Some("draft"));
        assert_eq!(runtime.snapshot().text, "draft");
    }
}
