//
// state_handlers.rs
//
// Copyright (C) 2024 Posit Software, PBC. All rights reserved.
//
//

use anyhow::anyhow;
use stdext::result::ResultExt;
use tower_lsp::lsp_types;
use tower_lsp::lsp_types::CompletionOptions;
use tower_lsp::lsp_types::CompletionOptionsCompletionItem;
use tower_lsp::lsp_types::CreateFilesParams;
use tower_lsp::lsp_types::DeleteFilesParams;
use tower_lsp::lsp_types::DidChangeConfigurationParams;
use tower_lsp::lsp_types::DidChangeTextDocumentParams;
use tower_lsp::lsp_types::DidCloseTextDocumentParams;
use tower_lsp::lsp_types::DidOpenTextDocumentParams;
use tower_lsp::lsp_types::DocumentOnTypeFormattingOptions;
use tower_lsp::lsp_types::ExecuteCommandOptions;
use tower_lsp::lsp_types::FileOperationFilter;
use tower_lsp::lsp_types::FileOperationPattern;
use tower_lsp::lsp_types::FileOperationPatternKind;
use tower_lsp::lsp_types::FileOperationRegistrationOptions;
use tower_lsp::lsp_types::FoldingRangeProviderCapability;
use tower_lsp::lsp_types::FormattingOptions;
use tower_lsp::lsp_types::HoverProviderCapability;
use tower_lsp::lsp_types::ImplementationProviderCapability;
use tower_lsp::lsp_types::InitializeParams;
use tower_lsp::lsp_types::InitializeResult;
use tower_lsp::lsp_types::OneOf;
use tower_lsp::lsp_types::RenameFilesParams;
use tower_lsp::lsp_types::SelectionRangeProviderCapability;
use tower_lsp::lsp_types::ServerCapabilities;
use tower_lsp::lsp_types::ServerInfo;
use tower_lsp::lsp_types::SignatureHelpOptions;
use tower_lsp::lsp_types::TextDocumentSyncCapability;
use tower_lsp::lsp_types::TextDocumentSyncKind;
use tower_lsp::lsp_types::WorkDoneProgressOptions;
use tower_lsp::lsp_types::WorkspaceFoldersServerCapabilities;
use tower_lsp::lsp_types::WorkspaceServerCapabilities;
use tracing::Instrument;
use tree_sitter::Parser;
use url::Url;

use crate::console::ConsoleNotification;
use crate::lsp;
use crate::lsp::backend::LspResult;
use crate::lsp::capabilities::Capabilities;
use crate::lsp::config::indent_style_from_lsp;
use crate::lsp::config::DOCUMENT_SETTINGS;
use crate::lsp::config::GLOBAL_SETTINGS;
use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;
use crate::lsp::handlers::SessionUpdateParams;
use crate::lsp::inputs::library::Library;
use crate::lsp::inputs::package::Package;
use crate::lsp::inputs::source_root::SourceRoot;
use crate::lsp::main_loop::DidCloseVirtualDocumentParams;
use crate::lsp::main_loop::DidOpenVirtualDocumentParams;
use crate::lsp::main_loop::LspState;
use crate::lsp::session_bridge::is_bridge_unavailable;
use crate::lsp::session_bridge::is_ipc_auth_error;
use crate::lsp::session_bridge::SessionBridge;
use crate::lsp::session_bridge::SessionBridgeConfig;
use crate::lsp::state::workspace_uris;
use crate::lsp::state::RuntimeMode;
use crate::lsp::state::WorldState;
use crate::url::UrlId;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

