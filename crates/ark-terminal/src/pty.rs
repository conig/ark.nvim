use std::collections::HashSet;
use std::fs::File;
use std::io::Read;
use std::io::Write;
use std::io::{self};
use std::os::fd::AsFd;
use std::os::fd::AsRawFd;
use std::os::fd::BorrowedFd;
use std::os::fd::FromRawFd;
use std::os::fd::IntoRawFd;
use std::os::fd::OwnedFd;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Child;
use std::process::Command;
use std::process::ExitStatus;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread;

use anyhow::anyhow;
use anyhow::Context;
use nix::poll::poll;
use nix::poll::PollFd;
use nix::poll::PollFlags;
use nix::poll::PollTimeout;
use nix::pty::openpty;
use nix::pty::Winsize;
use nix::sys::signal::pthread_sigmask;
use nix::sys::signal::SigSet;
use nix::sys::signal::SigmaskHow;
use nix::sys::signal::Signal;
use nix::unistd::dup;
use serde_json::json;
use serde_json::Value;

use crate::enhanced::EnhancedInputRuntime;
use crate::enhanced::InputEffect;
use crate::lsp_client::apply_completion_item;
use crate::lsp_runtime::TerminalLspEvent;
use crate::lsp_runtime::TerminalLspHandle;
use crate::lsp_runtime::TerminalLspSession;
use crate::prompt::PromptDetector;
use crate::prompt::PromptState;
use crate::raw_terminal::RawTerminal;
use crate::render::CompletionMenuItem;
use crate::render::CompletionMenuSnapshot;
use crate::render::LocalInputRenderer;
use crate::status::StartupStatus;
use crate::trace::TraceLog;
use crate::Cli;

const ENHANCED_STDIN_POLL_MS: u16 = 10;

#[derive(Debug, Clone)]
struct ActiveCompletionMenu {
    items: Vec<Value>,
    selected: usize,
}

impl ActiveCompletionMenu {
    fn selected_item(&self) -> Option<&Value> {
        self.items.get(self.selected)
    }

    fn snapshot(&self) -> CompletionMenuSnapshot {
        CompletionMenuSnapshot {
            items: self.items.iter().filter_map(completion_menu_item).collect(),
            selected: self.selected,
        }
    }
}

pub fn run(cli: Cli) -> anyhow::Result<i32> {
    if cli.child_command.is_empty() {
        return Err(anyhow!("ark-terminal requires a child command"));
    }

    let trace = TraceLog::open(cli.trace_log.as_deref())?;
    let enhanced_mode = !cli.raw;
    if enhanced_mode && !cli.no_lsp {
        trace.event(
            "enhanced_mode_started",
            json!({
                "lsp": "pending",
                "mode": "prompt-owned-input"
            }),
        );
    }

    let stdin = io::stdin();
    let stdout = io::stdout();
    let stdin_is_tty = is_tty(stdin.as_fd().as_raw_fd());
    let stdout_fd = stdout.as_fd().as_raw_fd();
    let winsize = terminal_size(stdout_fd);
    let openpty_result = openpty(Some(&winsize), None).context("failed to open child PTY")?;
    let master_for_input = dup(&openpty_result.master).context("failed to duplicate PTY master")?;
    let master_for_output = openpty_result.master;
    let slave = openpty_result.slave;

    let session = resolve_terminal_session(&cli);
    let mut child = spawn_child(&cli, &session, &slave).context("failed to spawn child command")?;
    drop(slave);

    if cli.print_status_json {
        StartupStatus::from_child(&cli, &session, &child).print_json()?;
    }

    trace.event(
        "child_started",
        json!({
            "pid": child.id(),
            "mode": if enhanced_mode { "enhanced" } else { "raw" },
            "backend": cli.backend,
            "session_id": session.session_id,
            "status_file": session.status_file.as_ref(),
        }),
    );
    let lsp = start_terminal_lsp(&cli, &session, enhanced_mode, &trace);

    let _raw_terminal = if stdin_is_tty {
        Some(RawTerminal::enter(stdin.as_fd()).context("failed to enter raw terminal mode")?)
    } else {
        None
    };

    start_resize_thread(stdout_fd, dup(&master_for_output)?, trace.clone())?;

    let prompt_state = Arc::new(Mutex::new(PromptState::PassThrough));
    let stdout_lock = Arc::new(Mutex::new(()));
    let input_prompt_state = Arc::clone(&prompt_state);
    let input_stdout_lock = Arc::clone(&stdout_lock);
    let input_trace = trace.clone();
    let _input_thread = thread::spawn(move || {
        forward_stdin_to_pty(
            master_for_input,
            enhanced_mode,
            stdout_fd,
            input_prompt_state,
            input_stdout_lock,
            input_trace,
            lsp,
        )
    });
    let output_trace = trace.clone();
    let output_thread = thread::spawn(move || {
        forward_pty_to_stdout(master_for_output, output_trace, prompt_state, stdout_lock)
    });

    let status = child.wait().context("failed waiting for child process")?;
    trace.event("child_exited", json!({ "code": exit_status_code(status) }));

    let _ = output_thread.join();

    Ok(exit_status_code(status))
}

