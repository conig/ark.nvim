//
// handlers.rs
//
// Copyright (C) 2024-2026 Posit Software, PBC. All rights reserved.
//
//

use anyhow::anyhow;
use serde_json::Value;
use std::path::PathBuf;
use stdext::result::ResultExt;
use stdext::unwrap;
use tower_lsp::lsp_types::CodeActionParams;
use tower_lsp::lsp_types::CodeActionResponse;
use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionParams;
use tower_lsp::lsp_types::CompletionResponse;
use tower_lsp::lsp_types::CompletionTriggerKind;
use tower_lsp::lsp_types::DocumentOnTypeFormattingParams;
use tower_lsp::lsp_types::DocumentSymbolParams;
use tower_lsp::lsp_types::DocumentSymbolResponse;
use tower_lsp::lsp_types::FoldingRange;
use tower_lsp::lsp_types::FoldingRangeParams;
use tower_lsp::lsp_types::GotoDefinitionParams;
use tower_lsp::lsp_types::GotoDefinitionResponse;
use tower_lsp::lsp_types::Hover;
use tower_lsp::lsp_types::HoverContents;
use tower_lsp::lsp_types::HoverParams;
use tower_lsp::lsp_types::Location;
use tower_lsp::lsp_types::MessageType;
use tower_lsp::lsp_types::ReferenceParams;
use tower_lsp::lsp_types::Registration;
use tower_lsp::lsp_types::SelectionRange;
use tower_lsp::lsp_types::SelectionRangeParams;
use tower_lsp::lsp_types::SignatureHelp;
use tower_lsp::lsp_types::SignatureHelpParams;
use tower_lsp::lsp_types::SymbolInformation;
use tower_lsp::lsp_types::TextEdit;
use tower_lsp::lsp_types::WorkspaceEdit;
use tower_lsp::lsp_types::WorkspaceSymbolParams;
use tower_lsp::Client;
use tracing::Instrument;

use crate::analysis::input_boundaries::input_boundaries;
use crate::lsp;
use crate::lsp::backend::LspError;
use crate::lsp::backend::LspResult;
use crate::lsp::code_action::code_actions;
use crate::lsp::completions::dedupe_and_sort_completion_items;
use crate::lsp::completions::provide_completions;
use crate::lsp::completions::provide_detached_post_bridge_completions;
use crate::lsp::completions::provide_detached_pre_bridge_completions;
use crate::lsp::completions::provide_detached_static_completions;
use crate::lsp::completions::resolve_completion;
use crate::lsp::definitions::goto_definition;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::folding_range::folding_range;
use crate::lsp::help_topic::help_topic;
use crate::lsp::help_topic::HelpTopicParams;
use crate::lsp::help_topic::HelpTopicResponse;
use crate::lsp::hover::r_hover;
use crate::lsp::indent::indent_edit;
use crate::lsp::input_boundaries::InputBoundariesParams;
use crate::lsp::input_boundaries::InputBoundariesResponse;
use crate::lsp::main_loop::LspState;
use crate::lsp::references::find_references;
use crate::lsp::selection_range::convert_selection_range_from_tree_sitter_to_lsp;
use crate::lsp::selection_range::selection_range;
use crate::lsp::session_bridge::is_bridge_unavailable;
use crate::lsp::session_bridge::is_eval_missing_object_error;
use crate::lsp::session_bridge::is_ipc_auth_error;
use crate::lsp::signature_help::r_signature_help;
use crate::lsp::state::WorldState;
use crate::lsp::statement_range::statement_range;
use crate::lsp::statement_range::StatementRangeParams;
use crate::lsp::statement_range::StatementRangeResponse;
use crate::lsp::symbols;
use crate::r_task;

pub static ARK_VDOC_REQUEST: &str = "ark/internal/virtualDocument";
pub static ARK_STATUS_REQUEST: &str = "ark/internal/status";
pub static ARK_SESSION_UPDATE_NOTIFICATION: &str = "ark/updateSession";

