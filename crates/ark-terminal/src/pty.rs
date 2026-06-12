use std::fs::File;
use std::io::Read;
use std::io::Write;
use std::io::{self};
use std::os::fd::AsFd;
use std::os::fd::AsRawFd;
use std::os::fd::FromRawFd;
use std::os::fd::IntoRawFd;
use std::os::fd::OwnedFd;
use std::os::unix::process::CommandExt;
use std::process::Child;
use std::process::Command;
use std::process::ExitStatus;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use std::thread;

use anyhow::anyhow;
use anyhow::Context;
use nix::pty::openpty;
use nix::pty::Winsize;
use nix::sys::signal::pthread_sigmask;
use nix::sys::signal::SigSet;
use nix::sys::signal::SigmaskHow;
use nix::sys::signal::Signal;
use nix::unistd::dup;
use serde_json::json;

use crate::enhanced::EnhancedInputRuntime;
use crate::enhanced::InputEffect;
use crate::prompt::PromptDetector;
use crate::prompt::PromptState;
use crate::raw_terminal::RawTerminal;
use crate::render::LocalInputRenderer;
use crate::status::StartupStatus;
use crate::trace::TraceLog;
use crate::Cli;

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

    let mut child = spawn_child(&cli, &slave).context("failed to spawn child command")?;
    drop(slave);

    if cli.print_status_json {
        StartupStatus::from_child(&cli, &child).print_json()?;
    }

    trace.event(
        "child_started",
        json!({
            "pid": child.id(),
            "mode": if enhanced_mode { "enhanced" } else { "raw" },
            "backend": cli.backend,
            "session_id": cli.session_id,
        }),
    );

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

fn spawn_child(cli: &Cli, slave: &OwnedFd) -> anyhow::Result<Child> {
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
    if let Some(session_id) = &cli.session_id {
        command.env("ARK_SESSION_ID", session_id);
    }
    command.env("ARK_SESSION_BACKEND", &cli.backend);
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
) -> io::Result<()> {
    let mut master = file_from_owned_fd(master);
    let mut stdin = io::stdin().lock();
    let mut enhanced = EnhancedInputRuntime::new();
    let mut renderer = LocalInputRenderer::new();
    let mut buffer = [0; 8192];

    loop {
        let read = stdin.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        if enhanced_mode {
            let state = *prompt_state.lock().unwrap_or_else(|err| err.into_inner());
            renderer.set_terminal_cols(usize::from(terminal_size(host_stdout_fd).ws_col));
            for effect in enhanced.handle_bytes(&buffer[..read], state) {
                consume_input_effect(
                    effect,
                    state,
                    &mut master,
                    &mut renderer,
                    &stdout_lock,
                    &trace,
                )?;
            }
        } else {
            master.write_all(&buffer[..read])?;
            master.flush()?;
        }
    }

    Ok(())
}

fn consume_input_effect(
    effect: InputEffect,
    prompt_state: PromptState,
    master: &mut File,
    renderer: &mut LocalInputRenderer,
    stdout_lock: &Arc<Mutex<()>>,
    trace: &TraceLog,
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
