use crate::input::EditCommand;

const ESC: u8 = 0x1b;
const BACKSPACE: u8 = 0x08;
const DEL: u8 = 0x7f;
const BRACKETED_PASTE_START: &[u8] = b"\x1b[200~";
const BRACKETED_PASTE_END: &[u8] = b"\x1b[201~";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodedInput {
    Edit(EditCommand),
    Control(ControlInput),
    Raw(Vec<u8>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlInput {
    Interrupt,
    Suspend,
    EofOrDelete,
    ReverseSearch,
    Cancel,
}

#[derive(Debug, Default)]
pub struct InputDecoder {
    pending: Vec<u8>,
    paste_buffer: Vec<u8>,
    paste_mode: bool,
}

impl InputDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push_bytes(&mut self, bytes: &[u8]) -> Vec<DecodedInput> {
        self.pending.extend_from_slice(bytes);
        let mut out = Vec::new();

        loop {
            if self.paste_mode {
                if let Some(index) = find_subslice(&self.pending, BRACKETED_PASTE_END) {
                    self.paste_buffer.extend_from_slice(&self.pending[..index]);
                    self.pending.drain(..index + BRACKETED_PASTE_END.len());
                    let text = String::from_utf8_lossy(&self.paste_buffer).into_owned();
                    self.paste_buffer.clear();
                    self.paste_mode = false;
                    out.push(DecodedInput::Edit(EditCommand::BracketedPaste(text)));
                    continue;
                }

                self.paste_buffer.append(&mut self.pending);
                break;
            }

            if self.pending.is_empty() {
                break;
            }

            if self.pending.starts_with(BRACKETED_PASTE_START) {
                self.pending.drain(..BRACKETED_PASTE_START.len());
                self.paste_mode = true;
                continue;
            }

            if let Some(decoded) = self.decode_one() {
                out.push(decoded);
                continue;
            }

            break;
        }

        out
    }

    fn decode_one(&mut self) -> Option<DecodedInput> {
        match self.pending[0] {
            b'\r' | b'\n' => Some(self.consume_edit(1, EditCommand::Enter)),
            BACKSPACE | DEL => Some(self.consume_edit(1, EditCommand::Backspace)),
            0x01 => Some(self.consume_edit(1, EditCommand::Home)),
            0x02 => Some(self.consume_edit(1, EditCommand::MoveLeft)),
            0x03 => Some(self.consume_control(1, ControlInput::Interrupt)),
            0x04 => Some(self.consume_control(1, ControlInput::EofOrDelete)),
            0x05 => Some(self.consume_edit(1, EditCommand::End)),
            0x06 => Some(self.consume_edit(1, EditCommand::MoveRight)),
            0x07 => Some(self.consume_control(1, ControlInput::Cancel)),
            0x0b => Some(self.consume_edit(1, EditCommand::KillToEnd)),
            0x0e => Some(self.consume_edit(1, EditCommand::HistoryNext)),
            0x10 => Some(self.consume_edit(1, EditCommand::HistoryPrevious)),
            0x12 => Some(self.consume_control(1, ControlInput::ReverseSearch)),
            0x19 => Some(self.consume_edit(1, EditCommand::Yank)),
            0x1a => Some(self.consume_control(1, ControlInput::Suspend)),
            ESC => self.decode_escape(),
            byte if byte < 0x20 => Some(self.consume_raw(1)),
            _ => self.decode_utf8_char(),
        }
    }

    fn decode_escape(&mut self) -> Option<DecodedInput> {
        if self.pending.len() == 1 {
            return None;
        }

        let known: &[(&[u8], EditCommand)] = &[
            (b"\x1b[D", EditCommand::MoveLeft),
            (b"\x1bOD", EditCommand::MoveLeft),
            (b"\x1b[C", EditCommand::MoveRight),
            (b"\x1bOC", EditCommand::MoveRight),
            (b"\x1b[A", EditCommand::HistoryPrevious),
            (b"\x1bOA", EditCommand::HistoryPrevious),
            (b"\x1b[B", EditCommand::HistoryNext),
            (b"\x1bOB", EditCommand::HistoryNext),
            (b"\x1b[H", EditCommand::Home),
            (b"\x1bOH", EditCommand::Home),
            (b"\x1b[1~", EditCommand::Home),
            (b"\x1b[7~", EditCommand::Home),
            (b"\x1b[F", EditCommand::End),
            (b"\x1bOF", EditCommand::End),
            (b"\x1b[4~", EditCommand::End),
            (b"\x1b[8~", EditCommand::End),
            (b"\x1b[3~", EditCommand::Delete),
            (b"\x1b[1;5D", EditCommand::MoveWordLeft),
            (b"\x1b[5D", EditCommand::MoveWordLeft),
            (b"\x1bb", EditCommand::MoveWordLeft),
            (b"\x1b[1;5C", EditCommand::MoveWordRight),
            (b"\x1b[5C", EditCommand::MoveWordRight),
            (b"\x1bf", EditCommand::MoveWordRight),
        ];

        for (sequence, command) in known {
            if self.pending.starts_with(sequence) {
                return Some(self.consume_edit(sequence.len(), command.clone()));
            }
        }

        if is_possible_escape_prefix(&self.pending) {
            return None;
        }

        Some(self.consume_raw(1))
    }

    fn decode_utf8_char(&mut self) -> Option<DecodedInput> {
        let width = utf8_char_width(self.pending[0]);
        if self.pending.len() < width {
            return None;
        }

        let bytes = &self.pending[..width];
        match std::str::from_utf8(bytes) {
            Ok(text) => {
                let text = text.to_string();
                self.pending.drain(..width);
                Some(DecodedInput::Edit(EditCommand::Insert(text)))
            },
            Err(_) => Some(self.consume_raw(1)),
        }
    }

    fn consume_edit(&mut self, count: usize, command: EditCommand) -> DecodedInput {
        self.pending.drain(..count);
        DecodedInput::Edit(command)
    }

    fn consume_control(&mut self, count: usize, control: ControlInput) -> DecodedInput {
        self.pending.drain(..count);
        DecodedInput::Control(control)
    }

    fn consume_raw(&mut self, count: usize) -> DecodedInput {
        let bytes = self.pending.drain(..count).collect();
        DecodedInput::Raw(bytes)
    }
}

fn utf8_char_width(byte: u8) -> usize {
    match byte {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => 1,
    }
}

fn is_possible_escape_prefix(bytes: &[u8]) -> bool {
    if bytes == [ESC] {
        return true;
    }

    let known = [
        b"\x1b[D".as_slice(),
        b"\x1bOD",
        b"\x1b[C",
        b"\x1bOC",
        b"\x1b[A",
        b"\x1bOA",
        b"\x1b[B",
        b"\x1bOB",
        b"\x1b[H",
        b"\x1bOH",
        b"\x1b[1~",
        b"\x1b[7~",
        b"\x1b[F",
        b"\x1bOF",
        b"\x1b[4~",
        b"\x1b[8~",
        b"\x1b[3~",
        b"\x1b[1;5D",
        b"\x1b[5D",
        b"\x1bb",
        b"\x1b[1;5C",
        b"\x1b[5C",
        b"\x1bf",
        BRACKETED_PASTE_START,
    ];

    known
        .iter()
        .any(|sequence| bytes.len() < sequence.len() && sequence.starts_with(bytes))
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(command: EditCommand) -> DecodedInput {
        DecodedInput::Edit(command)
    }

    #[test]
    fn decodes_printable_text_and_enter() {
        let mut decoder = InputDecoder::new();

        assert_eq!(decoder.push_bytes(b"x\n"), vec![
            edit(EditCommand::Insert("x".to_string())),
            edit(EditCommand::Enter)
        ]);
    }

    #[test]
    fn waits_for_complete_utf8_character() {
        let mut decoder = InputDecoder::new();

        assert!(decoder.push_bytes(&[0xf0, 0x9f]).is_empty());
        assert_eq!(decoder.push_bytes(&[0x8c, 0xb1]), vec![edit(
            EditCommand::Insert("🌱".to_string())
        )]);
    }

    #[test]
    fn decodes_arrow_and_word_sequences_across_chunks() {
        let mut decoder = InputDecoder::new();

        assert!(decoder.push_bytes(b"\x1b[1").is_empty());
        assert_eq!(decoder.push_bytes(b";5D\x1b[1;5C"), vec![
            edit(EditCommand::MoveWordLeft),
            edit(EditCommand::MoveWordRight)
        ]);
    }

    #[test]
    fn decodes_basic_editing_controls() {
        let mut decoder = InputDecoder::new();

        assert_eq!(decoder.push_bytes(&[0x01, 0x05, 0x0b, 0x19, DEL]), vec![
            edit(EditCommand::Home),
            edit(EditCommand::End),
            edit(EditCommand::KillToEnd),
            edit(EditCommand::Yank),
            edit(EditCommand::Backspace),
        ]);
    }

    #[test]
    fn decodes_interrupt_suspend_and_eof_controls() {
        let mut decoder = InputDecoder::new();

        assert_eq!(decoder.push_bytes(&[0x03, 0x1a, 0x04, 0x12, 0x07]), vec![
            DecodedInput::Control(ControlInput::Interrupt),
            DecodedInput::Control(ControlInput::Suspend),
            DecodedInput::Control(ControlInput::EofOrDelete),
            DecodedInput::Control(ControlInput::ReverseSearch),
            DecodedInput::Control(ControlInput::Cancel),
        ]);
    }

    #[test]
    fn decodes_bracketed_paste_across_chunks() {
        let mut decoder = InputDecoder::new();

        assert!(decoder.push_bytes(BRACKETED_PASTE_START).is_empty());
        assert!(decoder.push_bytes(b"line 1\nli").is_empty());
        assert_eq!(decoder.push_bytes(b"ne 2\x1b[201~x"), vec![
            edit(EditCommand::BracketedPaste("line 1\nline 2".to_string())),
            edit(EditCommand::Insert("x".to_string())),
        ]);
    }

    #[test]
    fn unknown_escape_falls_back_to_raw_bytes() {
        let mut decoder = InputDecoder::new();

        assert_eq!(decoder.push_bytes(b"\x1b?"), vec![
            DecodedInput::Raw(vec![ESC]),
            edit(EditCommand::Insert("?".to_string()))
        ]);
    }
}
