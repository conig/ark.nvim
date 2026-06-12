use crate::input::EditAction;
use crate::input::EditCommand;
use crate::input::EditorSnapshot;
use crate::input::LineEditor;
use crate::keys::ControlInput;
use crate::keys::DecodedInput;
use crate::keys::InputDecoder;
use crate::prompt::PromptState;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputEffect {
    Forward(Vec<u8>),
    Redraw(EditorSnapshot),
    ReverseSearchRequested,
}

#[derive(Debug, Default)]
pub struct EnhancedInputRuntime {
    decoder: InputDecoder,
    editor: LineEditor,
}

impl EnhancedInputRuntime {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn handle_bytes(&mut self, bytes: &[u8], prompt_state: PromptState) -> Vec<InputEffect> {
        if !is_editable_prompt(prompt_state) {
            return vec![InputEffect::Forward(bytes.to_vec())];
        }

        let mut effects = Vec::new();
        for decoded in self.decoder.push_bytes(bytes) {
            self.handle_decoded(decoded, &mut effects);
        }

        effects
    }

    pub fn snapshot(&self) -> EditorSnapshot {
        self.editor.snapshot()
    }

    fn handle_decoded(&mut self, decoded: DecodedInput, effects: &mut Vec<InputEffect>) {
        match decoded {
            DecodedInput::Edit(command) => self.handle_edit(command, effects),
            DecodedInput::Control(control) => self.handle_control(control, effects),
            DecodedInput::Raw(bytes) => effects.push(InputEffect::Forward(bytes)),
        }
    }

    fn handle_edit(&mut self, command: EditCommand, effects: &mut Vec<InputEffect>) {
        match self.editor.handle(command) {
            EditAction::Redraw => effects.push(InputEffect::Redraw(self.editor.snapshot())),
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
            ControlInput::EofOrDelete => {
                if self.editor.snapshot().text.is_empty() {
                    effects.push(InputEffect::Forward(vec![0x04]));
                } else {
                    self.handle_edit(EditCommand::Delete, effects);
                }
            },
            ControlInput::ReverseSearch => effects.push(InputEffect::ReverseSearchRequested),
        }
    }
}

fn is_editable_prompt(prompt_state: PromptState) -> bool {
    matches!(
        prompt_state,
        PromptState::TopLevel | PromptState::Continuation
    )
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

        let effects = runtime.handle_bytes(b"abc\x08d\n", PromptState::TopLevel);

        assert_eq!(text(&effects[0]), Some("a"));
        assert_eq!(text(&effects[1]), Some("ab"));
        assert_eq!(text(&effects[2]), Some("abc"));
        assert_eq!(text(&effects[3]), Some("ab"));
        assert_eq!(text(&effects[4]), Some("abd"));
        assert_eq!(effects[5], InputEffect::Forward(b"abd\n".to_vec()));
        assert_eq!(text(&effects[6]), Some(""));
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
            InputEffect::ReverseSearchRequested
        ]);
    }
}
