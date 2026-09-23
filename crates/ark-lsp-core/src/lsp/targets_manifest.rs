//! Project-scoped, bridge-evaluated target names. Diagnostics only read these
//! snapshots; they never evaluate a pipeline or wait for the R session.

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;

use serde_json::Value;
use url::Url;

use crate::lsp::backend::LspNotification;
use crate::lsp::indexer;
use crate::lsp::session_bridge::SessionBridge;
use crate::lsp::state::WorldState;
use crate::lsp::targets_project;

#[derive(Clone, Copy)]
pub(crate) enum TargetNames<'a> {
    Static,
    Unavailable,
    Manifest(&'a HashSet<String>),
}

#[derive(Clone, Debug, Default)]
pub(crate) struct TargetManifests {
    entries: HashMap<PathBuf, Entry>,
    dirty: HashSet<Url>,
    session_generation: u64,
    revision: u64,
}

#[derive(Clone, Debug)]
struct Entry {
    revision: u64,
    attempted: bool,
    names: Option<HashSet<String>>,
}

#[derive(Clone, Debug)]
pub(crate) struct ManifestRequest {
    root: PathBuf,
    script: PathBuf,
    revision: u64,
    session_generation: u64,
    bridge: SessionBridge,
}

#[derive(Debug)]
pub(crate) struct ManifestResult {
    pub request: ManifestRequest,
    pub result: anyhow::Result<Value>,
}

impl TargetManifests {
    pub(crate) fn revision(&self) -> u64 {
        self.revision
    }

    pub(crate) fn for_uri(&self, uri: &Url) -> TargetNames<'_> {
        let Some(root) = uri
            .to_file_path()
            .ok()
            .and_then(|path| targets_project::find_targets_root_for_path(&path))
        else {
            return TargetNames::Static;
        };
        match self.entries.get(&root) {
            Some(Entry {
                names: Some(names), ..
            }) => TargetNames::Manifest(names),
            Some(_) => TargetNames::Unavailable,
            None => TargetNames::Static,
        }
    }

    pub(crate) fn observe(&mut self, notification: &LspNotification) {
        match notification {
            LspNotification::DidOpenTextDocument(params) => {
                let uri = &params.text_document.uri;
                if uri
                    .to_file_path()
                    .ok()
                    .and_then(|path| std::fs::read_to_string(path).ok())
                    .is_none_or(|contents| contents != params.text_document.text)
                {
                    self.dirty.insert(uri.clone());
                    self.invalidate_source(uri, false);
                }
            },
            LspNotification::DidChangeTextDocument(params) => {
                self.dirty.insert(params.text_document.uri.clone());
                self.invalidate_source(&params.text_document.uri, false);
            },
            LspNotification::DidSaveTextDocument(params) => {
                self.dirty.remove(&params.text_document.uri);
                self.invalidate_source(&params.text_document.uri, true);
            },
            LspNotification::DidCloseTextDocument(params) => {
                if self.dirty.remove(&params.text_document.uri) {
                    self.invalidate_source(&params.text_document.uri, false);
                }
            },
            LspNotification::DidChangeWatchedFiles(params) => {
                for change in &params.changes {
                    self.invalidate_source(&change.uri, true);
                }
            },
            LspNotification::DidCreateFiles(params) => {
                for file in &params.files {
                    if let Ok(uri) = Url::parse(&file.uri) {
                        self.invalidate_source(&uri, true);
                    }
                }
            },
            LspNotification::DidDeleteFiles(params) => {
                for file in &params.files {
                    if let Ok(uri) = Url::parse(&file.uri) {
                        self.invalidate_source(&uri, true);
                    }
                }
            },
            LspNotification::DidRenameFiles(params) => {
                for file in &params.files {
                    for value in [&file.old_uri, &file.new_uri] {
                        if let Ok(uri) = Url::parse(value) {
                            self.invalidate_source(&uri, true);
                        }
                    }
                }
            },
            _ => {},
        }
    }

    fn invalidate_source(&mut self, uri: &Url, disk_change: bool) {
        for (root, entry) in &mut self.entries {
            // A new/deleted R source may not yet be in the static index. Disk
            // changes are conservative; ordinary typing only invalidates known
            // pipeline inputs so editing an analysis buffer never runs R.
            let changed_r_file = disk_change &&
                uri.to_file_path().is_ok_and(|path| {
                    path.starts_with(root) &&
                        path.extension().is_some_and(|ext| ext == "R" || ext == "r")
                });
            if changed_r_file || is_source(uri, root) {
                self.revision += 1;
                *entry = Entry {
                    revision: self.revision,
                    attempted: false,
                    names: None,
                };
            }
        }
    }

    pub(crate) fn is_current(&self, request: &ManifestRequest) -> bool {
        self.session_generation == request.session_generation &&
            self.entries
                .get(&request.root)
                .is_some_and(|entry| entry.revision == request.revision)
    }

    pub(crate) fn apply(&mut self, output: ManifestResult) {
        if !self.is_current(&output.request) {
            return;
        }
        let names = match output.result {
            Ok(payload) => manifest_names(&payload),
            Err(err) => {
                log::trace!(
                    "Target manifest unavailable for {}: {err:?}",
                    output.request.root.display()
                );
                None
            },
        };
        if let Some(entry) = self.entries.get_mut(&output.request.root) {
            // Replace rather than union: renamed/removed targets and literal
            // template names are not members of the evaluated graph.
            entry.names = names;
            self.revision += 1;
        }
    }
}