fn spawn_child(cli: &Cli, session: &TerminalLspSession, slave: &OwnedFd) -> anyhow::Result<Child> {
    let stdin_fd = dup(slave)?;
    let stdout_fd = dup(slave)?;
    let stderr_fd = dup(slave)?;
    let controlling_tty_fd = slave.as_raw_fd();

    let mut command = Command::new(&cli.child_command[0]);
    command.args(cli.child_command.iter().skip(1));
    command.stdin(Stdio::from(stdin_fd));
    command.stdout(Stdio::from(stdout_fd));
    command.stderr(Stdio::from(stderr_fd));

    if let Some(status_dir) = &cli.status_dir {
        command.env("ARK_STATUS_DIR", status_dir);
    }
    command.env("ARK_SESSION_KIND", &session.kind);
    command.env("ARK_SESSION_BACKEND", &session.backend);
    command.env("ARK_SESSION_ID", &session.session_id);
    command.env("ARK_SESSION_TIMEOUT_MS", session.timeout_ms.to_string());
    if let Some(status_file) = &session.status_file {
        command.env("ARK_SESSION_STATUS_FILE", status_file);
    }
    if !session.tmux_socket.is_empty() {
        command.env("ARK_SESSION_TMUX_SOCKET", &session.tmux_socket);
    }
    if !session.tmux_session.is_empty() {
        command.env("ARK_SESSION_TMUX_SESSION", &session.tmux_session);
    }
    if !session.tmux_pane.is_empty() {
        command.env("ARK_SESSION_TMUX_PANE", &session.tmux_pane);
    }
    if let Some(ark_lsp) = &cli.ark_lsp {
        command.env("ARK_NVIM_LSP_BIN", ark_lsp);
    }

    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(controlling_tty_fd, libc::TIOCSCTTY, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }

    command.spawn().map_err(Into::into)
}

fn forward_stdin_to_pty(
    master: OwnedFd,
    enhanced_mode: bool,
    host_stdout_fd: i32,
    prompt_state: Arc<Mutex<PromptState>>,
    stdout_lock: Arc<Mutex<()>>,
    trace: TraceLog,
    mut lsp: Option<TerminalLspHandle>,
) -> io::Result<()> {
    let mut master = file_from_owned_fd(master);
    let stdin_handle = io::stdin();
    let stdin_fd = stdin_handle.as_fd().as_raw_fd();
    let mut stdin = stdin_handle.lock();
    let mut enhanced = EnhancedInputRuntime::new();
    let mut renderer = LocalInputRenderer::new();
    let mut completion_menu: Option<ActiveCompletionMenu> = None;
    let mut buffer = [0; 8192];

    loop {
        drain_lsp_events(
            &mut lsp,
            &trace,
            Some(&mut renderer),
            Some(&stdout_lock),
            Some(&mut completion_menu),
        )?;
        if enhanced_mode && !stdin_ready(stdin_fd)? {
            continue;
        }
        let read = stdin.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        if enhanced_mode {
            let state = *prompt_state.lock().unwrap_or_else(|err| err.into_inner());
            renderer.set_terminal_cols(usize::from(terminal_size(host_stdout_fd).ws_col));
            if accept_completion_if_requested(
                &buffer[..read],
                state,
                &mut enhanced,
                &mut renderer,
                &stdout_lock,
                &trace,
                &mut lsp,
                &mut completion_menu,
            )? {
                drain_lsp_events(
                    &mut lsp,
                    &trace,
                    Some(&mut renderer),
                    Some(&stdout_lock),
                    Some(&mut completion_menu),
                )?;
                continue;
            }
            completion_menu = None;
            for effect in enhanced.handle_bytes(&buffer[..read], state) {
                consume_input_effect(
                    effect,
                    state,
                    &mut master,
                    &mut renderer,
                    &stdout_lock,
                    &trace,
                    &mut lsp,
                )?;
                drain_lsp_events(
                    &mut lsp,
                    &trace,
                    Some(&mut renderer),
                    Some(&stdout_lock),
                    Some(&mut completion_menu),
                )?;
            }
        } else {
            master.write_all(&buffer[..read])?;
            master.flush()?;
        }
    }

    drain_lsp_events(
        &mut lsp,
        &trace,
        Some(&mut renderer),
        Some(&stdout_lock),
        Some(&mut completion_menu),
    )?;
    Ok(())
}

