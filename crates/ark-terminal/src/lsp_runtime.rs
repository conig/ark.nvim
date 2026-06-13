use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::sync::mpsc;
use std::sync::mpsc::Receiver;
use std::sync::mpsc::Sender;
use std::sync::mpsc::TryRecvError;
use std::thread;

use anyhow::anyhow;
use serde_json::json;
use serde_json::Value;

use crate::input::EditorSnapshot;
use crate::lsp_client::completion_items_from_response;
use crate::lsp_client::ConsoleLspState;
use crate::lsp_client::LspTransport;

#[derive(Debug, Clone, PartialEq)]
pub enum TerminalLspEvent {
    Started {
        child_id: u32,
    },
    Initialized,
    SnapshotSynced {
        version: i32,
    },
    Completion {
        sequence: u64,
        trigger_character: Option<String>,
        item_count: usize,
        items: Vec<Value>,
    },
    Error {
        message: String,
    },
}

#[derive(Debug)]
pub struct TerminalLspHandle {
    command_tx: Sender<TerminalLspCommand>,
    event_rx: Receiver<TerminalLspEvent>,
    next_completion_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalLspSession {
    pub kind: String,
    pub backend: String,
    pub session_id: String,
    pub status_file: Option<PathBuf>,
    pub tmux_socket: String,
    pub tmux_session: String,
    pub tmux_pane: String,
    pub timeout_ms: u64,
}

#[derive(Debug)]
enum TerminalLspCommand {
    Sync(EditorSnapshot),
    Completion {
        sequence: u64,
        snapshot: EditorSnapshot,
        trigger_character: Option<String>,
    },
    Shutdown,
}

impl TerminalLspHandle {
    pub fn spawn_ark_lsp(
        ark_lsp: impl Into<PathBuf>,
        session: TerminalLspSession,
    ) -> anyhow::Result<Self> {
        let mut command = Command::new(ark_lsp.into());
        command.arg("--runtime-mode").arg("detached");
        session.apply_env(&mut command);
        Self::spawn(command, session.session_id)
    }

    pub fn spawn(command: Command, session_id: impl Into<String>) -> anyhow::Result<Self> {
        let (command_tx, command_rx) = mpsc::channel();
        let (event_tx, event_rx) = mpsc::channel();
        let session_id = session_id.into();

        thread::Builder::new()
            .name("ark-terminal-lsp".to_string())
            .spawn(move || {
                if let Err(err) = run_worker(command, session_id, command_rx, event_tx.clone()) {
                    let _ = event_tx.send(TerminalLspEvent::Error {
                        message: err.to_string(),
                    });
                }
            })?;

        Ok(Self {
            command_tx,
            event_rx,
            next_completion_sequence: 1,
        })
    }

    pub fn sync_snapshot(&self, snapshot: &EditorSnapshot) -> bool {
        self.command_tx
            .send(TerminalLspCommand::Sync(snapshot.clone()))
            .is_ok()
    }

    pub fn request_completion(
        &mut self,
        snapshot: &EditorSnapshot,
        trigger_character: Option<&str>,
    ) -> Option<u64> {
        let sequence = self.next_completion_sequence;
        self.next_completion_sequence += 1;
        let sent = self
            .command_tx
            .send(TerminalLspCommand::Completion {
                sequence,
                snapshot: snapshot.clone(),
                trigger_character: trigger_character.map(ToString::to_string),
            })
            .is_ok();

        sent.then_some(sequence)
    }

    pub fn drain_events(&mut self) -> Vec<TerminalLspEvent> {
        let mut events = Vec::new();
        loop {
            match self.event_rx.try_recv() {
                Ok(event) => events.push(event),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    events.push(TerminalLspEvent::Error {
                        message: "ark-terminal LSP worker disconnected".to_string(),
                    });
                    break;
                },
            }
        }
        events
    }
}