pub(crate) fn refresh_detached_session_inputs(state: &mut WorldState, force: bool) {
    if state.runtime_mode != RuntimeMode::Detached {
        return;
    }

    let now = now_ms();
    let bootstrap_incomplete = state.console_scopes.is_empty() || state.library.library_paths.is_empty();
    let retry_cooldown_elapsed = state
        .detached_session_status
        .last_bootstrap_attempt_ms
        .map(|last| now.saturating_sub(last) >= 500)
        .unwrap_or(true);
    let retry_failed_bootstrap = state.detached_session_bootstrap_attempted
        && state.detached_session_status.last_bootstrap_success_ms.is_none()
        && !state.detached_session_status.last_bootstrap_error.is_empty()
        && bootstrap_incomplete
        && retry_cooldown_elapsed;

    if !force && state.detached_session_bootstrap_attempted && !retry_failed_bootstrap {
        return;
    }

    state.detached_session_bootstrap_attempted = true;
    state.detached_session_status.last_bootstrap_attempt_ms = Some(now);
    state.detached_session_status.last_bootstrap_duration_ms = None;
    state.detached_session_status.last_bootstrap_search_path_symbols_ms = None;
    state.detached_session_status.last_bootstrap_library_paths_ms = None;

    let needs_bootstrap = force || bootstrap_incomplete;
    if !needs_bootstrap {
        return;
    }

    let Some(session_bridge) = state.session_bridge.as_ref() else {
        state.detached_session_status.last_bootstrap_error = String::from("session bridge missing");
        return;
    };

    tracing::info!(
        force,
        console_scope_count = state.console_scopes.len(),
        installed_package_count = state.installed_packages.len(),
        library_path_count = state.library.library_paths.len(),
        "Attempting detached session bootstrap refresh"
    );

    match session_bridge.bootstrap() {
        Ok(bootstrap) => {
            tracing::info!(
                search_path_symbols = bootstrap.search_path_symbols.len(),
                installed_packages = bootstrap.installed_packages.len(),
                library_paths = bootstrap.library_paths.len(),
                bootstrap_total_ms = bootstrap.timings.total_ms,
                bootstrap_search_path_symbols_ms = bootstrap.timings.search_path_symbols_ms,
                bootstrap_library_paths_ms = bootstrap.timings.library_paths_ms,
                "Rehydrated detached session inputs"
            );
            state.console_scopes = vec![bootstrap.search_path_symbols];
            state.installed_packages = bootstrap.installed_packages;
            state.library = Library::new(bootstrap.library_paths);
            state.detached_session_status.last_bootstrap_success_ms = Some(now_ms());
            state.detached_session_status.last_bootstrap_duration_ms = Some(bootstrap.timings.total_ms);
            state.detached_session_status.last_bootstrap_search_path_symbols_ms =
                Some(bootstrap.timings.search_path_symbols_ms);
            state.detached_session_status.last_bootstrap_library_paths_ms =
                Some(bootstrap.timings.library_paths_ms);
            state.detached_session_status.last_bootstrap_error.clear();
        },
        Err(err) => {
            state.detached_session_status.last_bootstrap_error = err.to_string();
            if is_ipc_auth_error(&err) {
                tracing::warn!("Detached session input refresh hit stale bridge auth: {err}");
            } else if is_bridge_unavailable(&err) {
                tracing::debug!("Detached session inputs not ready yet: {err}");
            } else {
                tracing::warn!("Detached session input refresh failed: {err:?}");
            }
        },
    }
}

fn session_bridge_from_update(
    params: &SessionUpdateParams,
) -> anyhow::Result<Option<SessionBridge>> {
    let Some(kind) = params.kind.as_deref().filter(|kind| !kind.is_empty()) else {
        return Ok(None);
    };

    if kind != "ark" && kind != "rscope" {
        return Err(anyhow!("unsupported session bridge kind: {kind}"));
    }

    let Some(status_file) = params.status_file.clone() else {
        return Ok(None);
    };

    SessionBridge::new(SessionBridgeConfig {
        host: String::new(),
        port: 0,
        auth_token: String::new(),
        status_file: Some(status_file),
        tmux_socket: params.tmux_socket.clone(),
        tmux_session: params.tmux_session.clone(),
        tmux_pane: params.tmux_pane.clone(),
        timeout_ms: params.timeout_ms.unwrap_or(1000),
    })
    .map(Some)
}

