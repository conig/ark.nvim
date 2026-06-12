use std::env;
use std::ffi::OsString;
use std::path::PathBuf;

use anyhow::anyhow;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cli {
    pub ark_lsp: Option<PathBuf>,
    pub status_dir: Option<PathBuf>,
    pub session_id: Option<String>,
    pub backend: String,
    pub raw: bool,
    pub no_lsp: bool,
    pub trace_log: Option<PathBuf>,
    pub print_status_json: bool,
    pub child_command: Vec<OsString>,
    pub help: bool,
    pub version: bool,
}

impl Cli {
    pub fn parse<I, S>(args: I) -> anyhow::Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let mut ark_lsp = env_path("ARK_NVIM_LSP_BIN");
        let mut status_dir = env_path("ARK_STATUS_DIR");
        let mut session_id = env_string("ARK_SESSION_ID");
        let mut backend = env_string("ARK_SESSION_BACKEND").unwrap_or_else(|| "tmux".to_string());
        let mut raw = false;
        let mut no_lsp = false;
        let mut trace_log = None;
        let mut print_status_json = false;
        let mut child_command = Vec::new();
        let mut help = false;
        let mut version = false;

        let mut iter = args.into_iter().map(Into::into).peekable();
        while let Some(arg) = iter.next() {
            let Some(arg_str) = arg.to_str() else {
                return Err(anyhow!(
                    "ark-terminal arguments must be valid UTF-8 before `--`"
                ));
            };

            match arg_str {
                "--" => {
                    child_command.extend(iter);
                    break;
                },
                "--ark-lsp" => ark_lsp = Some(required_path(&mut iter, "--ark-lsp")?),
                "--status-dir" => status_dir = Some(required_path(&mut iter, "--status-dir")?),
                "--session-id" => session_id = Some(required_string(&mut iter, "--session-id")?),
                "--backend" => backend = required_string(&mut iter, "--backend")?,
                "--raw" => raw = true,
                "--no-lsp" => no_lsp = true,
                "--trace-log" => trace_log = Some(required_path(&mut iter, "--trace-log")?),
                "--print-status-json" => print_status_json = true,
                "-h" | "--help" => help = true,
                "-V" | "--version" => version = true,
                other if other.starts_with('-') => {
                    return Err(anyhow!("unknown ark-terminal argument: {other}"));
                },
                _ => {
                    return Err(anyhow!(
                        "unexpected child command argument `{arg_str}`; pass child commands after `--`"
                    ));
                },
            }
        }

        if child_command.is_empty() && !help && !version {
            child_command = default_child_command();
        }

        Ok(Self {
            ark_lsp,
            status_dir,
            session_id,
            backend,
            raw,
            no_lsp,
            trace_log,
            print_status_json,
            child_command,
            help,
            version,
        })
    }

    pub fn usage() -> &'static str {
        concat!(
            "Usage: ark-terminal [OPTIONS] [-- CHILD [ARGS]...]\n",
            "\n",
            "Options:\n",
            "  --ark-lsp PATH          Path to ark-lsp for future enhanced mode\n",
            "  --status-dir DIR        Ark status directory to pass to the child\n",
            "  --session-id ID         Stable managed-session id\n",
            "  --backend NAME          Session backend name (default: tmux)\n",
            "  --raw                   Force transparent PTY pass-through mode\n",
            "  --no-lsp                Disable Ark LSP startup in enhanced mode\n",
            "  --trace-log PATH        Write JSON-lines frontend diagnostics\n",
            "  --print-status-json     Print startup metadata JSON after spawning child\n",
            "  -h, --help              Show this help\n",
            "  -V, --version           Show version\n"
        )
    }
}

fn required_path<I>(iter: &mut I, flag: &str) -> anyhow::Result<PathBuf>
where
    I: Iterator<Item = OsString>,
{
    Ok(PathBuf::from(required_os(iter, flag)?))
}

fn required_string<I>(iter: &mut I, flag: &str) -> anyhow::Result<String>
where
    I: Iterator<Item = OsString>,
{
    required_os(iter, flag)?
        .into_string()
        .map_err(|_| anyhow!("{flag} requires a UTF-8 value"))
}

fn required_os<I>(iter: &mut I, flag: &str) -> anyhow::Result<OsString>
where
    I: Iterator<Item = OsString>,
{
    iter.next()
        .ok_or_else(|| anyhow!("{flag} requires a value"))
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn env_string(name: &str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.is_empty())
}

fn default_child_command() -> Vec<OsString> {
    if let Some(launcher) = env::var_os("ARK_NVIM_LAUNCHER").filter(|value| !value.is_empty()) {
        return vec![launcher];
    }

    let mut command = vec![env::var_os("ARK_NVIM_R_BIN").unwrap_or_else(|| OsString::from("R"))];
    let args = env::var("ARK_NVIM_R_ARGS").unwrap_or_else(|_| "--quiet --no-save".to_string());
    command.extend(args.split_whitespace().map(OsString::from));
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wrapper_options_and_child_after_separator() {
        let cli = Cli::parse([
            "--raw",
            "--no-lsp",
            "--backend",
            "terminal",
            "--session-id",
            "abc",
            "--status-dir",
            "/tmp/ark-status",
            "--trace-log",
            "/tmp/ark.log",
            "--print-status-json",
            "--",
            "R",
            "--quiet",
        ])
        .unwrap();

        assert!(cli.raw);
        assert!(cli.no_lsp);
        assert_eq!(cli.backend, "terminal");
        assert_eq!(cli.session_id.as_deref(), Some("abc"));
        assert_eq!(
            cli.status_dir.as_deref(),
            Some(std::path::Path::new("/tmp/ark-status"))
        );
        assert_eq!(
            cli.trace_log.as_deref(),
            Some(std::path::Path::new("/tmp/ark.log"))
        );
        assert!(cli.print_status_json);
        assert_eq!(cli.child_command, vec![
            OsString::from("R"),
            OsString::from("--quiet")
        ]);
    }

    #[test]
    fn rejects_child_without_separator() {
        let err = Cli::parse(["R", "--quiet"]).unwrap_err();
        assert!(err.to_string().contains("after `--`"));
    }
}
