//! A vanilla, stdin-owned R helper, shared by baseline hydration and help.
//! Reusing the process avoids paying R and tools startup on every help key.
use std::io::BufRead;
use std::io::BufReader;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Child;
use std::process::ChildStdin;
use std::process::Command;
use std::process::Stdio;
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::anyhow;

static WORKER: Mutex<Option<Worker>> = Mutex::new(None);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

pub(super) fn request(command: &str) -> anyhow::Result<String> {
    let mut slot = WORKER
        .lock()
        .map_err(|err| anyhow!("R metadata worker lock: {err}"))?;
    if slot.is_none() {
        *slot = Some(Worker::start()?);
    }
    let worker = slot
        .as_mut()
        .ok_or_else(|| anyhow!("R metadata worker unavailable"))?;
    let response = worker.request(command);
    // A protocol/transport failure discards the helper. The next request can
    // start fresh; ordinary R errors (including missing help) do not restart it.
    let response = match response {
        Ok(response) => response,
        Err(err) => {
            *slot = None;
            return Err(err);
        },
    };
    if response.0 == "ok" {
        Ok(response.1)
    } else {
        Err(anyhow!("detached R metadata helper failed: {}", response.1))
    }
}

struct Worker {
    child: Child,
    stdin: ChildStdin,
    responses: mpsc::Receiver<anyhow::Result<(String, String)>>,
    reader: Option<JoinHandle<()>>,
}

impl Worker {
    fn start() -> anyhow::Result<Self> {
        let rscript = std::env::var("ARK_NVIM_RSCRIPT")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| String::from("Rscript"));
        let script = format!(
            "baseline <- function() {{ {} }}\nrender_help <- function(topic) {{ {} }}\n{}",
            super::BASELINE_SCRIPT,
            super::HELP_TEXT_SCRIPT,
            WORKER_SCRIPT
        );
        Self::spawn(&rscript, &script)
    }

    fn spawn(rscript: &str, script: &str) -> anyhow::Result<Self> {
        let mut command = Command::new(rscript);
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command
            .args(["--vanilla", "-e", script])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| anyhow!("failed to start `{rscript}` metadata helper: {err}"))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("R helper stdin missing"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("R helper stdout missing"))?;
        let (sender, responses) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut stdout = BufReader::new(stdout);
            loop {
                let response = read_response(&mut stdout);
                let failed = response.is_err();
                if sender.send(response).is_err() || failed {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            responses,
            reader: Some(reader),
        })
    }

    fn request(&mut self, command: &str) -> anyhow::Result<(String, String)> {
        writeln!(self.stdin, "{command}")?;
        self.stdin.flush()?;
        self.responses
            .recv_timeout(REQUEST_TIMEOUT)
            .map_err(|err| anyhow!("R metadata helper response unavailable: {err}"))?
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // Rd expressions/package hooks can start ordinary descendants. Kill
        // the helper's group too so inherited stdout cannot strand the reader.
        #[cfg(unix)]
        if let Ok(pid) = i32::try_from(self.child.id()) {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(pid),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn read_response(reader: &mut impl BufRead) -> anyhow::Result<(String, String)> {
    let mut status = String::new();
    reader.read_line(&mut status)?;
    let status = status.trim_end();
    if status != "ok" && status != "error" {
        return Err(anyhow!("invalid R metadata helper response status"));
    }
    let mut length = String::new();
    reader.read_line(&mut length)?;
    let length: usize = length.trim_end().parse()?;
    if length > MAX_RESPONSE_BYTES {
        return Err(anyhow!("R metadata helper response too large"));
    }
    let mut text = vec![0; length];
    reader.read_exact(&mut text)?;
    Ok((status.to_string(), String::from_utf8(text)?))
}

// Topics are hex-encoded UTF-8 data, never R source. Byte framing keeps
// multiline help (including non-ASCII text) separate from protocol headers.
// stdin EOF terminates R when its owning LSP exits, even without Rust Drop.
const WORKER_SCRIPT: &str = r#"
# Keep unqualified fallback lookup equivalent to a fresh vanilla R. Rendering
# Rd expressions can load namespaces; those must not change later resolution.
help_packages <- loadedNamespaces()
input <- file("stdin", open = "r")
repeat {
  line <- readLines(input, n = 1L, warn = FALSE)
  if (!length(line)) break
  response <- tryCatch({
    if (identical(line, "bootstrap")) {
      text <- paste(capture.output(baseline()), collapse = "\n")
    } else if (startsWith(line, "help ")) {
      hex <- substring(line, 6L)
      starts <- seq.int(1L, nchar(hex), by = 2L)
      topic <- rawToChar(as.raw(strtoi(substring(hex, starts, starts + 1L), 16L)))
      Encoding(topic) <- "UTF-8"
      text <- paste(capture.output(render_help(topic)), collapse = "\n")
    } else stop("unknown metadata command")
    list(status = "ok", text = enc2utf8(text))
  }, error = function(err) list(status = "error", text = enc2utf8(conditionMessage(err))))
  cat(response$status, "\n", nchar(response$text, type = "bytes"), "\n", response$text, sep = "")
  flush(stdout())
}
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn timeout_reaps_pipe_holding_descendants() {
        use std::os::unix::fs::PermissionsExt;
        use std::time::Instant;

        let directory = tempfile::tempdir().unwrap();
        let launcher = directory.path().join("rscript");
        std::fs::write(&launcher, "#!/bin/sh\nsleep 30 &\nwait\n").unwrap();
        std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
        let started = Instant::now();
        let mut worker = Worker::spawn(launcher.to_str().unwrap(), "").unwrap();
        assert!(worker.request("bootstrap").is_err());
        drop(worker);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn dead_helper_is_discarded_and_next_request_recovers() {
        if Command::new("Rscript").arg("--version").output().is_err() {
            return;
        }
        let first = request("bootstrap").unwrap();
        {
            let mut slot = WORKER.lock().unwrap();
            slot.as_mut().unwrap().child.kill().unwrap();
        }
        assert!(request("bootstrap").is_err());
        assert!(WORKER.lock().unwrap().is_none());
        assert_eq!(request("bootstrap").unwrap(), first);
    }

    #[test]
    fn framing_preserves_multiline_unicode_and_next_response() {
        let mut frames = std::io::Cursor::new("ok\n5\na\né\nerror\n4\noops".as_bytes());
        assert_eq!(
            read_response(&mut frames).unwrap(),
            ("ok".into(), "a\né\n".into())
        );
        assert_eq!(
            read_response(&mut frames).unwrap(),
            ("error".into(), "oops".into())
        );
    }

    #[test]
    fn framing_rejects_truncated_or_unbounded_responses() {
        for frame in ["", "noise\n0\n", "ok\n999999999\n", "ok\n5\na"] {
            assert!(read_response(&mut std::io::Cursor::new(frame)).is_err());
        }
    }
}