impl TerminalLspSession {
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            kind: String::from("ark"),
            backend: String::from("tmux"),
            session_id: session_id.into(),
            status_file: None,
            tmux_socket: String::new(),
            tmux_session: String::new(),
            tmux_pane: String::new(),
            timeout_ms: 1000,
        }
    }

    pub fn with_status_dir(mut self, status_dir: impl AsRef<Path>) -> Self {
        let mut path = status_dir.as_ref().to_path_buf();
        path.push(format!("{}.json", self.session_id));
        self.status_file = Some(path);
        self
    }

    fn apply_env(&self, command: &mut Command) {
        command.env("ARK_SESSION_KIND", &self.kind);
        command.env("ARK_SESSION_BACKEND", &self.backend);
        command.env("ARK_SESSION_ID", &self.session_id);
        command.env("ARK_SESSION_TIMEOUT_MS", self.timeout_ms.to_string());

        if let Some(status_file) = &self.status_file {
            command.env("ARK_SESSION_STATUS_FILE", status_file);
        }
        if !self.tmux_socket.is_empty() {
            command.env("ARK_SESSION_TMUX_SOCKET", &self.tmux_socket);
        }
        if !self.tmux_session.is_empty() {
            command.env("ARK_SESSION_TMUX_SESSION", &self.tmux_session);
        }
        if !self.tmux_pane.is_empty() {
            command.env("ARK_SESSION_TMUX_PANE", &self.tmux_pane);
        }
    }
}

impl Drop for TerminalLspHandle {
    fn drop(&mut self) {
        let _ = self.command_tx.send(TerminalLspCommand::Shutdown);
    }
}

fn run_worker(
    command: Command,
    session_id: String,
    command_rx: Receiver<TerminalLspCommand>,
    event_tx: Sender<TerminalLspEvent>,
) -> anyhow::Result<()> {
    let mut transport = LspTransport::spawn(command)?;
    let _ = event_tx.send(TerminalLspEvent::Started {
        child_id: transport.child_id(),
    });

    let mut state = ConsoleLspState::new(&session_id);
    let initialize = state.initialize(Some(std::process::id()));
    let initialize_id =
        message_id(&initialize).ok_or_else(|| anyhow!("initialize request missing id"))?;
    transport.send(&initialize)?;
    let _ = read_message_with_id(&mut transport, initialize_id)?;
    transport.send(&ConsoleLspState::initialized())?;
    let _ = event_tx.send(TerminalLspEvent::Initialized);

    while let Ok(command) = command_rx.recv() {
        match command {
            TerminalLspCommand::Sync(snapshot) => {
                if let Some(message) = state.sync_snapshot(&snapshot) {
                    transport.send(&message)?;
                    let _ = event_tx.send(TerminalLspEvent::SnapshotSynced {
                        version: state.document().version(),
                    });
                }
            },
            TerminalLspCommand::Completion {
                sequence,
                snapshot,
                trigger_character,
            } => {
                handle_completion(
                    &mut transport,
                    &mut state,
                    &event_tx,
                    sequence,
                    snapshot,
                    trigger_character,
                )?;
            },
            TerminalLspCommand::Shutdown => break,
        }
    }

    Ok(())
}

fn handle_completion(
    transport: &mut LspTransport,
    state: &mut ConsoleLspState,
    event_tx: &Sender<TerminalLspEvent>,
    sequence: u64,
    snapshot: EditorSnapshot,
    trigger_character: Option<String>,
) -> anyhow::Result<()> {
    let messages = state.completion_messages_for_snapshot(&snapshot, trigger_character.as_deref());
    let mut completion_id = None;

    for message in messages {
        if is_completion_request(&message) {
            completion_id = message_id(&message);
        }

        transport.send(&message)?;

        if message.get("method").and_then(Value::as_str) == Some("textDocument/didOpen") ||
            message.get("method").and_then(Value::as_str) == Some("textDocument/didChange")
        {
            let _ = event_tx.send(TerminalLspEvent::SnapshotSynced {
                version: state.document().version(),
            });
        }
    }

    let completion_id = completion_id.ok_or_else(|| anyhow!("completion request missing id"))?;
    let response = read_message_with_id(transport, completion_id)?;
    let items = completion_items_from_response(&response);
    let _ = event_tx.send(TerminalLspEvent::Completion {
        sequence,
        trigger_character,
        item_count: items.len(),
        items,
    });

    Ok(())
}