fn consume_input_effect(
    effect: InputEffect,
    prompt_state: PromptState,
    master: &mut File,
    renderer: &mut LocalInputRenderer,
    stdout_lock: &Arc<Mutex<()>>,
    trace: &TraceLog,
    lsp: &mut Option<TerminalLspHandle>,
) -> io::Result<()> {
    match effect {
        InputEffect::Forward(bytes) => {
            write_stdout_bytes(&renderer.clear_to_prompt(prompt_state), stdout_lock)?;
            master.write_all(&bytes)?;
            master.flush()?;
            trace.event(
                "enhanced_forward",
                json!({
                    "bytes": bytes.len(),
                    "prompt_state": prompt_state.as_str(),
                }),
            );
        },
        InputEffect::Redraw(snapshot) => {
            if let Some(lsp) = lsp.as_ref() {
                if !lsp.sync_snapshot(&snapshot) {
                    trace.event("lsp_sync_dropped", json!({}));
                }
            }
            let bytes = renderer.redraw(&snapshot, prompt_state);
            write_stdout_bytes(&bytes, stdout_lock)?;
            trace.event(
                "enhanced_redraw",
                json!({
                    "chars": snapshot.display_cursor,
                    "bytes": snapshot.text.len(),
                    "prompt_state": prompt_state.as_str(),
                }),
            );
        },
        InputEffect::Completion {
            snapshot,
            trigger_character,
        } => {
            if let Some(lsp) = lsp.as_mut() {
                if let Some(sequence) = lsp.request_completion(&snapshot, Some(&trigger_character))
                {
                    trace.event(
                        "lsp_completion_request",
                        json!({
                            "sequence": sequence,
                            "trigger_character": trigger_character,
                            "bytes": snapshot.text.len(),
                            "cursor": snapshot.cursor,
                            "prompt_state": prompt_state.as_str(),
                        }),
                    );
                } else {
                    trace.event("lsp_completion_dropped", json!({}));
                }
            }
        },
        InputEffect::ReverseSearch(snapshot) => {
            let bytes = renderer.redraw_reverse_search(&snapshot, prompt_state);
            write_stdout_bytes(&bytes, stdout_lock)?;
            trace.event(
                "enhanced_reverse_search",
                json!({
                    "matched": snapshot.result.is_some(),
                    "prompt_state": prompt_state.as_str(),
                    "query_bytes": snapshot.query.len(),
                }),
            );
        },
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn accept_completion_if_requested(
    bytes: &[u8],
    prompt_state: PromptState,
    enhanced: &mut EnhancedInputRuntime,
    renderer: &mut LocalInputRenderer,
    stdout_lock: &Arc<Mutex<()>>,
    trace: &TraceLog,
    lsp: &mut Option<TerminalLspHandle>,
    completion_menu: &mut Option<ActiveCompletionMenu>,
) -> io::Result<bool> {
    if !matches!(bytes, b"\t" | b"\n" | b"\r") {
        return Ok(false);
    }

    let Some(menu) = completion_menu.take() else {
        return Ok(false);
    };
    let Some(item) = menu.selected_item() else {
        return Ok(false);
    };

    match apply_completion_item(&enhanced.snapshot(), item) {
        Ok(applied) => {
            let snapshot = enhanced.replace_text_and_cursor(applied.text, applied.cursor);
            if let Some(lsp) = lsp.as_ref() {
                if !lsp.sync_snapshot(&snapshot) {
                    trace.event("lsp_sync_dropped", json!({}));
                }
            }
            let bytes = renderer.redraw(&snapshot, prompt_state);
            write_stdout_bytes(&bytes, stdout_lock)?;
            trace.event(
                "lsp_completion_accept",
                json!({
                    "selected": menu.selected,
                    "bytes": snapshot.text.len(),
                    "cursor": snapshot.cursor,
                }),
            );
        },
        Err(err) => {
            trace.event(
                "lsp_completion_accept_failed",
                json!({
                    "error": err.to_string(),
                }),
            );
        },
    }

    Ok(true)
}

fn start_terminal_lsp(
    cli: &Cli,
    session: &TerminalLspSession,
    enhanced_mode: bool,
    trace: &TraceLog,
) -> Option<TerminalLspHandle> {
    if !enhanced_mode || cli.no_lsp {
        return None;
    }

    let Some(ark_lsp) = cli.ark_lsp.clone() else {
        trace.event("lsp_disabled", json!({ "reason": "missing ark-lsp path" }));
        return None;
    };

    match TerminalLspHandle::spawn_ark_lsp(ark_lsp, session.clone()) {
        Ok(lsp) => {
            trace.event(
                "lsp_worker_spawned",
                json!({
                    "session_id": session.session_id,
                    "status_file": session.status_file.as_ref(),
                    "backend": session.backend,
                }),
            );
            Some(lsp)
        },
        Err(err) => {
            trace.event(
                "lsp_worker_spawn_failed",
                json!({
                    "error": err.to_string(),
                }),
            );
            None
        },
    }
}

fn resolve_terminal_session(cli: &Cli) -> TerminalLspSession {
    let tmux_socket = cli
        .session_tmux_socket
        .clone()
        .or_else(tmux_socket_from_env)
        .unwrap_or_default();
    let tmux_pane = cli
        .session_tmux_pane
        .clone()
        .or_else(|| env_non_empty("TMUX_PANE"))
        .unwrap_or_default();
    let tmux_session = cli
        .session_tmux_session
        .clone()
        .or_else(|| tmux_session_name(&tmux_socket, &tmux_pane))
        .unwrap_or_default();

    let session_id = cli
        .session_id
        .clone()
        .or_else(|| tmux_session_id(&tmux_socket, &tmux_session, &tmux_pane))
        .unwrap_or_else(|| format!("ark-terminal-{}", std::process::id()));

    let mut session = TerminalLspSession::new(session_id);
    session.kind = cli
        .session_kind
        .clone()
        .unwrap_or_else(|| String::from("ark"));
    session.backend = cli.backend.clone();
    session.timeout_ms = cli.session_timeout_ms.unwrap_or(1000);
    session.tmux_socket = tmux_socket;
    session.tmux_session = tmux_session;
    session.tmux_pane = tmux_pane;
    session.status_file = cli
        .session_status_file
        .clone()
        .or_else(|| status_file_from_dir(cli.status_dir.as_deref(), &session.session_id));

    session
}

fn env_non_empty(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

fn tmux_socket_from_env() -> Option<String> {
    env_non_empty("ARK_TMUX_SOCKET").or_else(|| {
        env_non_empty("TMUX").and_then(|value| value.split(',').next().map(ToString::to_string))
    })
}

fn tmux_session_name(socket: &str, pane: &str) -> Option<String> {
    if socket.is_empty() || pane.is_empty() {
        return None;
    }

    let output = Command::new("tmux")
        .arg("-S")
        .arg(socket)
        .arg("display-message")
        .arg("-p")
        .arg("-t")
        .arg(pane)
        .arg("#{session_name}")
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    String::from_utf8(output.stdout)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn tmux_session_id(socket: &str, session: &str, pane: &str) -> Option<String> {
    if socket.is_empty() || session.is_empty() || pane.is_empty() {
        return None;
    }

    Some(
        [socket, session, pane]
            .into_iter()
            .map(encode_status_component)
            .collect::<Vec<_>>()
            .join("__"),
    )
}

fn encode_status_component(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' | b'-' => {
                encoded.push(char::from(byte));
            },
            _ => {
                encoded.push_str(&format!("%{byte:02X}"));
            },
        }
    }
    encoded
}

fn status_file_from_dir(status_dir: Option<&Path>, session_id: &str) -> Option<std::path::PathBuf> {
    if session_id.is_empty() {
        return None;
    }

    let mut path = status_dir?.to_path_buf();
    path.push(format!("{session_id}.json"));
    Some(path)
}

fn drain_lsp_events(
    lsp: &mut Option<TerminalLspHandle>,
    trace: &TraceLog,
    mut renderer: Option<&mut LocalInputRenderer>,
    stdout_lock: Option<&Arc<Mutex<()>>>,
    mut active_completion_menu: Option<&mut Option<ActiveCompletionMenu>>,
) -> io::Result<()> {
    let Some(handle) = lsp.as_mut() else {
        return Ok(());
    };

    let mut failed = false;
    for event in handle.drain_events() {
        match event {
            TerminalLspEvent::Started { child_id } => {
                trace.event("lsp_child_started", json!({ "pid": child_id }));
            },
            TerminalLspEvent::Initialized => {
                trace.event("lsp_initialized", json!({}));
            },
            TerminalLspEvent::SnapshotSynced { version } => {
                trace.event("lsp_snapshot_synced", json!({ "version": version }));
            },
            TerminalLspEvent::Completion {
                sequence,
                trigger_character,
                item_count,
                items,
            } => {
                trace.event(
                    "lsp_completion_response",
                    json!({
                        "sequence": sequence,
                        "trigger_character": trigger_character,
                        "item_count": item_count,
                    }),
                );
                if let (Some(renderer), Some(stdout_lock)) = (renderer.as_deref_mut(), stdout_lock)
                {
                    let menu = active_completion_menu_from_lsp_items(&items);
                    let snapshot = menu.snapshot();
                    let bytes = renderer.redraw_completion_menu(&snapshot);
                    write_stdout_bytes(&bytes, stdout_lock)?;
                    if let Some(active_completion_menu) = active_completion_menu.as_deref_mut() {
                        *active_completion_menu = if snapshot.items.is_empty() {
                            None
                        } else {
                            Some(menu)
                        };
                    }
                    if !snapshot.items.is_empty() {
                        trace.event(
                            "lsp_completion_menu",
                            json!({
                                "sequence": sequence,
                                "items": snapshot.items.len(),
                            }),
                        );
                    }
                }
            },
            TerminalLspEvent::Error { message } => {
                trace.event("lsp_error", json!({ "message": message }));
                failed = true;
            },
        }
    }

    if failed {
        *lsp = None;
    }

    Ok(())
}

fn active_completion_menu_from_lsp_items(items: &[Value]) -> ActiveCompletionMenu {
    let mut seen = HashSet::new();
    let mut menu_items = Vec::new();

    for item in items {
        let Some(label) = item.get("label").and_then(Value::as_str) else {
            continue;
        };
        if label.is_empty() || !seen.insert(label.to_string()) {
            continue;
        }
        menu_items.push(item.clone());
    }

    ActiveCompletionMenu {
        items: menu_items,
        selected: 0,
    }
}

fn completion_menu_item(item: &Value) -> Option<CompletionMenuItem> {
    let label = item.get("label").and_then(Value::as_str)?;
    if label.is_empty() {
        return None;
    }
    let detail = item
        .get("detail")
        .and_then(Value::as_str)
        .filter(|detail| !detail.is_empty())
        .map(ToString::to_string);
    Some(CompletionMenuItem {
        label: label.to_string(),
        detail,
    })
}

fn forward_pty_to_stdout(
    master: OwnedFd,
    trace: TraceLog,
    prompt_state: Arc<Mutex<PromptState>>,
    stdout_lock: Arc<Mutex<()>>,
) -> io::Result<()> {
    let mut master = file_from_owned_fd(master);
    let mut detector = PromptDetector::new();
    let mut buffer = [0; 8192];

    loop {
        match master.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                write_stdout_bytes(&buffer[..read], &stdout_lock)?;
                for transition in detector.push_bytes(&buffer[..read]) {
                    *prompt_state.lock().unwrap_or_else(|err| err.into_inner()) =
                        transition.current;
                    trace.event(
                        "prompt_state",
                        json!({
                            "previous": transition.previous.as_str(),
                            "current": transition.current.as_str(),
                        }),
                    );
                }
            },
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) if err.raw_os_error() == Some(libc::EIO) => break,
            Err(err) => return Err(err),
        }
    }

    Ok(())
}