fn is_source(uri: &Url, root: &Path) -> bool {
    let Ok(path) = uri.to_file_path() else {
        return false;
    };
    path == targets_project::targets_config_path(root) ||
        (path.starts_with(root) && indexer::is_targets_pipeline_uri(uri))
}

pub(crate) fn prepare(state: &mut WorldState) -> Vec<ManifestRequest> {
    let roots: HashSet<_> = state
        .documents
        .keys()
        .filter_map(|uri| targets_project::find_targets_root_for_path(&uri.to_file_path().ok()?))
        .collect();
    let ready = state.session_bridge.is_some() && state.detached_session_hydrated();
    let cache = &mut state.target_manifests;
    if cache.session_generation != state.detached_session_update_generation {
        cache.entries.clear();
        cache.session_generation = state.detached_session_update_generation;
        cache.revision += 1;
    }
    cache.entries.retain(|root, _| roots.contains(root));
    if !ready {
        return Vec::new();
    }
    let Some(bridge) = &state.session_bridge else {
        return Vec::new();
    };

    let mut requests = Vec::new();
    for root in roots {
        let dirty = cache.dirty.iter().any(|uri| is_source(uri, &root));
        let entry = cache.entries.entry(root.clone()).or_insert_with(|| {
            cache.revision += 1;
            Entry {
                revision: cache.revision,
                attempted: false,
                names: None,
            }
        });
        if dirty {
            // Source discovery can finish after didOpen/didChange. Discard a
            // disk result if that newly discovered input has unsaved changes.
            if entry.attempted {
                cache.revision += 1;
                *entry = Entry {
                    revision: cache.revision,
                    attempted: false,
                    names: None,
                };
            }
            continue;
        }
        if entry.attempted {
            continue;
        }
        entry.attempted = true;
        requests.push(ManifestRequest {
            script: targets_project::targets_script_for_root(&root),
            root,
            revision: entry.revision,
            session_generation: cache.session_generation,
            bridge: bridge.clone(),
        });
    }
    requests
}

impl ManifestRequest {
    pub(crate) fn session_generation(&self) -> u64 {
        self.session_generation
    }

    pub(crate) fn run(&self) -> anyhow::Result<Value> {
        self.bridge.targets_manifest(
            self.root.to_string_lossy().into_owned(),
            self.script.to_string_lossy().into_owned(),
            String::new(),
        )
    }

    pub(crate) fn with_control(
        mut self,
        control: crate::lsp::session_bridge_runtime::BridgeRequestControl,
    ) -> Self {
        self.bridge = self.bridge.with_request_control(control);
        self
    }
}

