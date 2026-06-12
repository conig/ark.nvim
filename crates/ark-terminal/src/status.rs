use std::path::Path;
use std::process::Child;

use serde::Serialize;

use crate::Cli;

#[derive(Debug, Serialize)]
pub struct StartupStatus {
    pub status: &'static str,
    pub mode: &'static str,
    pub child_pid: u32,
    pub backend: String,
    pub session_id: Option<String>,
    pub status_dir: Option<String>,
    pub ark_lsp: Option<String>,
    pub no_lsp: bool,
    pub child_command: Vec<String>,
}

impl StartupStatus {
    pub fn from_child(cli: &Cli, child: &Child) -> Self {
        Self {
            status: "started",
            mode: if cli.raw || cli.no_lsp {
                "raw"
            } else {
                "raw-fallback"
            },
            child_pid: child.id(),
            backend: cli.backend.clone(),
            session_id: cli.session_id.clone(),
            status_dir: cli.status_dir.as_ref().map(path_to_string),
            ark_lsp: cli.ark_lsp.as_ref().map(path_to_string),
            no_lsp: cli.no_lsp,
            child_command: cli
                .child_command
                .iter()
                .map(|value| value.to_string_lossy().into_owned())
                .collect(),
        }
    }

    pub fn print_json(&self) -> anyhow::Result<()> {
        println!("{}", serde_json::to_string(self)?);
        Ok(())
    }
}

fn path_to_string(path: &impl AsRef<Path>) -> String {
    path.as_ref().to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::*;

    #[test]
    fn raw_mode_status_is_serializable() {
        let cli = Cli {
            ark_lsp: Some("/tmp/ark-lsp".into()),
            status_dir: Some("/tmp/ark-status".into()),
            session_id: Some("session-1".into()),
            backend: "terminal".into(),
            raw: true,
            no_lsp: true,
            trace_log: None,
            print_status_json: true,
            child_command: vec![OsString::from("R")],
            help: false,
            version: false,
        };
        let status = StartupStatus {
            status: "started",
            mode: "raw",
            child_pid: 42,
            backend: cli.backend,
            session_id: cli.session_id,
            status_dir: cli
                .status_dir
                .map(|path| path.to_string_lossy().into_owned()),
            ark_lsp: cli.ark_lsp.map(|path| path.to_string_lossy().into_owned()),
            no_lsp: cli.no_lsp,
            child_command: vec!["R".to_string()],
        };

        let json = serde_json::to_string(&status).unwrap();
        assert!(json.contains("\"mode\":\"raw\""));
        assert!(json.contains("\"child_pid\":42"));
        assert!(json.contains("\"backend\":\"terminal\""));
    }
}