fn write_stdout_bytes(bytes: &[u8], stdout_lock: &Arc<Mutex<()>>) -> io::Result<()> {
    if bytes.is_empty() {
        return Ok(());
    }

    let _guard = stdout_lock.lock().unwrap_or_else(|err| err.into_inner());
    let mut stdout = io::stdout().lock();
    stdout.write_all(bytes)?;
    stdout.flush()
}

fn start_resize_thread(host_fd: i32, master: OwnedFd, trace: TraceLog) -> anyhow::Result<()> {
    let mut signals = SigSet::empty();
    signals.add(Signal::SIGWINCH);
    pthread_sigmask(SigmaskHow::SIG_BLOCK, Some(&signals), None)?;
    resize_pty_from_host(host_fd, master.as_raw_fd(), &trace);

    thread::Builder::new()
        .name("ark-terminal-sigwinch".to_string())
        .spawn(move || {
            while signals.wait().is_ok() {
                resize_pty_from_host(host_fd, master.as_raw_fd(), &trace);
            }
        })
        .context("failed to start resize signal thread")?;

    Ok(())
}

fn resize_pty_from_host(host_fd: i32, pty_fd: i32, trace: &TraceLog) {
    let winsize = terminal_size(host_fd);
    if set_terminal_size(pty_fd, winsize).is_ok() {
        trace.event(
            "resize",
            json!({
                "rows": winsize.ws_row,
                "cols": winsize.ws_col,
            }),
        );
    }
}