fn manifest_names(payload: &Value) -> Option<HashSet<String>> {
    // The bridge deliberately falls back to a partial static manifest on
    // evaluation errors. Only a successful targets manifest proves absence.
    if payload.get("status")?.as_str()? != "ok" || payload.get("source")?.as_str()? != "targets" {
        return None;
    }
    payload
        .get("targets")?
        .as_array()?
        .iter()
        .map(|target| {
            let name = target.get("name")?.as_str()?;
            (!name.is_empty()).then(|| name.to_string())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lsp::document::Document;
    use crate::lsp::session_bridge::SessionBridgeConfig;
    use crate::lsp::state::DetachedSessionStatus;
    use crate::lsp::state::RuntimeMode;

    fn project(state: &mut WorldState) -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("_targets.R"), "list()\n").unwrap();
        let uri = Url::from_file_path(root.path().join("report.R")).unwrap();
        state
            .documents
            .insert(uri, Document::new("tar_read(generated_north)", None));
        root
    }

    fn state() -> WorldState {
        WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(
                SessionBridge::new(SessionBridgeConfig {
                    host: String::from("127.0.0.1"),
                    port: 1,
                    auth_token: String::from("test-token"),
                    status_file: None,
                    backend: String::from("tmux"),
                    session_id: String::from("test-session"),
                    tmux_socket: String::new(),
                    tmux_session: String::new(),
                    tmux_pane: String::new(),
                    timeout_ms: 50,
                })
                .unwrap(),
            ),
            console_scopes: vec![vec![String::from("tar_read")]],
            library: oak_semantic::library::Library::new(vec![PathBuf::from("/tmp/test-library")]),
            detached_session_completed_generation: Some(0),
            detached_session_status: DetachedSessionStatus {
                last_session_update_status: String::from("ready"),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    fn payload(name: &str) -> Value {
        serde_json::json!({"status": "ok", "source": "targets", "targets": [{"name": name}]})
    }

    #[test]
    fn authoritative_names_require_successful_evaluation() {
        assert_eq!(
            manifest_names(&payload("generated_north")).unwrap(),
            HashSet::from([String::from("generated_north")])
        );
        assert!(manifest_names(
            &serde_json::json!({"status": "ok", "source": "targets", "targets": []})
        )
        .unwrap()
        .is_empty());
        for invalid in [
            serde_json::json!({"status": "ok", "source": "static", "targets": [{"name": "template"}]}),
            serde_json::json!({"status": "error", "source": "targets", "targets": []}),
            serde_json::json!({"status": "ok", "source": "targets", "targets": [{}]}),
            serde_json::json!({"status": "ok", "source": "targets", "targets": [{"name": ""}]}),
        ] {
            assert!(
                manifest_names(&invalid).is_none(),
                "invalid payload: {invalid}"
            );
        }
    }

    #[test]
    fn manifests_are_project_scoped_and_reused_until_invalidated() {
        let mut state = state();
        let first = project(&mut state);
        let second = project(&mut state);
        let requests = prepare(&mut state);
        assert_eq!(requests.len(), 2);
        assert!(
            prepare(&mut state).is_empty(),
            "do not re-evaluate on every editor event"
        );
        let request = requests
            .into_iter()
            .find(|request| request.root == first.path())
            .unwrap();
        state.target_manifests.apply(ManifestResult {
            request,
            result: Ok(payload("generated_north")),
        });
        let first_uri = Url::from_file_path(first.path().join("report.R")).unwrap();
        let second_uri = Url::from_file_path(second.path().join("report.R")).unwrap();
        assert!(
            matches!(state.target_manifests.for_uri(&first_uri), TargetNames::Manifest(names) if names.contains("generated_north"))
        );
        assert!(matches!(
            state.target_manifests.for_uri(&second_uri),
            TargetNames::Unavailable
        ));
        assert!(prepare(&mut state).is_empty());
    }

    #[test]
    fn edits_invalidate_names_and_reject_stale_results_until_saved() {
        let mut state = state();
        let root = project(&mut state);
        let request = prepare(&mut state).pop().unwrap();
        let source = Url::from_file_path(root.path().join("_targets.R")).unwrap();
        let report = Url::from_file_path(root.path().join("report.R")).unwrap();
        state.target_manifests.apply(ManifestResult {
            request: request.clone(),
            result: Ok(payload("old_name")),
        });
        state
            .target_manifests
            .observe(&LspNotification::DidChangeTextDocument(
                tower_lsp::lsp_types::DidChangeTextDocumentParams {
                    text_document: tower_lsp::lsp_types::VersionedTextDocumentIdentifier::new(
                        source.clone(),
                        2,
                    ),
                    content_changes: vec![],
                },
            ));
        assert!(matches!(
            state.target_manifests.for_uri(&report),
            TargetNames::Unavailable
        ));
        assert!(
            prepare(&mut state).is_empty(),
            "disk manifest is not current while source buffer is dirty"
        );
        state.target_manifests.apply(ManifestResult {
            request,
            result: Ok(payload("stale_name")),
        });
        assert!(matches!(
            state.target_manifests.for_uri(&report),
            TargetNames::Unavailable
        ));
        state
            .target_manifests
            .observe(&LspNotification::DidSaveTextDocument(
                tower_lsp::lsp_types::DidSaveTextDocumentParams {
                    text_document: tower_lsp::lsp_types::TextDocumentIdentifier::new(source),
                    text: None,
                },
            ));
        let request = prepare(&mut state).pop().unwrap();
        state.target_manifests.apply(ManifestResult {
            request,
            result: Ok(payload("new_name")),
        });
        assert!(
            matches!(state.target_manifests.for_uri(&report), TargetNames::Manifest(names) if names == &HashSet::from([String::from("new_name")]))
        );
    }

    #[test]
    fn failures_and_session_changes_do_not_reuse_old_graph() {
        let mut state = state();
        let root = project(&mut state);
        let request = prepare(&mut state).pop().unwrap();
        let report = Url::from_file_path(root.path().join("report.R")).unwrap();
        state.target_manifests.apply(ManifestResult {
            request: request.clone(),
            result: Ok(payload("old_name")),
        });
        state.detached_session_update_generation = 1;
        state.detached_session_completed_generation = Some(1);
        let next = prepare(&mut state).pop().unwrap();
        state.target_manifests.apply(ManifestResult {
            request,
            result: Ok(payload("stale_name")),
        });
        assert!(matches!(
            state.target_manifests.for_uri(&report),
            TargetNames::Unavailable
        ));
        state.target_manifests.apply(ManifestResult {
            request: next,
            result: Err(anyhow::anyhow!("bridge unavailable")),
        });
        assert!(matches!(
            state.target_manifests.for_uri(&report),
            TargetNames::Unavailable
        ));
        assert!(
            prepare(&mut state).is_empty(),
            "failure must not trigger an automatic retry loop"
        );
    }

    #[test]
    fn closed_project_rejects_pending_result() {
        let mut state = state();
        let root = project(&mut state);
        let request = prepare(&mut state).pop().unwrap();
        state.documents.clear();
        assert!(prepare(&mut state).is_empty());
        state.target_manifests.apply(ManifestResult {
            request,
            result: Ok(payload("old_name")),
        });
        let report = Url::from_file_path(root.path().join("report.R")).unwrap();
        assert!(matches!(
            state.target_manifests.for_uri(&report),
            TargetNames::Static
        ));
    }

    #[test]
    fn watched_config_and_new_source_changes_refresh_only_their_project() {
        let mut state = state();
        let first = project(&mut state);
        let _second = project(&mut state);
        assert_eq!(prepare(&mut state).len(), 2);
        let config_path = first.path().join("_targets.yaml");
        std::fs::write(&config_path, "main:\n  script: custom_pipeline.R\n").unwrap();
        std::fs::write(first.path().join("custom_pipeline.R"), "list()\n").unwrap();
        for path in [config_path, first.path().join("new_helper.R")] {
            state
                .target_manifests
                .observe(&LspNotification::DidChangeWatchedFiles(
                    tower_lsp::lsp_types::DidChangeWatchedFilesParams {
                        changes: vec![tower_lsp::lsp_types::FileEvent {
                            uri: Url::from_file_path(path).unwrap(),
                            typ: tower_lsp::lsp_types::FileChangeType::CREATED,
                        }],
                    },
                ));
            let requests = prepare(&mut state);
            assert_eq!(requests.len(), 1);
            assert_eq!(requests[0].root, first.path());
            assert_eq!(requests[0].script, first.path().join("custom_pipeline.R"));
        }
    }
}