// Handlers that mutate the world state

/// Information sent from the kernel to the LSP after each top-level evaluation.
#[derive(Debug)]
pub struct ConsoleInputs {
    /// List of console scopes, from innermost (global or debug) to outermost
    /// scope. Currently the scopes are vectors of symbol names. TODO: In the
    /// future, we should send structural information like search path, and let
    /// the LSP query us for the contents so that the LSP can cache the
    /// information.
    pub console_scopes: Vec<Vec<String>>,

    /// Packages currently installed in the library path. TODO: Should send
    /// library paths instead and inspect and cache package information in the LSP.
    pub installed_packages: Vec<String>,
}

// Handlers taking exclusive references to global state

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn initialize(
    params: InitializeParams,
    lsp_state: &mut LspState,
    state: &mut WorldState,
) -> LspResult<InitializeResult> {
    lsp_state.capabilities = Capabilities::new(params.capabilities);

    // Initialize the workspace folders
    let mut folders: Vec<String> = Vec::new();
    if let Some(workspace_folders) = params.workspace_folders {
        for folder in workspace_folders.iter() {
            state.workspace.folders.push(folder.uri.clone());
            if let Ok(path) = folder.uri.to_file_path() {
                // Try to load package from this workspace folder and set as
                // root if found. This means we're dealing with a package
                // source.
                if state.root.is_none() {
                    match Package::load_from_folder(&path) {
                        Ok(Some(pkg)) => {
                            log::info!(
                                "Root: Loaded package `{pkg}` from {path} as project root",
                                pkg = pkg.description.name,
                                path = path.display()
                            );
                            state.root = Some(SourceRoot::Package(pkg));
                        },
                        Ok(None) => {
                            log::info!(
                                "Root: No package found at {path}, treating as folder of scripts",
                                path = path.display()
                            );
                        },
                        Err(err) => {
                            log::warn!(
                                "Root: Error loading package at {path}: {err}",
                                path = path.display()
                            );
                        },
                    }
                }
                if let Some(path_str) = path.to_str() {
                    folders.push(path_str.to_string());
                }
            }
        }
    }

    // Start first round of indexing
    lsp::main_loop::index_start(folders, state.clone());

    Ok(InitializeResult {
        server_info: Some(ServerInfo {
            name: "Ark R Kernel".to_string(),
            version: Some(env!("CARGO_PKG_VERSION").to_string()),
        }),
        capabilities: ServerCapabilities {
            // Currently hard-coded to UTF-16, but we might want to allow UTF-8 frontends
            // once/if Ark becomes an independent LSP
            position_encoding: Some(lsp_types::PositionEncodingKind::UTF16),
            text_document_sync: Some(TextDocumentSyncCapability::Kind(
                TextDocumentSyncKind::INCREMENTAL,
            )),
            selection_range_provider: Some(SelectionRangeProviderCapability::Simple(true)),
            hover_provider: Some(HoverProviderCapability::from(true)),
            completion_provider: Some(CompletionOptions {
                resolve_provider: Some(true),
                trigger_characters: Some(vec![
                    "$".to_string(),
                    "@".to_string(),
                    ":".to_string(),
                    "(".to_string(),
                    "[".to_string(),
                    ",".to_string(),
                    " ".to_string(),
                    "\"".to_string(),
                ]),
                work_done_progress_options: Default::default(),
                all_commit_characters: None,
                completion_item: Some(CompletionOptionsCompletionItem {
                    label_details_support: Some(true),
                }),
            }),
            signature_help_provider: Some(SignatureHelpOptions {
                trigger_characters: Some(vec!["(".to_string(), ",".to_string(), "=".to_string()]),
                retrigger_characters: None,
                work_done_progress_options: WorkDoneProgressOptions {
                    work_done_progress: None,
                },
            }),
            definition_provider: Some(OneOf::Left(true)),
            type_definition_provider: None,
            implementation_provider: Some(ImplementationProviderCapability::Simple(true)),
            references_provider: Some(OneOf::Left(true)),
            document_symbol_provider: Some(OneOf::Left(true)),
            folding_range_provider: Some(FoldingRangeProviderCapability::Simple(true)),
            workspace_symbol_provider: Some(OneOf::Left(true)),
            execute_command_provider: Some(ExecuteCommandOptions {
                commands: vec![],
                work_done_progress_options: Default::default(),
            }),
            code_action_provider: lsp_state.capabilities.code_action_provider_capability(),
            workspace: Some(WorkspaceServerCapabilities {
                workspace_folders: Some(WorkspaceFoldersServerCapabilities {
                    supported: Some(true),
                    change_notifications: Some(OneOf::Left(true)),
                }),
                file_operations: {
                    let r_file_filter = FileOperationFilter {
                        scheme: Some(String::from("file")),
                        pattern: FileOperationPattern {
                            glob: String::from("**/*.{r,R}"),
                            matches: Some(FileOperationPatternKind::File),
                            options: None,
                        },
                    };
                    Some(lsp_types::WorkspaceFileOperationsServerCapabilities {
                        did_create: Some(FileOperationRegistrationOptions {
                            filters: vec![r_file_filter.clone()],
                        }),
                        did_delete: Some(FileOperationRegistrationOptions {
                            filters: vec![r_file_filter.clone()],
                        }),
                        did_rename: Some(FileOperationRegistrationOptions {
                            filters: vec![r_file_filter],
                        }),
                        ..Default::default()
                    })
                },
            }),
            document_on_type_formatting_provider: Some(DocumentOnTypeFormattingOptions {
                first_trigger_character: String::from("\n"),
                more_trigger_character: None,
            }),
            ..ServerCapabilities::default()
        },
    })
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_open(
    params: DidOpenTextDocumentParams,
    lsp_state: &mut LspState,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    let contents = params.text_document.text.as_str();
    let uri = params.text_document.uri;
    let version = params.text_document.version;

    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_r::LANGUAGE.into())
        .unwrap();

    let kind = DocumentKind::from_language_id(params.text_document.language_id.as_str());
    let document = Document::new_with_parser_and_kind(contents, &mut parser, Some(version), kind);

    lsp_state.parsers.insert(uri.clone(), parser);
    state.documents.insert(uri.clone(), document.clone());

    // NOTE: Do we need to call `update_config()` here?
    // update_config(vec![uri]).await;
    refresh_detached_session_inputs(state, false);

    lsp::main_loop::diagnostics_refresh_all_from_state(state);

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_change(
    params: DidChangeTextDocumentParams,
    lsp_state: &mut LspState,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    let uri = &params.text_document.uri;
    let document = state.get_document_mut(uri)?;

    let parser = lsp_state
        .parsers
        .get_mut(uri)
        .ok_or(anyhow!("No parser for {uri}"))?;

    document.on_did_change(parser, &params);
    refresh_detached_session_inputs(state, false);
    lsp::main_loop::index_update(vec![uri.clone()], state.clone());
    lsp::main_loop::diagnostics_refresh_all_from_state(state);

    // Notify console about document change to invalidate breakpoints.
    lsp_state
        .console_notification_tx
        .send(ConsoleNotification::DidChangeDocument(UrlId::from_url(
            uri.clone(),
        )))
        .log_err();

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_close(
    params: DidCloseTextDocumentParams,
    lsp_state: &mut LspState,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    let uri = params.text_document.uri;

    // Publish empty set of diagnostics to clear them
    lsp::publish_diagnostics(uri.clone(), Vec::new(), None);

    state
        .documents
        .remove(&uri)
        .ok_or(anyhow!("Failed to remove document for URI: {uri}"))?;

    lsp_state
        .parsers
        .remove(&uri)
        .ok_or(anyhow!("Failed to remove parser for URI: {uri}"))?;

    lsp::log_info!("did_close(): closed document with URI: '{uri}'.");

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_create_files(
    params: CreateFilesParams,
    state: &WorldState,
) -> anyhow::Result<()> {
    let uris = params
        .files
        .iter()
        .filter_map(|file| parse_uri_or_none(&file.uri))
        .collect();

    lsp::main_loop::index_create(uris, state.clone());

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_delete_files(
    params: DeleteFilesParams,
    state: &WorldState,
) -> anyhow::Result<()> {
    let uris = params
        .files
        .iter()
        .filter_map(|file| parse_uri_or_none(&file.uri))
        .collect();

    lsp::main_loop::index_delete(uris, state.clone());

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_rename_files(
    params: RenameFilesParams,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    let uri_pairs = params
        .files
        .iter()
        .filter_map(|file| {
            let old_url = parse_uri_or_none(&file.old_uri)?;
            let new_url = parse_uri_or_none(&file.new_uri)?;
            Some((old_url, new_url))
        })
        .collect();

    lsp::main_loop::index_rename(uri_pairs, state.clone());
    Ok(())
}

fn parse_uri_or_none(uri: &str) -> Option<url::Url> {
    match url::Url::parse(uri) {
        Ok(url) => Some(url),
        Err(err) => {
            log::warn!("Failed to parse URI '{uri}': {err}");
            None
        },
    }
}

pub(crate) async fn did_change_configuration(
    _params: DidChangeConfigurationParams,
    client: &tower_lsp::Client,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    // The notification params sometimes contain data but it seems in practice
    // we should just ignore it. Instead we need to pull the settings again for
    // all URI of interest.

    // Note that the client sends notifications for settings for which we have
    // declared interest in. This registration is done in `handle_initialized()`.

    update_config(workspace_uris(state), client, state)
        .instrument(tracing::info_span!("did_change_configuration"))
        .await
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_update_session(
    params: SessionUpdateParams,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    if state.runtime_mode != RuntimeMode::Detached {
        return Ok(());
    }

    tracing::info!(
        status = params.status,
        repl_ready = params.repl_ready,
        tmux_socket = params.tmux_socket,
        tmux_session = params.tmux_session,
        tmux_pane = params.tmux_pane,
        "Received detached session update"
    );

    state.detached_session_status.last_session_update_ms = Some(now_ms());
    state.detached_session_status.last_session_update_status = params.status.clone();
    state.detached_session_status.last_session_update_repl_ready = params.repl_ready;
    state.session_bridge = session_bridge_from_update(&params)?;
    state.detached_session_bootstrap_attempted = false;

    if params.status == "ready" && state.session_bridge.is_some() {
        refresh_detached_session_inputs(state, true);
    }

    lsp::diagnostics_refresh_all(state);

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_change_formatting_options(
    uri: &Url,
    opts: &FormattingOptions,
    state: &mut WorldState,
) {
    let Ok(doc) = state.get_document_mut(uri) else {
        return;
    };

    // The information provided in formatting requests is more up-to-date
    // than the user settings because it also includes changes made to the
    // configuration of particular editors. However the former is less rich
    // than the latter: it does not allow the tab size to differ from the
    // indent size, as in the R core sources. So we just ignore the less
    // rich updates in this case.
    if doc.config.indent.indent_size != doc.config.indent.tab_width {
        return;
    }

    doc.config.indent.indent_size = opts.tab_size as usize;
    doc.config.indent.tab_width = opts.tab_size as usize;
    doc.config.indent.indent_style = indent_style_from_lsp(opts.insert_spaces);

    // TODO:
    // `trim_trailing_whitespace`
    // `trim_final_newlines`
    // `insert_final_newline`
}

async fn update_config(
    uris: Vec<Url>,
    client: &tower_lsp::Client,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    // Keep track of existing config to detect whether it was changed
    let diagnostics_config = state.config.diagnostics.clone();

    // Build the configuration request for global and document settings
    let mut items: Vec<_> = vec![];

    // This should be first because we first handle the global settings below,
    // splitting them off the response array
    let mut global_items: Vec<_> = GLOBAL_SETTINGS
        .iter()
        .map(|mapping| lsp_types::ConfigurationItem {
            scope_uri: None,
            section: Some(mapping.key.to_string()),
        })
        .collect();

    // For document items we create a n_uris * n_document_settings array that we'll
    // handle by batch in a double loop over URIs and document settings
    let mut document_items: Vec<_> = uris
        .iter()
        .flat_map(|uri| {
            DOCUMENT_SETTINGS
                .iter()
                .map(|mapping| lsp_types::ConfigurationItem {
                    scope_uri: Some(uri.clone()),
                    section: Some(mapping.key.to_string()),
                })
        })
        .collect();

    // Concatenate everything into a flat array that we'll send in one request
    items.append(&mut global_items);
    items.append(&mut document_items);

    // The response better match the number of items we send in
    let n_items = items.len();

    let mut configs = client.configuration(items).await?;

    if configs.len() != n_items {
        return Err(anyhow!(
            "Unexpected number of retrieved configurations: {}/{}",
            configs.len(),
            n_items
        ));
    }

    let document_configs = configs.split_off(GLOBAL_SETTINGS.len());
    let global_configs = configs;

    for (mapping, value) in GLOBAL_SETTINGS.iter().zip(global_configs) {
        (mapping.set)(&mut state.config, value);
    }

    let mut remaining = document_configs;

    for uri in uris.into_iter() {
        // Need to juggle a bit because `split_off()` returns the tail of the
        // split and updates the vector with the head
        let tail = remaining.split_off(DOCUMENT_SETTINGS.len());
        let head = std::mem::replace(&mut remaining, tail);

        for (mapping, value) in DOCUMENT_SETTINGS.iter().zip(head) {
            if let Ok(doc) = state.get_document_mut(&uri) {
                (mapping.set)(&mut doc.config, value);
            }
        }
    }

    // Refresh diagnostics if the configuration changed
    if state.config.diagnostics != diagnostics_config {
        tracing::info!("Refreshing diagnostics after configuration changed");
        lsp::main_loop::diagnostics_refresh_all_from_state(state);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::io::Write;
    use std::net::TcpListener;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::thread;
    fn spawn_bootstrap_bridge(auth_token: &str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let auth_token = auth_token.to_string();

        thread::spawn(move || {
            for expected in ["search_path", "installed_packages", "library_paths"] {
                let (mut stream, _) = listener.accept().expect("expected bridge request");
                let mut request = String::new();
                stream
                    .read_to_string(&mut request)
                    .expect("expected bridge request payload");
                assert!(!request.is_empty(), "expected bridge request body");

                let payload: serde_json::Value =
                    serde_json::from_str(request.trim()).expect("expected json request");
                assert_eq!(
                    payload
                        .get("auth_token")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default(),
                    auth_token
                );

                let command = payload
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let expr = payload
                    .get("expr")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();

                let response = match expected {
                    "search_path" => {
                        assert_eq!(command, "bootstrap");
                        r#"{"status":"ok","search_path_symbols":["library","mtcars"],"library_paths":["/tmp/ark-test-library"]}"#
                    },
                    "installed_packages" => {
                        assert!(expr.contains(".packages(all.available = TRUE)"));
                        r#"{"members":[{"name_raw":"ggplot2"},{"name_raw":"utils"}]}"#
                    },
                    "library_paths" => {
                        assert!(expr.contains(".libPaths()"));
                        r#"{"members":[{"name_raw":"/tmp/ark-test-library"}]}"#
                    },
                    _ => unreachable!(),
                };

                stream
                    .write_all(response.as_bytes())
                    .expect("expected bridge response");
            }
        });

        port
    }

    fn spawn_counting_bridge(count: Arc<AtomicUsize>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();

        thread::spawn(move || {
            while let Ok((mut stream, _)) = listener.accept() {
                count.fetch_add(1, Ordering::SeqCst);
                let mut request = String::new();
                let _ = stream.read_to_string(&mut request);
                let _ = stream.write_all(
                    br#"{"status":"ok","search_path_symbols":["library"],"library_paths":["/tmp/ark-test-library"]}"#,
                );
            }
        });

        port
    }

    #[test]
    fn test_detached_session_update_bootstraps_console_scopes_when_bridge_is_ready() {
        let auth_token = "ark-test-token";
        let port = spawn_bootstrap_bridge(auth_token);
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            format!(
                r#"{{"status":"ready","port":{},"auth_token":"{}","repl_ready":true}}"#,
                port, auth_token
            ),
        )
        .expect("expected status file");

        let mut state = WorldState::detached();

        did_update_session(
            SessionUpdateParams {
                kind: Some(String::from("ark")),
                status_file: Some(status.path().to_path_buf()),
                tmux_socket: String::from("/tmp/ark-test.sock"),
                tmux_session: String::from("ark-test"),
                tmux_pane: String::from("%1"),
                timeout_ms: Some(1000),
                status: String::from("ready"),
                repl_ready: false,
            },
            &mut state,
        )
        .expect("expected session update to succeed");

        assert_eq!(
            state.console_scopes,
            vec![vec![String::from("library"), String::from("mtcars")]]
        );
        assert_eq!(
            state.installed_packages,
            Vec::<String>::new()
        );
        assert_eq!(state.library.library_paths.len(), 1);
        assert_eq!(
            state.library.library_paths[0],
            std::path::PathBuf::from("/tmp/ark-test-library")
        );
    }

    #[test]
    fn test_detached_nonforced_refresh_only_probes_bridge_once() {
        let bridge_hits = Arc::new(AtomicUsize::new(0));
        let port = spawn_counting_bridge(bridge_hits.clone());
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            format!(
                r#"{{"status":"ready","port":{},"auth_token":"test-token","repl_ready":true}}"#,
                port
            ),
        )
        .expect("expected status file");

        let mut state = WorldState {
            runtime_mode: crate::lsp::state::RuntimeMode::Detached,
            session_bridge: Some(
                SessionBridge::new(SessionBridgeConfig {
                    host: String::new(),
                    port: 0,
                    auth_token: String::new(),
                    status_file: Some(status.path().to_path_buf()),
                    tmux_socket: String::from("/tmp/ark-test.sock"),
                    tmux_session: String::from("ark-test"),
                    tmux_pane: String::from("%1"),
                    timeout_ms: 50,
                })
                .expect("expected bridge"),
            ),
            ..Default::default()
        };
        refresh_detached_session_inputs(&mut state, false);
        refresh_detached_session_inputs(&mut state, false);

        assert_eq!(
            bridge_hits.load(Ordering::SeqCst),
            1,
            "non-forced detached refresh should only run one bridge probe cycle"
        );
    }
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_change_console_inputs(
    inputs: ConsoleInputs,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    state.console_scopes = inputs.console_scopes;
    state.installed_packages = inputs.installed_packages;

    // We currently rely on global console scopes for diagnostics, in particular
    // during package development in conjunction with `devtools::load_all()`.
    // Ideally diagnostics would not rely on these though, and we wouldn't need
    // to refresh from here.
    lsp::diagnostics_refresh_all(state);

    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_open_virtual_document(
    params: DidOpenVirtualDocumentParams,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    // Insert new document, replacing any old one
    state.virtual_documents.insert(params.uri, params.contents);
    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn did_close_virtual_document(
    params: DidCloseVirtualDocumentParams,
    state: &mut WorldState,
) -> anyhow::Result<()> {
    state.virtual_documents.remove(&params.uri);
    Ok(())
}