fn terminal_size(fd: i32) -> Winsize {
    let mut winsize = Winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };

    unsafe {
        if libc::ioctl(fd, libc::TIOCGWINSZ, &mut winsize) == -1 ||
            winsize.ws_row == 0 ||
            winsize.ws_col == 0
        {
            winsize.ws_row = 24;
            winsize.ws_col = 80;
            winsize.ws_xpixel = 0;
            winsize.ws_ypixel = 0;
        }
    }

    winsize
}

fn set_terminal_size(fd: i32, winsize: Winsize) -> io::Result<()> {
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &winsize) } == -1 {
        return Err(io::Error::last_os_error());
    }

    Ok(())
}

fn stdin_ready(fd: i32) -> io::Result<bool> {
    let borrowed = unsafe { BorrowedFd::borrow_raw(fd) };
    let mut poll_fds = [PollFd::new(
        borrowed,
        PollFlags::POLLIN | PollFlags::POLLHUP | PollFlags::POLLERR,
    )];
    let count =
        poll(&mut poll_fds, PollTimeout::from(ENHANCED_STDIN_POLL_MS)).map_err(io::Error::other)?;
    if count == 0 {
        return Ok(false);
    }

    let revents = poll_fds[0].revents().unwrap_or_else(PollFlags::empty);
    if revents.contains(PollFlags::POLLERR) {
        return Err(io::Error::other("stdin poll returned POLLERR"));
    }

    Ok(revents.intersects(PollFlags::POLLIN | PollFlags::POLLHUP))
}