fn read_message_with_id(transport: &mut LspTransport, id: u64) -> anyhow::Result<Value> {
    loop {
        let message = transport.read_message()?;
        if message_id(&message) == Some(id) && !is_server_request(&message) {
            return Ok(message);
        }
        if is_server_request(&message) {
            transport.send(&server_request_response(&message))?;
        }
    }
}

fn message_id(message: &Value) -> Option<u64> {
    message.get("id").and_then(Value::as_u64)
}

fn is_completion_request(message: &Value) -> bool {
    message.get("method").and_then(Value::as_str) == Some("textDocument/completion")
}

fn is_server_request(message: &Value) -> bool {
    message_id(message).is_some() && message.get("method").and_then(Value::as_str).is_some()
}

fn server_request_response(message: &Value) -> Value {
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    let result = match message.get("method").and_then(Value::as_str) {
        Some("workspace/configuration") => json!([]),
        _ => Value::Null,
    };

    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    })
}

#[cfg(test)]
mod tests {
    use std::time::Duration;
    use std::time::Instant;

    use super::*;

    fn snapshot(text: &str) -> EditorSnapshot {
        EditorSnapshot {
            text: text.to_string(),
            cursor: text.len(),
            display_cursor: text.len(),
            is_complete: true,
        }
    }

    fn wait_for_event(
        handle: &mut TerminalLspHandle,
        predicate: impl Fn(&TerminalLspEvent) -> bool,
    ) -> TerminalLspEvent {
        let start = Instant::now();
        loop {
            for event in handle.drain_events() {
                if predicate(&event) {
                    return event;
                }
            }

            if start.elapsed() > Duration::from_secs(2) {
                panic!("timed out waiting for terminal LSP event");
            }

            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn server_request_response_acknowledges_dynamic_registration() {
        assert_eq!(
            server_request_response(&json!({
                "jsonrpc": "2.0",
                "id": 7,
                "method": "client/registerCapability",
                "params": {}
            })),
            json!({
                "jsonrpc": "2.0",
                "id": 7,
                "result": null
            })
        );
        assert_eq!(
            server_request_response(&json!({
                "jsonrpc": "2.0",
                "id": 8,
                "method": "workspace/configuration",
                "params": {}
            })),
            json!({
                "jsonrpc": "2.0",
                "id": 8,
                "result": []
            })
        );
    }

    #[test]
    fn worker_initializes_and_reports_completion_responses() {
        let mut handle = TerminalLspHandle::spawn(Command::new("cat"), "session-1").unwrap();

        let _ = wait_for_event(&mut handle, |event| {
            matches!(event, TerminalLspEvent::Initialized)
        });
        let sequence = handle
            .request_completion(&snapshot("mtcars$"), Some("$"))
            .unwrap();
        let event = wait_for_event(&mut handle, |event| {
            matches!(event, TerminalLspEvent::Completion { .. })
        });

        match event {
            TerminalLspEvent::Completion {
                sequence: event_sequence,
                trigger_character,
                item_count,
                items,
            } => {
                assert_eq!(event_sequence, sequence);
                assert_eq!(trigger_character.as_deref(), Some("$"));
                assert_eq!(item_count, 0);
                assert!(items.is_empty());
            },
            other => panic!("unexpected terminal LSP event: {other:?}"),
        }
    }

    #[test]
    fn lsp_session_status_dir_matches_session_id() {
        let session = TerminalLspSession::new("session-1").with_status_dir("/tmp/ark-status");
        assert_eq!(
            session.status_file.as_deref(),
            Some(std::path::Path::new("/tmp/ark-status/session-1.json"))
        );
    }
}
