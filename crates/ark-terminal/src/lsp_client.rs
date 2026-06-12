use std::io::Read;
use std::io::Write;
use std::path::Path;
use std::process::Child;
use std::process::ChildStdin;
use std::process::ChildStdout;
use std::process::Command;
use std::process::Stdio;

use anyhow::anyhow;
use serde_json::json;
use serde_json::Value;

use crate::input::EditorSnapshot;

const JSONRPC_VERSION: &str = "2.0";
const CONSOLE_LANGUAGE_ID: &str = "r";
pub const COMPLETION_TRIGGER_CHARACTERS: &[&str] =
    &["$", "@", ":", "(", "[", ",", " ", "\"", "'", "/"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LspPosition {
    pub line: u32,
    pub character: u32,
}

impl LspPosition {
    pub fn from_byte_offset(text: &str, byte_offset: usize) -> Self {
        let byte_offset = byte_offset.min(text.len());
        let mut line = 0;
        let mut character = 0;

        for (index, ch) in text.char_indices() {
            if index >= byte_offset {
                break;
            }

            if ch == '\n' {
                line += 1;
                character = 0;
            } else {
                character += u32::try_from(ch.len_utf16()).unwrap_or(u32::MAX);
            }
        }

        Self { line, character }
    }

    fn from_value(value: &Value) -> anyhow::Result<Self> {
        let line = value
            .get("line")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("LSP position missing numeric line"))?;
        let character = value
            .get("character")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("LSP position missing numeric character"))?;

        Ok(Self {
            line: u32::try_from(line).map_err(|_| anyhow!("LSP line is too large"))?,
            character: u32::try_from(character)
                .map_err(|_| anyhow!("LSP character is too large"))?,
        })
    }

    fn to_value(self) -> Value {
        json!({
            "line": self.line,
            "character": self.character,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConsoleDocument {
    uri: String,
    language_id: String,
    version: i32,
    text: String,
}

impl ConsoleDocument {
    pub fn new(session_id: &str) -> Self {
        Self::with_text(session_id, "")
    }

    pub fn with_text(session_id: &str, text: &str) -> Self {
        Self {
            uri: console_document_uri(session_id),
            language_id: CONSOLE_LANGUAGE_ID.to_string(),
            version: 0,
            text: text.to_string(),
        }
    }

    pub fn uri(&self) -> &str {
        &self.uri
    }

    pub fn version(&self) -> i32 {
        self.version
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn did_open(&self) -> Value {
        notification(
            "textDocument/didOpen",
            json!({
                "textDocument": {
                    "uri": self.uri,
                    "languageId": self.language_id,
                    "version": self.version,
                    "text": self.text,
                },
            }),
        )
    }

    pub fn replace_text(&mut self, text: impl Into<String>) -> Value {
        self.version += 1;
        self.text = text.into();
        notification(
            "textDocument/didChange",
            json!({
                "textDocument": {
                    "uri": self.uri,
                    "version": self.version,
                },
                "contentChanges": [
                    {
                        "text": self.text,
                    },
                ],
            }),
        )
    }

    pub fn completion_request(
        &self,
        id: u64,
        position: LspPosition,
        trigger_character: Option<&str>,
    ) -> Value {
        let context = match trigger_character {
            Some(trigger_character) => json!({
                "triggerKind": 2,
                "triggerCharacter": trigger_character,
            }),
            None => json!({
                "triggerKind": 1,
            }),
        };

        request(
            id,
            "textDocument/completion",
            json!({
                "textDocument": {
                    "uri": self.uri,
                },
                "position": position.to_value(),
                "context": context,
            }),
        )
    }
}

#[derive(Debug, Clone)]
pub struct LspMessageFactory {
    next_id: u64,
}

#[derive(Debug)]
pub struct LspTransport {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
    read_buffer: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedCompletion {
    pub text: String,
    pub cursor: usize,
}

impl Default for LspMessageFactory {
    fn default() -> Self {
        Self::new()
    }
}

impl LspMessageFactory {
    pub fn new() -> Self {
        Self { next_id: 1 }
    }

    pub fn initialize(&mut self, process_id: Option<u32>) -> Value {
        self.request(
            "initialize",
            json!({
                "processId": process_id,
                "clientInfo": {
                    "name": "ark-terminal",
                    "version": env!("CARGO_PKG_VERSION"),
                },
                "capabilities": {
                    "general": {
                        "positionEncodings": ["utf-16"],
                    },
                    "textDocument": {
                        "completion": {
                            "completionItem": {
                                "documentationFormat": ["markdown", "plaintext"],
                                "resolveSupport": {
                                    "properties": [
                                        "documentation",
                                        "detail",
                                        "additionalTextEdits"
                                    ],
                                },
                                "snippetSupport": false,
                            },
                            "contextSupport": true,
                        },
                    },
                },
            }),
        )
    }

    pub fn initialized() -> Value {
        notification("initialized", json!({}))
    }

    pub fn completion(
        &mut self,
        document: &ConsoleDocument,
        position: LspPosition,
        trigger_character: Option<&str>,
    ) -> Value {
        let id = self.next_request_id();
        document.completion_request(id, position, trigger_character)
    }

    pub fn resolve_completion(&mut self, item: Value) -> Value {
        self.request("completionItem/resolve", item)
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        request(self.next_request_id(), method, params)
    }

    fn next_request_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

#[derive(Debug, Clone)]
pub struct ConsoleLspState {
    document: ConsoleDocument,
    factory: LspMessageFactory,
    opened: bool,
}

impl ConsoleLspState {
    pub fn new(session_id: &str) -> Self {
        Self {
            document: ConsoleDocument::new(session_id),
            factory: LspMessageFactory::new(),
            opened: false,
        }
    }

    pub fn document(&self) -> &ConsoleDocument {
        &self.document
    }

    pub fn is_open(&self) -> bool {
        self.opened
    }

    pub fn initialize(&mut self, process_id: Option<u32>) -> Value {
        self.factory.initialize(process_id)
    }

    pub fn initialized() -> Value {
        LspMessageFactory::initialized()
    }

    pub fn sync_snapshot(&mut self, snapshot: &EditorSnapshot) -> Option<Value> {
        if !self.opened {
            self.document.text = snapshot.text.clone();
            self.opened = true;
            return Some(self.document.did_open());
        }

        if self.document.text() == snapshot.text {
            return None;
        }

        Some(self.document.replace_text(snapshot.text.clone()))
    }

    pub fn completion_messages_for_snapshot(
        &mut self,
        snapshot: &EditorSnapshot,
        trigger_character: Option<&str>,
    ) -> Vec<Value> {
        let mut messages = Vec::new();
        if let Some(message) = self.sync_snapshot(snapshot) {
            messages.push(message);
        }

        messages.push(self.completion_request_for_snapshot(snapshot, trigger_character));
        messages
    }

    pub fn completion_request_for_snapshot(
        &mut self,
        snapshot: &EditorSnapshot,
        trigger_character: Option<&str>,
    ) -> Value {
        let position = LspPosition::from_byte_offset(&snapshot.text, snapshot.cursor);
        self.factory
            .completion(&self.document, position, trigger_character)
    }

    pub fn resolve_completion(&mut self, item: Value) -> Value {
        self.factory.resolve_completion(item)
    }
}

pub fn completion_trigger_from_inserted_text(text: &str) -> Option<&'static str> {
    text.chars().last().and_then(completion_trigger_for_char)
}

pub fn completion_trigger_for_char(ch: char) -> Option<&'static str> {
    match ch {
        '$' => Some("$"),
        '@' => Some("@"),
        ':' => Some(":"),
        '(' => Some("("),
        '[' => Some("["),
        ',' => Some(","),
        ' ' => Some(" "),
        '"' => Some("\""),
        '\'' => Some("'"),
        '/' => Some("/"),
        _ => None,
    }
}

impl LspTransport {
    pub fn spawn_ark_lsp(ark_lsp: impl AsRef<Path>) -> anyhow::Result<Self> {
        let mut command = Command::new(ark_lsp.as_ref());
        command.arg("--runtime-mode").arg("detached");
        Self::spawn(command)
    }

    pub fn spawn(mut command: Command) -> anyhow::Result<Self> {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("failed to open LSP child stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("failed to open LSP child stdout"))?;

        Ok(Self {
            child,
            stdin,
            stdout,
            read_buffer: Vec::new(),
        })
    }

    pub fn child_id(&self) -> u32 {
        self.child.id()
    }

    pub fn send(&mut self, message: &Value) -> anyhow::Result<()> {
        let bytes = encode_message(message)?;
        self.stdin.write_all(&bytes)?;
        self.stdin.flush()?;
        Ok(())
    }

    pub fn read_message(&mut self) -> anyhow::Result<Value> {
        let mut buffer = [0; 8192];
        loop {
            if let Some((message, consumed)) = decode_message(&self.read_buffer)? {
                self.read_buffer.drain(..consumed);
                return Ok(message);
            }

            let read = self.stdout.read(&mut buffer)?;
            if read == 0 {
                return Err(anyhow!("LSP child stdout closed before a complete message"));
            }
            self.read_buffer.extend_from_slice(&buffer[..read]);
        }
    }
}

impl Drop for LspTransport {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn encode_message(message: &Value) -> anyhow::Result<Vec<u8>> {
    let body = serde_json::to_vec(message)?;
    let mut out = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn decode_message(buffer: &[u8]) -> anyhow::Result<Option<(Value, usize)>> {
    let Some(header_end) = find_header_end(buffer) else {
        return Ok(None);
    };

    let header = std::str::from_utf8(&buffer[..header_end])
        .map_err(|_| anyhow!("LSP message header is not valid UTF-8"))?;
    let content_length = content_length(header)?;
    let body_start = header_end + b"\r\n\r\n".len();
    let message_end = body_start + content_length;

    if buffer.len() < message_end {
        return Ok(None);
    }

    let value = serde_json::from_slice(&buffer[body_start..message_end])?;
    Ok(Some((value, message_end)))
}

pub fn completion_items_from_response(response: &Value) -> Vec<Value> {
    match response.get("result") {
        Some(Value::Array(items)) => items.clone(),
        Some(Value::Object(result)) => result
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

pub fn apply_lsp_text_edit(text: &str, edit: &Value) -> anyhow::Result<String> {
    let (start_offset, end_offset, new_text) = lsp_text_edit_parts(text, edit)?;

    let mut edited = text.to_string();
    edited.replace_range(start_offset..end_offset, new_text);
    Ok(edited)
}

pub fn apply_completion_item(
    snapshot: &EditorSnapshot,
    item: &Value,
) -> anyhow::Result<AppliedCompletion> {
    if let Some(text_edit) = item.get("textEdit") {
        let (start_offset, end_offset, new_text) = lsp_text_edit_parts(&snapshot.text, text_edit)?;
        let mut text = snapshot.text.clone();
        text.replace_range(start_offset..end_offset, new_text);
        return Ok(AppliedCompletion {
            text,
            cursor: start_offset + new_text.len(),
        });
    }

    let insert_text = item
        .get("insertText")
        .and_then(Value::as_str)
        .or_else(|| item.get("label").and_then(Value::as_str))
        .ok_or_else(|| anyhow!("LSP completion item missing label or insertText"))?;
    let start_offset = completion_prefix_start(&snapshot.text, snapshot.cursor);
    let mut text = snapshot.text.clone();
    text.replace_range(start_offset..snapshot.cursor, insert_text);

    Ok(AppliedCompletion {
        text,
        cursor: start_offset + insert_text.len(),
    })
}

pub fn byte_offset_for_position(text: &str, position: LspPosition) -> Option<usize> {
    let mut line = 0;
    let mut character = 0;

    for (index, ch) in text.char_indices() {
        if line == position.line && character == position.character {
            return Some(index);
        }

        if ch == '\n' {
            if line == position.line {
                return None;
            }
            line += 1;
            character = 0;
            continue;
        }

        if line == position.line {
            character += u32::try_from(ch.len_utf16()).ok()?;
            if character > position.character {
                return None;
            }
        }
    }

    if line == position.line && character == position.character {
        Some(text.len())
    } else {
        None
    }
}

fn request(id: u64, method: &str, params: Value) -> Value {
    json!({
        "jsonrpc": JSONRPC_VERSION,
        "id": id,
        "method": method,
        "params": params,
    })
}

fn notification(method: &str, params: Value) -> Value {
    json!({
        "jsonrpc": JSONRPC_VERSION,
        "method": method,
        "params": params,
    })
}

fn console_document_uri(session_id: &str) -> String {
    format!("ark-console://{}/input.R", encode_uri_component(session_id))
}

fn encode_uri_component(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(b"\r\n\r\n".len())
        .position(|window| window == b"\r\n\r\n")
}

fn content_length(header: &str) -> anyhow::Result<usize> {
    for line in header.split("\r\n") {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("Content-Length") {
            return value
                .trim()
                .parse::<usize>()
                .map_err(|_| anyhow!("LSP Content-Length header is not numeric"));
        }
    }

    Err(anyhow!("LSP message missing Content-Length header"))
}

fn lsp_text_edit_parts<'a>(text: &str, edit: &'a Value) -> anyhow::Result<(usize, usize, &'a str)> {
    let range = edit
        .get("range")
        .or_else(|| edit.get("replace"))
        .or_else(|| edit.get("insert"))
        .ok_or_else(|| anyhow!("LSP text edit missing range"))?;
    let start = range
        .get("start")
        .map(LspPosition::from_value)
        .transpose()?
        .ok_or_else(|| anyhow!("LSP text edit missing start range"))?;
    let end = range
        .get("end")
        .map(LspPosition::from_value)
        .transpose()?
        .ok_or_else(|| anyhow!("LSP text edit missing end range"))?;
    let new_text = edit
        .get("newText")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("LSP text edit missing newText"))?;

    let start_offset = byte_offset_for_position(text, start)
        .ok_or_else(|| anyhow!("LSP text edit start is outside the document"))?;
    let end_offset = byte_offset_for_position(text, end)
        .ok_or_else(|| anyhow!("LSP text edit end is outside the document"))?;

    if start_offset > end_offset {
        return Err(anyhow!("LSP text edit start is after end"));
    }

    Ok((start_offset, end_offset, new_text))
}

fn completion_prefix_start(text: &str, cursor: usize) -> usize {
    let cursor = cursor.min(text.len());
    let before = &text[..cursor];
    before
        .char_indices()
        .rev()
        .find_map(|(index, ch)| {
            if is_completion_prefix_char(ch) {
                None
            } else {
                Some(index + ch.len_utf8())
            }
        })
        .unwrap_or(0)
}

fn is_completion_prefix_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(value: &Value) -> Option<&str> {
        value.get("label").and_then(Value::as_str)
    }

    fn snapshot(text: &str, cursor: usize) -> EditorSnapshot {
        EditorSnapshot {
            text: text.to_string(),
            cursor,
            display_cursor: cursor,
            is_complete: true,
        }
    }

    #[test]
    fn console_document_uri_escapes_session_identity() {
        let document = ConsoleDocument::new("/tmp/tmux/default__%169");

        assert_eq!(
            document.uri(),
            "ark-console://%2Ftmp%2Ftmux%2Fdefault__%25169/input.R"
        );
    }

    #[test]
    fn did_open_and_change_track_full_document_versions() {
        let mut document = ConsoleDocument::with_text("session-1", "mtcars$");
        let opened = document.did_open();

        assert_eq!(
            opened["params"]["textDocument"]["uri"],
            "ark-console://session-1/input.R"
        );
        assert_eq!(opened["params"]["textDocument"]["languageId"], "r");
        assert_eq!(opened["params"]["textDocument"]["version"], 0);
        assert_eq!(opened["params"]["textDocument"]["text"], "mtcars$");

        let changed = document.replace_text("library(");

        assert_eq!(document.version(), 1);
        assert_eq!(document.text(), "library(");
        assert_eq!(changed["method"], "textDocument/didChange");
        assert_eq!(changed["params"]["textDocument"]["version"], 1);
        assert_eq!(changed["params"]["contentChanges"][0]["text"], "library(");
    }

    #[test]
    fn completion_request_uses_console_document_and_trigger_context() {
        let document = ConsoleDocument::with_text("session-1", "mtcars$");
        let message = document.completion_request(
            7,
            LspPosition {
                line: 0,
                character: 7,
            },
            Some("$"),
        );

        assert_eq!(message["id"], 7);
        assert_eq!(message["method"], "textDocument/completion");
        assert_eq!(
            message["params"]["textDocument"]["uri"],
            "ark-console://session-1/input.R"
        );
        assert_eq!(
            message["params"]["position"],
            json!({"line": 0, "character": 7})
        );
        assert_eq!(message["params"]["context"]["triggerKind"], 2);
        assert_eq!(message["params"]["context"]["triggerCharacter"], "$");
    }

    #[test]
    fn factory_sequences_initialize_completion_and_resolve_requests() {
        let mut factory = LspMessageFactory::new();
        let document = ConsoleDocument::with_text("session-1", "mean(");

        let initialize = factory.initialize(Some(42));
        let completion = factory.completion(
            &document,
            LspPosition {
                line: 0,
                character: 5,
            },
            None,
        );
        let resolve = factory.resolve_completion(json!({"label": "mean"}));

        assert_eq!(initialize["id"], 1);
        assert_eq!(initialize["method"], "initialize");
        assert_eq!(initialize["params"]["processId"], 42);
        assert_eq!(
            initialize["params"]["capabilities"]["general"]["positionEncodings"][0],
            "utf-16"
        );
        assert_eq!(completion["id"], 2);
        assert_eq!(completion["params"]["context"]["triggerKind"], 1);
        assert_eq!(resolve["id"], 3);
        assert_eq!(resolve["method"], "completionItem/resolve");
        assert_eq!(resolve["params"]["label"], "mean");
        assert_eq!(LspMessageFactory::initialized()["method"], "initialized");
    }

    #[test]
    fn console_lsp_state_opens_once_and_syncs_changed_snapshots() {
        let mut state = ConsoleLspState::new("session-1");
        let first = snapshot("mtcars$", "mtcars$".len());

        let opened = state.sync_snapshot(&first).unwrap();

        assert!(state.is_open());
        assert_eq!(state.document().version(), 0);
        assert_eq!(state.document().text(), "mtcars$");
        assert_eq!(opened["method"], "textDocument/didOpen");
        assert_eq!(opened["params"]["textDocument"]["version"], 0);
        assert_eq!(opened["params"]["textDocument"]["text"], "mtcars$");
        assert!(state.sync_snapshot(&first).is_none());

        let changed = state
            .sync_snapshot(&snapshot("mtcars$c", "mtcars$c".len()))
            .unwrap();

        assert_eq!(state.document().version(), 1);
        assert_eq!(state.document().text(), "mtcars$c");
        assert_eq!(changed["method"], "textDocument/didChange");
        assert_eq!(changed["params"]["textDocument"]["version"], 1);
        assert_eq!(changed["params"]["contentChanges"][0]["text"], "mtcars$c");
    }

    #[test]
    fn console_lsp_state_sequences_initialize_completion_and_resolve() {
        let mut state = ConsoleLspState::new("session-1");
        let input = "x😀$";
        let initialize = state.initialize(Some(99));
        let messages = state.completion_messages_for_snapshot(
            &snapshot(input, input.len()),
            completion_trigger_from_inserted_text(input),
        );
        let completion = messages.last().unwrap();
        let resolve = state.resolve_completion(json!({"label": "x"}));

        assert_eq!(initialize["id"], 1);
        assert_eq!(initialize["method"], "initialize");
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["method"], "textDocument/didOpen");
        assert_eq!(completion["id"], 2);
        assert_eq!(completion["method"], "textDocument/completion");
        assert_eq!(
            completion["params"]["position"],
            json!({"line": 0, "character": 4})
        );
        assert_eq!(completion["params"]["context"]["triggerKind"], 2);
        assert_eq!(completion["params"]["context"]["triggerCharacter"], "$");
        assert_eq!(resolve["id"], 3);
        assert_eq!(resolve["method"], "completionItem/resolve");
    }

    #[test]
    fn console_lsp_state_sends_change_before_completion_for_stale_document() {
        let mut state = ConsoleLspState::new("session-1");
        let first = snapshot("mtcars$", "mtcars$".len());
        let second = snapshot("mtcars$c", "mtcars$c".len());

        let first_messages = state.completion_messages_for_snapshot(&first, Some("$"));
        let second_messages = state.completion_messages_for_snapshot(&second, None);

        assert_eq!(first_messages.len(), 2);
        assert_eq!(second_messages.len(), 2);
        assert_eq!(second_messages[0]["method"], "textDocument/didChange");
        assert_eq!(
            second_messages[0]["params"]["contentChanges"][0]["text"],
            "mtcars$c"
        );
        assert_eq!(second_messages[1]["method"], "textDocument/completion");
        assert_eq!(second_messages[1]["params"]["context"]["triggerKind"], 1);
    }

    #[test]
    fn recognizes_console_completion_triggers_from_inserted_text() {
        assert_eq!(COMPLETION_TRIGGER_CHARACTERS.len(), 10);
        for trigger in COMPLETION_TRIGGER_CHARACTERS {
            assert_eq!(
                completion_trigger_from_inserted_text(&format!("abc{trigger}")),
                Some(*trigger)
            );
        }

        assert_eq!(completion_trigger_for_char('m'), None);
        assert_eq!(completion_trigger_from_inserted_text(""), None);
    }

    #[test]
    fn frames_and_decodes_content_length_messages() {
        let message = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "capabilities": {}
            },
        });

        let encoded = encode_message(&message).unwrap();
        let decoded = decode_message(&encoded).unwrap().unwrap();

        assert_eq!(decoded.0, message);
        assert_eq!(decoded.1, encoded.len());
    }

    #[test]
    fn waits_for_complete_headers_and_bodies() {
        assert!(decode_message(b"Content-Length: 10\r\n").unwrap().is_none());
        assert!(decode_message(b"Content-Length: 10\r\n\r\n{}")
            .unwrap()
            .is_none());
    }

    #[test]
    fn completion_response_accepts_array_and_completion_list_results() {
        let array_response = json!({
            "id": 1,
            "result": [
                {"label": "mpg"},
                {"label": "cyl"}
            ],
        });
        let list_response = json!({
            "id": 2,
            "result": {
                "isIncomplete": false,
                "items": [
                    {"label": "library"}
                ],
            },
        });

        let array_items = completion_items_from_response(&array_response);
        let list_items = completion_items_from_response(&list_response);

        assert_eq!(array_items.iter().map(label).collect::<Vec<_>>(), vec![
            Some("mpg"),
            Some("cyl")
        ]);
        assert_eq!(list_items.iter().map(label).collect::<Vec<_>>(), vec![
            Some("library")
        ]);
    }

    #[test]
    fn positions_use_lsp_utf16_character_offsets() {
        let text = "a😀\nb語";

        assert_eq!(
            LspPosition::from_byte_offset(text, "a😀".len()),
            LspPosition {
                line: 0,
                character: 3,
            }
        );
        assert_eq!(
            LspPosition::from_byte_offset(text, text.len()),
            LspPosition {
                line: 1,
                character: 2,
            }
        );
        assert_eq!(
            byte_offset_for_position(text, LspPosition {
                line: 0,
                character: 3,
            }),
            Some("a😀".len())
        );
        assert_eq!(
            byte_offset_for_position(text, LspPosition {
                line: 0,
                character: 2,
            }),
            None
        );
    }

    #[test]
    fn applies_lsp_text_edits_with_utf16_ranges() {
        let edited = apply_lsp_text_edit(
            "df$😀x\nnext",
            &json!({
                "range": {
                    "start": {"line": 0, "character": 5},
                    "end": {"line": 0, "character": 6}
                },
                "newText": "y"
            }),
        )
        .unwrap();

        assert_eq!(edited, "df$😀y\nnext");
    }

    #[test]
    fn applies_completion_items_with_label_fallback_after_operator() {
        let applied = apply_completion_item(
            &snapshot("mtcars$", "mtcars$".len()),
            &json!({"label": "mpg"}),
        )
        .unwrap();

        assert_eq!(applied, AppliedCompletion {
            text: "mtcars$mpg".to_string(),
            cursor: "mtcars$mpg".len(),
        });
    }

    #[test]
    fn applies_completion_items_by_replacing_current_prefix() {
        let applied = apply_completion_item(
            &snapshot("libr", "libr".len()),
            &json!({"label": "library"}),
        )
        .unwrap();

        assert_eq!(applied, AppliedCompletion {
            text: "library".to_string(),
            cursor: "library".len(),
        });

        let applied = apply_completion_item(
            &snapshot("mtcars$m", "mtcars$m".len()),
            &json!({"label": "mpg"}),
        )
        .unwrap();

        assert_eq!(applied, AppliedCompletion {
            text: "mtcars$mpg".to_string(),
            cursor: "mtcars$mpg".len(),
        });
    }

    #[test]
    fn applies_completion_text_edits_and_insert_replace_edits() {
        let text_edit = apply_completion_item(
            &snapshot("df$mp", "df$mp".len()),
            &json!({
                "label": "mpg",
                "textEdit": {
                    "range": {
                        "start": {"line": 0, "character": 3},
                        "end": {"line": 0, "character": 5}
                    },
                    "newText": "mpg"
                }
            }),
        )
        .unwrap();
        let insert_replace = apply_completion_item(
            &snapshot("df$mp", "df$mp".len()),
            &json!({
                "label": "mpg",
                "textEdit": {
                    "insert": {
                        "start": {"line": 0, "character": 3},
                        "end": {"line": 0, "character": 5}
                    },
                    "replace": {
                        "start": {"line": 0, "character": 3},
                        "end": {"line": 0, "character": 5}
                    },
                    "newText": "mpg"
                }
            }),
        )
        .unwrap();

        assert_eq!(text_edit, AppliedCompletion {
            text: "df$mpg".to_string(),
            cursor: "df$mpg".len(),
        });
        assert_eq!(insert_replace, text_edit);
    }

    #[test]
    fn transport_writes_and_reads_framed_messages_through_stdio() {
        let mut transport = LspTransport::spawn(Command::new("cat")).unwrap();
        let message = json!({
            "jsonrpc": "2.0",
            "id": 99,
            "method": "test/echo",
            "params": {
                "value": "ok"
            }
        });

        transport.send(&message).unwrap();

        assert_eq!(transport.read_message().unwrap(), message);
        assert!(transport.child_id() > 0);
    }
}