#[derive(Debug, Eq, PartialEq, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct VirtualDocumentParams {
    pub path: String,
}

pub(crate) type VirtualDocumentResponse = String;

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct StatusParams {}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionUpdateParams {
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub status_file: Option<PathBuf>,
    #[serde(default)]
    pub tmux_socket: String,
    #[serde(default)]
    pub tmux_session: String,
    #[serde(default)]
    pub tmux_pane: String,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub repl_ready: bool,
}

fn log_detached_bridge_auth_fallback(feature: &str, err: &anyhow::Error) {
    log::warn!(
        "Detached {feature} hit stale bridge auth; falling back until ark_lsp refreshes: {err}"
    );
}

fn runtime_required<T>(state: &WorldState) -> LspResult<Option<T>> {
    if state.has_attached_runtime() {
        return Err(LspError::Anyhow(anyhow!(
            "runtime_required() should only be used for detached LSP state"
        )));
    }

    Ok(None)
}

// Handlers that do not mutate the world state. They take a sharing reference or
// a clone of the state.

pub(crate) async fn handle_initialized(
    client: &Client,
    lsp_state: &LspState,
) -> anyhow::Result<()> {
    let span = tracing::info_span!("handle_initialized").entered();

    // Register capabilities to the client
    let mut regs: Vec<Registration> = vec![];

    if lsp_state
        .capabilities
        .dynamic_registration_for_did_change_configuration()
    {
        // The `didChangeConfiguration` request instructs the client to send
        // a notification when the tracked settings have changed.
        //
        // Note that some settings, such as editor indentation properties, may be
        // changed by extensions or by the user without changing the actual
        // underlying setting. Unfortunately we don't receive updates in that case.

        for setting in crate::lsp::config::GLOBAL_SETTINGS {
            for key in setting.keys {
                regs.push(Registration {
                    id: uuid::Uuid::new_v4().to_string(),
                    method: String::from("workspace/didChangeConfiguration"),
                    register_options: Some(serde_json::json!({ "section": key })),
                });
            }
        }
        for setting in crate::lsp::config::DOCUMENT_SETTINGS {
            for key in setting.keys {
                regs.push(Registration {
                    id: uuid::Uuid::new_v4().to_string(),
                    method: String::from("workspace/didChangeConfiguration"),
                    register_options: Some(serde_json::json!({ "section": key })),
                });
            }
        }
    }

    client
        .register_capability(regs)
        .instrument(span.exit())
        .await?;
    Ok(())
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_symbol(
    params: WorkspaceSymbolParams,
    state: &WorldState,
) -> LspResult<Option<Vec<SymbolInformation>>> {
    symbols::symbols(&params, state).map(Some).or_else(|err| {
        // Missing doc: Why are we not propagating errors to the frontend?
        lsp::log_error!("{err:?}");
        Ok(None)
    })
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_document_symbol(
    params: DocumentSymbolParams,
    state: &WorldState,
) -> LspResult<Option<DocumentSymbolResponse>> {
    symbols::document_symbols(state, &params)
        .map(|res| Some(DocumentSymbolResponse::Nested(res)))
        .or_else(|err| {
            // Missing doc: Why are we not propagating errors to the frontend?
            lsp::log_error!("{err:?}");
            Ok(None)
        })
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_folding_range(
    params: FoldingRangeParams,
    state: &WorldState,
) -> LspResult<Option<Vec<FoldingRange>>> {
    let uri = &params.text_document.uri;
    let document = state.get_document(uri)?;
    match folding_range(document) {
        Ok(foldings) => Ok(Some(foldings)),
        Err(err) => {
            lsp::log_error!("{err:?}");
            Ok(None)
        },
    }
}

pub(crate) async fn handle_execute_command(client: &Client) -> LspResult<Option<Value>> {
    match client.apply_edit(WorkspaceEdit::default()).await {
        Ok(res) if res.applied => client.log_message(MessageType::INFO, "applied").await,
        Ok(_) => client.log_message(MessageType::INFO, "rejected").await,
        Err(err) => client.log_message(MessageType::ERROR, err).await,
    }
    Ok(None)
}

pub(crate) fn handle_status(_params: StatusParams, state: &WorldState) -> LspResult<Value> {
    serde_json::to_value(state.detached_status_snapshot()).map_err(|err| LspError::Anyhow(err.into()))
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_completion(
    params: CompletionParams,
    state: &WorldState,
) -> LspResult<Option<CompletionResponse>> {
    let uri = params.text_document_position.text_document.uri;
    let document = state.get_document(&uri)?;

    let position = params.text_document_position.position;
    let point = document.tree_sitter_point_from_lsp_position(position)?;

    let trigger = params
        .context
        .as_ref()
        .and_then(|ctxt| ctxt.trigger_character.clone());
    let explicit_completion_request = params
        .context
        .as_ref()
        .map(|ctxt| ctxt.trigger_kind == CompletionTriggerKind::INVOKED)
        .unwrap_or(false);

    // Build the document context.
    let context =
        DocumentContext::new_with_completion(document, point, trigger, explicit_completion_request);
    lsp::log_info!("Completion context: {:#?}", context);

    if !state.has_attached_runtime() {
        if let Some(completions) =
            provide_detached_pre_bridge_completions(&context, state).map_err(LspError::Anyhow)?
        {
            return Ok(completion_response_from_items(completions));
        }

        if let Some(session_bridge) = state.session_bridge.as_ref() {
            let detached = match session_bridge.completion_items(&context) {
                Ok(detached) => detached,
                Err(err) => {
                    if is_bridge_unavailable(&err) || is_eval_missing_object_error(&err) {
                        None
                    } else if is_ipc_auth_error(&err) {
                        log_detached_bridge_auth_fallback("completion", &err);
                        None
                    } else {
                        return Err(LspError::Anyhow(err));
                    }
                },
            };

            if detached.is_none() {
                if let Some(completions) = provide_detached_post_bridge_completions(&context, state)
                    .map_err(LspError::Anyhow)?
                {
                    return Ok(completion_response_from_items(completions));
                }
            }

            let detached = detached.unwrap_or_default();
            if !detached.merge_static || !detached.items.is_empty() {
                return Ok(completion_response_from_items(detached.items));
            }

            let static_items =
                provide_detached_static_completions(&context, state).map_err(LspError::Anyhow)?;
            let items =
                dedupe_and_sort_completion_items(detached.items.into_iter().chain(static_items));

            return Ok(completion_response_from_items(items));
        }
        return runtime_required(state);
    }

    let completions = r_task(|| provide_completions(&context, state))?;

    if !completions.is_empty() {
        Ok(Some(CompletionResponse::Array(completions)))
    } else {
        Ok(None)
    }
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_completion_resolve(
    mut item: CompletionItem,
    state: &WorldState,
) -> LspResult<CompletionItem> {
    if !state.has_attached_runtime() {
        if let Some(session_bridge) = state.session_bridge.as_ref() {
            let unresolved = item.clone();
            return match session_bridge.resolve_completion_item(item) {
                Ok(item) => Ok(item),
                Err(err) => {
                    if is_bridge_unavailable(&err) || is_eval_missing_object_error(&err) {
                        Ok(unresolved)
                    } else if is_ipc_auth_error(&err) {
                        log_detached_bridge_auth_fallback("completion resolve", &err);
                        Ok(unresolved)
                    } else {
                        Err(LspError::Anyhow(err))
                    }
                },
            };
        }
        return Ok(item);
    }

    if !crate::console::Console::is_initialized() {
        return Ok(item);
    }

    r_task(|| resolve_completion(&mut item))?;
    Ok(item)
}

fn completion_response_from_items(items: Vec<CompletionItem>) -> Option<CompletionResponse> {
    if items.is_empty() {
        None
    } else {
        Some(CompletionResponse::Array(items))
    }
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_hover(params: HoverParams, state: &WorldState) -> LspResult<Option<Hover>> {
    let uri = params.text_document_position_params.text_document.uri;
    let document = state.get_document(&uri)?;

    let position = params.text_document_position_params.position;
    let point = document.tree_sitter_point_from_lsp_position(position)?;

    // build document context
    let context = DocumentContext::new(document, point, None);

    if !state.has_attached_runtime() {
        if let Some(session_bridge) = state.session_bridge.as_ref() {
            return match session_bridge.hover(&context) {
                Ok(result) => Ok(result),
                Err(err) => {
                    if is_bridge_unavailable(&err) || is_eval_missing_object_error(&err) {
                        Ok(None)
                    } else if is_ipc_auth_error(&err) {
                        log_detached_bridge_auth_fallback("hover", &err);
                        Ok(None)
                    } else {
                        Err(LspError::Anyhow(err))
                    }
                },
            };
        }
        return runtime_required(state);
    }

    // request hover information
    let result = r_task(|| r_hover(&context));

    // unwrap errors
    let result = unwrap!(result, Err(err) => {
        lsp::log_error!("{err:?}");
        return Ok(None);
    });

    // unwrap empty options
    let result = unwrap!(result, None => {
        return Ok(None);
    });

    // we got a result; use it
    Ok(Some(Hover {
        contents: HoverContents::Markup(result),
        range: None,
    }))
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_signature_help(
    params: SignatureHelpParams,
    state: &WorldState,
) -> LspResult<Option<SignatureHelp>> {
    let uri = params.text_document_position_params.text_document.uri;
    let document = state.get_document(&uri)?;

    let position = params.text_document_position_params.position;
    let point = document.tree_sitter_point_from_lsp_position(position)?;

    let context = DocumentContext::new(document, point, None);

    if !state.has_attached_runtime() {
        if let Some(session_bridge) = state.session_bridge.as_ref() {
            return match session_bridge.signature_help(&context) {
                Ok(result) => Ok(result),
                Err(err) => {
                    if is_bridge_unavailable(&err) || is_eval_missing_object_error(&err) {
                        Ok(None)
                    } else if is_ipc_auth_error(&err) {
                        log_detached_bridge_auth_fallback("signature help", &err);
                        Ok(None)
                    } else {
                        Err(LspError::Anyhow(err))
                    }
                },
            };
        }
        return runtime_required(state);
    }

    // request signature help
    let result = r_task(|| r_signature_help(&context));

    // unwrap errors
    let result = unwrap!(result, Err(err) => {
        lsp::log_error!("{err:?}");
        return Ok(None);
    });

    // unwrap empty options
    let result = unwrap!(result, None => {
        return Ok(None);
    });

    Ok(Some(result))
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_goto_definition(
    params: GotoDefinitionParams,
    state: &WorldState,
) -> LspResult<Option<GotoDefinitionResponse>> {
    let uri = &params.text_document_position_params.text_document.uri;
    let document = state.get_document(uri)?;
    Ok(goto_definition(document, params).log_err().flatten())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Read;
    use std::io::Write;
    use std::net::TcpListener;
    use std::path::PathBuf;
    use std::thread;
    use tempfile::tempdir;
    use tower_lsp::lsp_types::Position;
    use tower_lsp::lsp_types::TextDocumentIdentifier;
    use tower_lsp::lsp_types::TextDocumentPositionParams;
    use tower_lsp::lsp_types::WorkDoneProgressParams;
    use url::Url;

    use crate::lsp::document::Document;
    use crate::lsp::session_bridge::SessionBridge;
    use crate::lsp::session_bridge::SessionBridgeConfig;
    use crate::lsp::state::RuntimeMode;

    fn auth_error_bridge() -> SessionBridge {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();

        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected bridge request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected bridge request payload");
            assert!(!request.is_empty(), "expected bridge request body");
            stream
                .write_all(br#"{"error":{"code":"E_IPC_AUTH","message":"invalid IPC auth token"}}"#)
                .expect("expected bridge error response");
        });

        SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("stale-token"),
            status_file: None,
            tmux_socket: String::from("/tmp/ark-test.sock"),
            tmux_session: String::from("ark-test"),
            tmux_pane: String::from("%1"),
            timeout_ms: 1000,
        })
        .expect("expected session bridge")
    }

    fn eval_error_bridge(message: &str) -> SessionBridge {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let message = message.to_string();

        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected bridge request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected bridge request payload");
            assert!(!request.is_empty(), "expected bridge request body");
            stream
                .write_all(
                    format!(r#"{{"error":{{"code":"E_EVAL","message":"{}"}}}}"#, message).as_bytes(),
                )
                .expect("expected bridge error response");
        });

        SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("test-token"),
            status_file: None,
            tmux_socket: String::from("/tmp/ark-test.sock"),
            tmux_session: String::from("ark-test"),
            tmux_pane: String::from("%1"),
            timeout_ms: 1000,
        })
        .expect("expected session bridge")
    }

    fn unavailable_status_file_bridge() -> SessionBridge {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        drop(listener);

        let tempdir = tempdir().expect("expected tempdir");
        let status_file: PathBuf = tempdir.path().join("status.json");
        fs::write(
            &status_file,
            format!(
                r#"{{"status":"ready","port":{port},"auth_token":"test-token","repl_ready":true}}"#
            ),
        )
        .expect("expected status file");

        // Leak the tempdir so the status file survives for the duration of the test.
        let _ = Box::leak(Box::new(tempdir));

        SessionBridge::new(SessionBridgeConfig {
            host: String::new(),
            port: 0,
            auth_token: String::new(),
            status_file: Some(status_file),
            tmux_socket: String::from("/tmp/ark-test.sock"),
            tmux_session: String::from("ark-test"),
            tmux_pane: String::from("%1"),
            timeout_ms: 100,
        })
        .expect("expected session bridge")
    }

    #[test]
    fn test_detached_hover_auth_mismatch_degrades_to_none() {
        let uri = Url::parse("file:///tmp/ark_hover_auth_fallback.R").expect("expected uri");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(auth_error_bridge()),
            ..Default::default()
        };
        state
            .documents
            .insert(uri.clone(), Document::new("mean", Some(1)));

        let result = handle_hover(
            HoverParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri },
                    position: Position::new(0, 1),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
            },
            &state,
        );

        assert!(result.expect("expected detached hover fallback").is_none());
    }

    #[test]
    fn test_detached_hover_connection_refused_degrades_to_none() {
        let uri = Url::parse("file:///tmp/ark_hover_unavailable_bridge.R").expect("expected uri");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(unavailable_status_file_bridge()),
            ..Default::default()
        };
        state
            .documents
            .insert(uri.clone(), Document::new("mean", Some(1)));

        let result = handle_hover(
            HoverParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri },
                    position: Position::new(0, 1),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
            },
            &state,
        );

        assert!(result.expect("expected detached hover fallback").is_none());
    }

    #[test]
    fn test_detached_hover_missing_object_degrades_to_none() {
        let uri = Url::parse("file:///tmp/ark_hover_missing_object.R").expect("expected uri");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(eval_error_bridge("object 'ggplot' not found")),
            ..Default::default()
        };
        state
            .documents
            .insert(uri.clone(), Document::new("ggplot", Some(1)));

        let result = handle_hover(
            HoverParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri },
                    position: Position::new(0, 2),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
            },
            &state,
        );

        assert!(result.expect("expected detached hover fallback").is_none());
    }

    #[test]
    fn test_detached_signature_help_missing_object_degrades_to_none() {
        let uri = Url::parse("file:///tmp/ark_signature_missing_object.R").expect("expected uri");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(eval_error_bridge("object 'ggplot' not found")),
            ..Default::default()
        };
        state
            .documents
            .insert(uri.clone(), Document::new("ggplot(", Some(1)));

        let result = handle_signature_help(
            SignatureHelpParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri },
                    position: Position::new(0, 7),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
                context: None,
            },
            &state,
        );

        assert!(result.expect("expected detached signature help fallback").is_none());
    }
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_selection_range(
    params: SelectionRangeParams,
    state: &WorldState,
) -> LspResult<Option<Vec<SelectionRange>>> {
    let document = state.get_document(&params.text_document.uri)?;

    // Get tree-sitter points to return selection ranges for
    let points = params
        .positions
        .into_iter()
        .map(|position| document.tree_sitter_point_from_lsp_position(position))
        .collect::<anyhow::Result<Vec<_>>>()?;

    let Some(selections) = selection_range(&document.ast, points) else {
        return Ok(None);
    };

    // Convert tree-sitter points to LSP positions everywhere
    let selections = selections
        .into_iter()
        .map(|selection| convert_selection_range_from_tree_sitter_to_lsp(selection, document))
        .collect::<anyhow::Result<Vec<_>>>()?;

    Ok(Some(selections))
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_references(
    params: ReferenceParams,
    state: &WorldState,
) -> LspResult<Option<Vec<Location>>> {
    let locations = match find_references(params, state) {
        Ok(locations) => locations,
        Err(_error) => {
            return Ok(None);
        },
    };

    if locations.is_empty() {
        Ok(None)
    } else {
        Ok(Some(locations))
    }
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_statement_range(
    params: StatementRangeParams,
    state: &WorldState,
) -> LspResult<Option<StatementRangeResponse>> {
    let document = state.get_document(&params.text_document.uri)?;
    let point = document.tree_sitter_point_from_lsp_position(params.position)?;
    statement_range(document, point)
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_help_topic(
    params: HelpTopicParams,
    state: &WorldState,
) -> LspResult<Option<HelpTopicResponse>> {
    let document = state.get_document(&params.text_document.uri)?;
    let point = document.tree_sitter_point_from_lsp_position(params.position)?;
    help_topic(point, document)
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_indent(
    params: DocumentOnTypeFormattingParams,
    state: &WorldState,
) -> LspResult<Option<Vec<TextEdit>>> {
    let ctxt = params.text_document_position;
    let doc = state.get_document(&ctxt.text_document.uri)?;
    let point = doc.tree_sitter_point_from_lsp_position(ctxt.position)?;

    indent_edit(doc, point.row)
}

#[tracing::instrument(level = "info", skip_all)]
pub(crate) fn handle_code_action(
    params: CodeActionParams,
    lsp_state: &LspState,
    state: &WorldState,
) -> LspResult<Option<CodeActionResponse>> {
    let uri = params.text_document.uri;
    let doc = state.get_document(&uri)?;
    let range = doc.tree_sitter_range_from_lsp_range(params.range)?;

    let code_actions = code_actions(&uri, doc, range, &lsp_state.capabilities);

    if code_actions.is_empty() {
        Ok(None)
    } else {
        Ok(Some(code_actions))
    }
}

pub(crate) fn handle_virtual_document(
    params: VirtualDocumentParams,
    state: &WorldState,
) -> LspResult<VirtualDocumentResponse> {
    if let Some(contents) = state.virtual_documents.get(&params.path) {
        Ok(contents.clone())
    } else {
        Err(LspError::Anyhow(anyhow!(
            "Can't find virtual document {}",
            params.path
        )))
    }
}

pub(crate) fn handle_input_boundaries(
    params: InputBoundariesParams,
) -> LspResult<InputBoundariesResponse> {
    if !crate::console::Console::is_initialized() {
        return Err(LspError::Anyhow(anyhow!(
            "input boundaries require an attached R runtime"
        )));
    }

    let boundaries = r_task(|| input_boundaries(&params.text))?;
    Ok(InputBoundariesResponse { boundaries })
}