fn is_tty(fd: i32) -> bool {
    unsafe { libc::isatty(fd) == 1 }
}

fn file_from_owned_fd(fd: OwnedFd) -> File {
    unsafe { File::from_raw_fd(fd.into_raw_fd()) }
}

fn exit_status_code(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }

    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return 128 + signal;
        }
    }

    1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completion_menu_preserves_lsp_order_and_deduplicates_labels() {
        let menu = active_completion_menu_from_lsp_items(&[
            json!({"label": "mpg", "detail": "field"}),
            json!({"label": "cyl", "detail": "field"}),
            json!({"label": "mpg", "detail": "duplicate"}),
            json!({"label": ""}),
            json!({"detail": "missing label"}),
        ]);

        assert_eq!(menu.snapshot(), CompletionMenuSnapshot {
            selected: 0,
            items: vec![
                CompletionMenuItem {
                    label: "mpg".to_string(),
                    detail: Some("field".to_string()),
                },
                CompletionMenuItem {
                    label: "cyl".to_string(),
                    detail: Some("field".to_string()),
                },
            ],
        });
        assert_eq!(menu.selected_item().unwrap()["label"], "mpg");
    }

    #[test]
    fn tmux_session_id_matches_launcher_status_encoding() {
        let session_id = tmux_session_id("/tmp/tmux-60349/default", "repos_ark_nvim", "%195");
        assert_eq!(
            session_id.as_deref(),
            Some("%2Ftmp%2Ftmux-60349%2Fdefault__repos_ark_nvim__%25195")
        );
    }
}
