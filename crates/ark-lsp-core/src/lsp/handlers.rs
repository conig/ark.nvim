//
// handlers.rs
//
// Copyright (C) 2024-2026 Posit Software, PBC. All rights reserved.
//
//

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::sync::LazyLock;

use anyhow::anyhow;
use regex::Regex;
use serde_json::Value;
use stdext::result::ResultExt;
use stdext::unwrap;
use tower_lsp::lsp_types::CodeActionParams;
use tower_lsp::lsp_types::CodeActionResponse;
use tower_lsp::lsp_types::Command;
use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
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
use tower_lsp::lsp_types::MarkupContent;
use tower_lsp::lsp_types::MarkupKind;
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
use crate::lsp::indexer;
use crate::lsp::input_boundaries::InputBoundariesParams;
use crate::lsp::input_boundaries::InputBoundariesResponse;
use crate::lsp::main_loop::LspState;
use crate::lsp::references::find_references;
use crate::lsp::selection_range::convert_selection_range_from_tree_sitter_to_lsp;
use crate::lsp::selection_range::selection_range;
use crate::lsp::session_bridge::is_bridge_unavailable;
use crate::lsp::session_bridge::is_eval_missing_object_error;
use crate::lsp::session_bridge::is_ipc_auth_error;
use crate::lsp::session_bridge::target_name_completion_context;
use crate::lsp::session_bridge::HelpPage;
use crate::lsp::session_bridge::TargetCompletionProject;
use crate::lsp::signature_help::r_signature_help;
use crate::lsp::state::WorldState;
use crate::lsp::statement_range::statement_range;
use crate::lsp::statement_range::StatementRangeParams;
use crate::lsp::statement_range::StatementRangeResponse;
use crate::lsp::symbols;
use crate::lsp::traits::node::NodeExt;
use crate::r_task;
use crate::treesitter::NodeTypeExt;

pub static ARK_VDOC_REQUEST: &str = "ark/internal/virtualDocument";
pub static ARK_STATUS_REQUEST: &str = "ark/internal/status";
pub static ARK_HELP_TEXT_REQUEST: &str = "ark/internal/helpText";
pub static ARK_SESSION_BOOTSTRAP_REQUEST: &str = "ark/internal/bootstrapSession";
pub static ARK_SESSION_UPDATE_NOTIFICATION: &str = "ark/updateSession";
pub static ARK_VIEW_OPEN_REQUEST: &str = "ark/internal/viewOpen";
pub static ARK_VIEW_STATE_REQUEST: &str = "ark/internal/viewState";
pub static ARK_VIEW_PAGE_REQUEST: &str = "ark/internal/viewPage";
pub static ARK_VIEW_SORT_REQUEST: &str = "ark/internal/viewSort";
pub static ARK_VIEW_FILTER_REQUEST: &str = "ark/internal/viewFilter";
pub static ARK_VIEW_SCHEMA_SEARCH_REQUEST: &str = "ark/internal/viewSchemaSearch";
pub static ARK_VIEW_PROFILE_REQUEST: &str = "ark/internal/viewProfile";
pub static ARK_VIEW_CODE_REQUEST: &str = "ark/internal/viewCode";
pub static ARK_VIEW_EXPORT_REQUEST: &str = "ark/internal/viewExport";
pub static ARK_VIEW_CELL_REQUEST: &str = "ark/internal/viewCell";
pub static ARK_VIEW_CLOSE_REQUEST: &str = "ark/internal/viewClose";
pub static ARK_TARGETS_PROJECT_INFO_REQUEST: &str = "ark/internal/targetsProjectInfo";
pub static ARK_TARGETS_MANIFEST_REQUEST: &str = "ark/internal/targetsManifest";
pub static ARK_TARGETS_NETWORK_REQUEST: &str = "ark/internal/targetsNetwork";
pub static ARK_TARGETS_META_REQUEST: &str = "ark/internal/targetsMeta";
pub static ARK_TARGETS_OBJECT_META_REQUEST: &str = "ark/internal/targetsObjectMeta";
pub static ARK_TARGETS_ACTION_REQUEST: &str = "ark/internal/targetsAction";

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
pub(crate) struct HelpTextParams {
    #[serde(default)]
    pub topic: String,
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionBootstrapResponse {
    #[serde(default)]
    pub hydrated: bool,
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionUpdateParams {
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub status_file: Option<PathBuf>,
    #[serde(default)]
    pub backend: String,
    #[serde(default)]
    pub session_id: String,
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
    #[serde(default)]
    pub repl_seq: Option<u64>,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewOpenParams {
    #[serde(default)]
    pub expr: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewSessionParams {
    #[serde(default)]
    pub session_id: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewPageParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub offset: u32,
    #[serde(default)]
    pub limit: u32,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewSortParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub column_index: u32,
    #[serde(default)]
    pub direction: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewFilterParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub column_index: u32,
    #[serde(default)]
    pub query: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewSchemaSearchParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub query: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewProfileParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub column_index: u32,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewExportParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub format: String,
}

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ViewCellParams {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub row_index: u32,
    #[serde(default)]
    pub column_index: u32,
}

#[derive(Debug)]
pub(crate) enum ViewRpcRequest {
    Open(ViewOpenParams),
    State(ViewSessionParams),
    Page(ViewPageParams),
    Sort(ViewSortParams),
    Filter(ViewFilterParams),
    SchemaSearch(ViewSchemaSearchParams),
    Profile(ViewProfileParams),
    Code(ViewSessionParams),
    Export(ViewExportParams),
    Cell(ViewCellParams),
    Close(ViewSessionParams),
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetsProjectParams {
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub store: String,
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetsMetaParams {
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub store: String,
    #[serde(default)]
    pub names: Vec<String>,
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetsObjectMetaParams {
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub store: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Default, Clone, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetsActionParams {
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub store: String,
    #[serde(default)]
    pub names: Vec<String>,
}

#[derive(Debug)]
pub(crate) enum TargetsRpcRequest {
    ProjectInfo(TargetsProjectParams),
    Manifest(TargetsProjectParams),
    Network(TargetsProjectParams),
    Meta(TargetsMetaParams),
    ObjectMeta(TargetsObjectMetaParams),
    Action(TargetsActionParams),
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
    serde_json::to_value(state.detached_status_snapshot())
        .map_err(|err| LspError::Anyhow(err.into()))
}

pub(crate) fn handle_help_text(
    params: HelpTextParams,
    state: &WorldState,
) -> LspResult<Option<HelpPage>> {
    if !state.has_attached_runtime() {
        let Some(session_bridge) = state.session_bridge.as_ref() else {
            return Ok(None);
        };

        return match session_bridge.help_text(params.topic.as_str()) {
            Ok(text) => Ok(text),
            Err(err) => {
                if is_ipc_auth_error(&err) || is_bridge_unavailable(&err) {
                    log_detached_bridge_auth_fallback("help text", &err);
                    Ok(None)
                } else {
                    Err(LspError::Anyhow(err))
                }
            },
        };
    }

    runtime_required(state)
}

pub(crate) fn handle_view_rpc(params: ViewRpcRequest, state: &WorldState) -> LspResult<Value> {
    if state.has_attached_runtime() {
        return Err(LspError::Anyhow(anyhow!(
            "Ark view requests are only supported in detached runtime mode"
        )));
    }

    let Some(session_bridge) = state.session_bridge.as_ref() else {
        return Err(LspError::Anyhow(anyhow!("session bridge missing")));
    };

    let response = match params {
        ViewRpcRequest::Open(params) => session_bridge.view_open(params.expr.as_str()),
        ViewRpcRequest::State(params) => session_bridge.view_state(params.session_id.as_str()),
        ViewRpcRequest::Page(params) => {
            session_bridge.view_page(params.session_id.as_str(), params.offset, params.limit)
        },
        ViewRpcRequest::Sort(params) => session_bridge.view_sort(
            params.session_id.as_str(),
            params.column_index,
            params.direction.as_str(),
        ),
        ViewRpcRequest::Filter(params) => session_bridge.view_filter(
            params.session_id.as_str(),
            params.column_index,
            params.query.as_str(),
        ),
        ViewRpcRequest::SchemaSearch(params) => {
            session_bridge.view_schema_search(params.session_id.as_str(), params.query.as_str())
        },
        ViewRpcRequest::Profile(params) => {
            session_bridge.view_profile(params.session_id.as_str(), params.column_index)
        },
        ViewRpcRequest::Code(params) => session_bridge.view_code(params.session_id.as_str()),
        ViewRpcRequest::Export(params) => {
            session_bridge.view_export(params.session_id.as_str(), params.format.as_str())
        },
        ViewRpcRequest::Cell(params) => session_bridge.view_cell(
            params.session_id.as_str(),
            params.row_index,
            params.column_index,
        ),
        ViewRpcRequest::Close(params) => session_bridge.view_close(params.session_id.as_str()),
    };

    response.map_err(LspError::Anyhow)
}

pub(crate) fn handle_targets_rpc(
    params: TargetsRpcRequest,
    state: &WorldState,
) -> LspResult<Value> {
    if state.has_attached_runtime() {
        return Err(LspError::Anyhow(anyhow!(
            "Ark target requests are only supported in detached runtime mode"
        )));
    }

    let Some(session_bridge) = state.session_bridge.as_ref() else {
        return Err(LspError::Anyhow(anyhow!("session bridge missing")));
    };

    let response = match params {
        TargetsRpcRequest::ProjectInfo(params) => {
            session_bridge.targets_project_info(params.root, params.script, params.store)
        },
        TargetsRpcRequest::Manifest(params) => {
            session_bridge.targets_manifest(params.root, params.script, params.store)
        },
        TargetsRpcRequest::Network(params) => {
            session_bridge.targets_network(params.root, params.script, params.store)
        },
        TargetsRpcRequest::Meta(params) => {
            session_bridge.targets_meta(params.root, params.script, params.store, params.names)
        },
        TargetsRpcRequest::ObjectMeta(params) => session_bridge.targets_object_meta(
            params.root,
            params.script,
            params.store,
            params.name,
        ),
        TargetsRpcRequest::Action(params) => session_bridge.targets_action(
            params.action,
            params.root,
            params.script,
            params.store,
            params.names,
        ),
    };

    response.map_err(LspError::Anyhow)
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
        if let Some(completions) = provide_static_target_name_completions(&context, &uri, state)
            .map_err(LspError::Anyhow)?
        {
            return Ok(completion_response_from_items(completions));
        }

        if let Some(completions) =
            provide_detached_pre_bridge_completions(&context, state).map_err(LspError::Anyhow)?
        {
            return Ok(completion_response_from_items(completions));
        }

        if let Some(session_bridge) = state.session_bridge.as_ref() {
            let target_project = target_project_paths(&uri, state)
                .map(|(root, script, _store)| TargetCompletionProject { root, script });
            let detached = match session_bridge.completion_items(&context, target_project) {
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

fn provide_static_target_name_completions(
    context: &DocumentContext,
    uri: &tower_lsp::lsp_types::Url,
    state: &WorldState,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    let Some(target_context) = target_name_completion_context(context)? else {
        return Ok(None);
    };

    let Some((root, _, _)) = target_project_paths(uri, state) else {
        return Ok(None);
    };

    let root = PathBuf::from(root);
    let prefix = target_context.prefix.as_deref().unwrap_or("");
    let mut names = BTreeSet::new();

    indexer::map(|entry_uri, _symbol, entry| {
        if !indexed_uri_is_under_root(entry_uri, root.as_path()) {
            return;
        }

        let indexer::IndexEntryData::Target { name } = &entry.data else {
            return;
        };

        if !prefix.is_empty() && !name.starts_with(prefix) {
            return;
        }

        names.insert(name.clone());
    });

    if names.is_empty() {
        return Ok(None);
    }

    let items = names
        .into_iter()
        .enumerate()
        .map(|(index, name)| target_completion_item(name, index, target_context.close_string))
        .collect();

    Ok(Some(items))
}

fn indexed_uri_is_under_root(uri: &tower_lsp::lsp_types::Url, root: &Path) -> bool {
    let Ok(path) = uri.to_file_path() else {
        return false;
    };

    path.starts_with(root)
}

fn target_completion_item(name: String, index: usize, close_string: bool) -> CompletionItem {
    CompletionItem {
        label: name.clone(),
        detail: Some(String::from("targets target")),
        filter_text: Some(name.clone()),
        insert_text: Some(name),
        kind: Some(CompletionItemKind::VALUE),
        sort_text: Some(format!("{index:04}")),
        command: close_string.then(|| Command {
            title: String::from("Complete String Delimiter"),
            command: String::from("ark.completeStringDelimiter"),
            ..Default::default()
        }),
        ..Default::default()
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

    if let Some(hover) = static_target_hover(&context, &uri, state).map_err(LspError::Anyhow)? {
        return Ok(Some(hover));
    }

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

fn static_target_hover(
    context: &DocumentContext,
    uri: &tower_lsp::lsp_types::Url,
    state: &WorldState,
) -> anyhow::Result<Option<Hover>> {
    let node = context
        .closest_node
        .ancestors()
        .find(|node| node.is_identifier_or_string())
        .unwrap_or(context.closest_node);
    if !node.is_identifier_or_string() {
        return Ok(None);
    }

    let name = node
        .get_identifier_or_string_text(context.document.contents.as_str())?
        .to_string();
    let Some((definition_uri, definition)) =
        find_static_target_definition(name.as_str(), uri, context.document, state)
    else {
        if target_reference_hover_context(&node, context.document.contents.as_str()) {
            return Ok(manifest_only_target_hover(name.as_str(), uri, state));
        }
        return Ok(None);
    };

    let indexer::IndexEntryData::Target { ref name } = definition.data else {
        return Ok(None);
    };

    let source = target_hover_source_label(definition_uri.as_uri());
    let line = definition.range.start.line + 1;
    let mut sections = vec![format!("```r\n{name}\n```")];
    if let Some(command) = static_target_command(
        definition_uri.as_uri(),
        &definition,
        uri,
        context.document,
        state,
    ) {
        sections.push(format!("Command:\n```r\n{command}\n```"));
    }
    sections.extend(static_target_dynamic_hover_sections(name, uri, state));
    sections.push(format!("Target declared in `{source}` on line `{line}`."));
    let value = sections.join("\n\n");

    Ok(Some(Hover {
        contents: HoverContents::Markup(MarkupContent {
            kind: MarkupKind::Markdown,
            value,
        }),
        range: None,
    }))
}

fn manifest_only_target_hover(
    name: &str,
    uri: &tower_lsp::lsp_types::Url,
    state: &WorldState,
) -> Option<Hover> {
    let session_bridge = state.session_bridge.as_ref()?;
    let (root, script, store) = target_project_paths(uri, state)?;
    let manifest = session_bridge.targets_manifest(root, script, store).ok()?;
    let target = target_manifest_record(name, &manifest)?;

    let mut sections = vec![
        format!("```r\n{name}\n```"),
        String::from("Manifest-only `{targets}` target."),
    ];

    if let Some(command) = target_hover_scalar(target.get("command")) {
        sections.push(format!("Command:\n```r\n{command}\n```"));
    }
    if let Some(description) = target_hover_scalar(target.get("description")) {
        sections.push(format!("Description: {description}"));
    }
    if let Some(format) = target_hover_scalar(target.get("format")) {
        sections.push(format!("Format: `{format}`"));
    }

    sections.push(String::from(
        "No static source location is available for this target.",
    ));

    Some(Hover {
        contents: HoverContents::Markup(MarkupContent {
            kind: MarkupKind::Markdown,
            value: sections.join("\n\n"),
        }),
        range: None,
    })
}

fn find_static_target_definition(
    name: &str,
    uri: &tower_lsp::lsp_types::Url,
    document: &crate::lsp::document::Document,
    state: &WorldState,
) -> Option<(indexer::FileId, indexer::IndexEntry)> {
    if let Some(info) = indexer::find_in_document(name, uri, document) {
        if matches!(info.1.data, indexer::IndexEntryData::Target { .. }) {
            return Some(info);
        }
    }

    let mut open_uris: Vec<_> = state
        .documents
        .keys()
        .filter(|open_uri| *open_uri != uri)
        .collect();
    open_uris.sort_by(|left, right| left.as_str().cmp(right.as_str()));

    for open_uri in open_uris {
        let Some(open_document) = state.documents.get(open_uri) else {
            continue;
        };
        let Some(info) = indexer::find_in_document(name, open_uri, open_document) else {
            continue;
        };
        if matches!(info.1.data, indexer::IndexEntryData::Target { .. }) {
            return Some(info);
        }
    }

    indexer::find_in_file(name, uri)
        .or_else(|| indexer::find(name))
        .filter(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
}

fn target_hover_source_label(uri: &tower_lsp::lsp_types::Url) -> String {
    if uri.scheme() == "file" {
        if let Ok(path) = uri.to_file_path() {
            return path.display().to_string();
        }
    }

    uri.to_string()
}

fn target_reference_hover_context(node: &tree_sitter::Node, contents: &str) -> bool {
    node.ancestors()
        .any(|ancestor| target_reference_call(&ancestor, contents))
}

fn target_reference_call(node: &tree_sitter::Node, contents: &str) -> bool {
    if !node.is_call() {
        return false;
    }

    let Some(function) = node.child_by_field_name("function") else {
        return false;
    };
    let Ok(callee) = function.node_to_string(contents) else {
        return false;
    };

    matches!(
        target_reference_unqualified_callee(callee.as_str()),
        "tar_read" | "tar_load" | "tar_make" | "tar_invalidate" | "tar_render"
    )
}

fn target_reference_unqualified_callee(callee: &str) -> &str {
    callee
        .rsplit_once(":::")
        .or_else(|| callee.rsplit_once("::"))
        .map(|(_, name)| name)
        .unwrap_or(callee)
}

fn static_target_command(
    definition_uri: &tower_lsp::lsp_types::Url,
    definition: &indexer::IndexEntry,
    current_uri: &tower_lsp::lsp_types::Url,
    current_document: &crate::lsp::document::Document,
    state: &WorldState,
) -> Option<String> {
    let document = if definition_uri == current_uri {
        current_document
    } else {
        state.documents.get(definition_uri)?
    };

    let point = document
        .tree_sitter_point_from_lsp_position(definition.range.start)
        .ok()?;
    let node = document
        .ast
        .root_node()
        .descendant_for_point_range(point, point)?;

    let call = node
        .ancestors()
        .find(|node| static_target_declaration_call(node, document.contents.as_str()))?;

    static_target_command_node(&call, document.contents.as_str())
        .and_then(|node| node.node_to_string(document.contents.as_str()).ok())
}

fn static_target_dynamic_hover_sections(
    name: &str,
    uri: &tower_lsp::lsp_types::Url,
    state: &WorldState,
) -> Vec<String> {
    let Some(session_bridge) = state.session_bridge.as_ref() else {
        return Vec::new();
    };
    let Some((root, script, store)) = target_project_paths(uri, state) else {
        return Vec::new();
    };

    let mut sections = Vec::new();
    let mut meta_payload = None;

    if let Ok(network) = session_bridge.targets_network(root.clone(), script.clone(), store.clone())
    {
        if let Some(section) = target_network_hover_section(name, &network) {
            sections.push(section);
        }
    }

    if let Ok(meta) =
        session_bridge.targets_meta(root.clone(), script.clone(), store.clone(), vec![
            String::from(name),
        ])
    {
        if let Some(section) = target_meta_hover_section(&meta) {
            sections.push(section);
        }
        meta_payload = Some(meta);
    }

    if meta_payload
        .as_ref()
        .is_some_and(target_meta_allows_hover_object_inspection)
    {
        if let Ok(object_meta) =
            session_bridge.targets_object_meta(root, script, store, String::from(name))
        {
            if let Some(section) = target_object_meta_hover_section(&object_meta) {
                sections.push(section);
            }
        }
    }

    sections
}

fn target_project_paths(
    uri: &tower_lsp::lsp_types::Url,
    state: &WorldState,
) -> Option<(String, String, String)> {
    let path = uri.to_file_path().ok()?;
    let root = find_targets_root_for_path(path.as_path())
        .or_else(|| find_open_targets_root(state))
        .or_else(|| path.parent().map(Path::to_path_buf))?;
    let script = root.join("_targets.R");
    let store = target_store_path(root.as_path(), state).unwrap_or_else(|| root.join("_targets"));

    Some((
        root.to_string_lossy().to_string(),
        script.to_string_lossy().to_string(),
        store.to_string_lossy().to_string(),
    ))
}

fn target_store_path(root: &Path, state: &WorldState) -> Option<PathBuf> {
    let script = root.join("_targets.R");
    let contents = open_targets_script_contents(script.as_path(), state)
        .or_else(|| fs::read_to_string(script.as_path()).ok())?;
    let store = PathBuf::from(target_store_config(contents.as_str())?);

    if store.is_absolute() {
        Some(store)
    } else {
        Some(root.join(store))
    }
}

fn open_targets_script_contents(script: &Path, state: &WorldState) -> Option<String> {
    state.documents.iter().find_map(|(uri, document)| {
        let path = uri.to_file_path().ok()?;
        if path == script {
            Some(document.source_contents.clone())
        } else {
            None
        }
    })
}

fn target_store_config(contents: &str) -> Option<String> {
    static STORE_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?s)(?:[A-Za-z.][A-Za-z0-9._]*(?:::|::))?tar_config_set\s*\([^)]*?\bstore\s*=\s*["'](?P<store>[^"']+)["']"#,
        )
        .unwrap()
    });

    STORE_RE
        .captures(contents)
        .and_then(|captures| captures.name("store"))
        .map(|capture| capture.as_str().to_string())
}

fn find_targets_root_for_path(path: &Path) -> Option<PathBuf> {
    let start = if path.is_dir() { path } else { path.parent()? };

    for ancestor in start.ancestors() {
        if ancestor.join("_targets.R").exists() {
            return Some(ancestor.to_path_buf());
        }
    }

    None
}

fn find_open_targets_root(state: &WorldState) -> Option<PathBuf> {
    state.documents.keys().find_map(|uri| {
        let path = uri.to_file_path().ok()?;
        if path.file_name()?.to_str()? == "_targets.R" {
            path.parent().map(Path::to_path_buf)
        } else {
            None
        }
    })
}

fn target_network_hover_section(name: &str, value: &Value) -> Option<String> {
    let edges = value.get("edges")?.as_array()?;
    let mut upstream = Vec::new();
    let mut downstream = Vec::new();

    for edge in edges {
        let from = edge.get("from").and_then(Value::as_str).unwrap_or_default();
        let to = edge.get("to").and_then(Value::as_str).unwrap_or_default();
        if to == name && !from.is_empty() {
            upstream.push(from.to_string());
        }
        if from == name && !to.is_empty() {
            downstream.push(to.to_string());
        }
    }

    if upstream.is_empty() && downstream.is_empty() {
        return None;
    }

    upstream.sort();
    upstream.dedup();
    downstream.sort();
    downstream.dedup();

    let mut details = Vec::new();
    if !upstream.is_empty() {
        details.push(format!(
            "Upstream: {}",
            format_target_list(upstream.as_slice())
        ));
    }
    if !downstream.is_empty() {
        details.push(format!(
            "Downstream: {}",
            format_target_list(downstream.as_slice())
        ));
    }

    Some(details.join("\n"))
}

fn target_manifest_record<'a>(
    name: &str,
    value: &'a Value,
) -> Option<&'a serde_json::Map<String, Value>> {
    value
        .get("targets")?
        .as_array()?
        .iter()
        .filter_map(Value::as_object)
        .find(|target| target.get("name").and_then(Value::as_str) == Some(name))
}

fn target_meta_hover_section(value: &Value) -> Option<String> {
    let meta = value.get("meta")?.as_array()?.first()?;
    let mut details = Vec::new();

    for (label, key) in [
        ("Status", "progress"),
        ("Time", "time"),
        ("Runtime", "seconds"),
        ("Bytes", "bytes"),
        ("Format", "format"),
        ("Error", "error"),
        ("Warning", "warning"),
        ("Path", "path"),
    ] {
        if let Some(value) = target_hover_scalar(meta.get(key)) {
            details.push(format!("{label}: `{value}`"));
        }
    }

    if details.is_empty() {
        None
    } else {
        Some(details.join("\n"))
    }
}

fn target_object_meta_hover_section(value: &Value) -> Option<String> {
    let payload = value
        .get("objectMeta")
        .or_else(|| value.get("object_meta"))?;
    let object_meta = payload
        .get("objectMeta")
        .or_else(|| payload.get("object_meta"))
        .unwrap_or(payload);
    let mut details = Vec::new();

    if let Some(summary) = target_hover_scalar(object_meta.get("summary")) {
        details.push(summary);
    }
    if let Some(value) = target_hover_scalar(object_meta.get("type")) {
        details.push(format!("Object type: `{value}`"));
    }
    if let Some(class) = object_meta.get("class").and_then(Value::as_array) {
        let class: Vec<_> = class
            .iter()
            .filter_map(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(String::from)
            .collect();
        if !class.is_empty() {
            details.push(format!("Object class: `{}`", class.join(", ")));
        }
    }
    if let Some(value) = target_hover_scalar(object_meta.get("length")) {
        details.push(format!("Object length: `{value}`"));
    }
    if let Some(members) = target_object_member_names(payload) {
        details.push(format!(
            "Members: {}",
            format_target_list(members.as_slice())
        ));
    }

    if details.is_empty() {
        None
    } else {
        Some(details.join("\n"))
    }
}

fn target_object_member_names(value: &Value) -> Option<Vec<String>> {
    let names: Vec<_> = value
        .get("members")?
        .as_array()?
        .iter()
        .filter_map(|member| {
            member
                .get("nameDisplay")
                .or_else(|| member.get("name_display"))
                .or_else(|| member.get("nameRaw"))
                .or_else(|| member.get("name_raw"))
                .and_then(Value::as_str)
        })
        .filter(|name| !name.is_empty())
        .map(String::from)
        .collect();

    if names.is_empty() {
        None
    } else {
        Some(names)
    }
}

fn target_meta_allows_hover_object_inspection(value: &Value) -> bool {
    const MAX_HOVER_OBJECT_BYTES: u64 = 5 * 1024 * 1024;

    let Some(meta) = value
        .get("meta")
        .and_then(Value::as_array)
        .and_then(|meta| meta.first())
    else {
        return false;
    };

    let Some(bytes) = meta.get("bytes") else {
        return false;
    };

    if let Some(bytes) = bytes.as_u64() {
        return bytes <= MAX_HOVER_OBJECT_BYTES;
    }

    if let Some(bytes) = bytes.as_f64() {
        return bytes.is_finite() && bytes >= 0.0 && bytes <= MAX_HOVER_OBJECT_BYTES as f64;
    }

    false
}

fn target_hover_scalar(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if value.is_null() {
        return None;
    }

    let text = match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        Value::Bool(value) => value.to_string(),
        _ => return None,
    };

    if text.is_empty() || text == "NA" {
        None
    } else {
        Some(text)
    }
}

fn format_target_list(names: &[String]) -> String {
    let max_names = 8;
    let rendered = names
        .iter()
        .take(max_names)
        .map(|name| format!("`{name}`"))
        .collect::<Vec<_>>()
        .join(", ");

    if names.len() > max_names {
        format!("{rendered}, ...")
    } else {
        rendered
    }
}

fn static_target_declaration_call(node: &tree_sitter::Node, contents: &str) -> bool {
    if !node.is_call() {
        return false;
    }

    let Some(callee) = node.child_by_field_name("function") else {
        return false;
    };
    let Ok(callee) = callee.node_as_str(contents) else {
        return false;
    };

    matches!(
        callee,
        "tar_target" |
            "targets::tar_target" |
            "targets:::tar_target" |
            "tar_render" |
            "tarchetypes::tar_render" |
            "tarchetypes:::tar_render"
    )
}

fn static_target_command_node<'a>(
    call: &'a tree_sitter::Node,
    _contents: &str,
) -> Option<tree_sitter::Node<'a>> {
    let mut unnamed_values =
        call.arguments()
            .into_iter()
            .filter_map(|(name, value)| if name.is_none() { value } else { None });

    unnamed_values.next()?;
    unnamed_values.next()
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
    Ok(goto_definition(document, params, state).log_err().flatten())
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::Read;
    use std::io::Write;
    use std::net::TcpListener;
    use std::path::PathBuf;
    use std::thread;

    use tempfile::tempdir;
    use tower_lsp::lsp_types::CompletionContext as LspCompletionContext;
    use tower_lsp::lsp_types::Position;
    use tower_lsp::lsp_types::TextDocumentIdentifier;
    use tower_lsp::lsp_types::TextDocumentPositionParams;
    use tower_lsp::lsp_types::WorkDoneProgressParams;
    use url::Url;

    use super::*;
    use crate::fixtures::point_from_cursor;
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
            backend: String::from("tmux"),
            session_id: String::from("ark-test-session"),
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
                    format!(r#"{{"error":{{"code":"E_EVAL","message":"{}"}}}}"#, message)
                        .as_bytes(),
                )
                .expect("expected bridge error response");
        });

        SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("test-token"),
            status_file: None,
            backend: String::from("tmux"),
            session_id: String::from("ark-test-session"),
            tmux_socket: String::from("/tmp/ark-test.sock"),
            tmux_session: String::from("ark-test"),
            tmux_pane: String::from("%1"),
            timeout_ms: 1000,
        })
        .expect("expected session bridge")
    }

    fn json_response_bridge(response: &'static str) -> SessionBridge {
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
                .write_all(response.as_bytes())
                .expect("expected bridge response");
        });

        SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("test-token"),
            status_file: None,
            backend: String::from("tmux"),
            session_id: String::from("ark-test-session"),
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
            backend: String::from("tmux"),
            session_id: String::from("ark-test-session"),
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
    fn test_static_target_hover_uses_open_targets_script_definition() {
        let targets_uri =
            Url::parse("file:///tmp/ark-target-hover/_targets.R").expect("expected targets uri");
        let analysis_uri =
            Url::parse("file:///tmp/ark-target-hover/analysis.R").expect("expected analysis uri");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            ..Default::default()
        };
        state.documents.insert(
            targets_uri,
            Document::new("list(tar_target(clean_data, raw_data + 1))", None),
        );
        state.documents.insert(
            analysis_uri.clone(),
            Document::new("targets::tar_read(clean_data)", None),
        );

        let result = handle_hover(
            HoverParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri: analysis_uri },
                    position: Position::new(0, 19),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
            },
            &state,
        )
        .expect("expected target hover");

        let Some(Hover {
            contents: HoverContents::Markup(markup),
            ..
        }) = result
        else {
            panic!("expected static target hover");
        };
        assert!(markup.value.contains("clean_data"));
        assert!(markup.value.contains("raw_data + 1"));
        assert!(markup.value.contains("_targets.R"));
    }

    #[test]
    fn test_manifest_only_target_hover_degrades_dynamic_target() {
        let tempdir = tempdir().expect("expected tempdir");
        let targets_uri =
            Url::from_file_path(tempdir.path().join("_targets.R")).expect("expected targets uri");
        let report_uri =
            Url::from_file_path(tempdir.path().join("report.Rmd")).expect("expected report uri");
        let (text, point) = point_from_cursor(r#"targets::tar_read("generated_report@")"#);
        let report_document = Document::new(text.as_str(), None);
        let position = report_document
            .lsp_position_from_tree_sitter_point(point)
            .expect("expected hover position");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: Some(json_response_bridge(
                r#"{"targets":[{"name":"generated_report","command":"factory()","description":"Generated from a factory","format":"file"}]}"#,
            )),
            ..Default::default()
        };
        state
            .documents
            .insert(targets_uri, Document::new("list()\n", None));
        state.documents.insert(report_uri.clone(), report_document);

        let result = handle_hover(
            HoverParams {
                text_document_position_params: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri: report_uri },
                    position,
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
            },
            &state,
        )
        .expect("expected target hover");

        let Some(Hover {
            contents: HoverContents::Markup(markup),
            ..
        }) = result
        else {
            panic!("expected manifest-only target hover");
        };
        assert!(markup.value.contains("generated_report"));
        assert!(markup.value.contains("Manifest-only"));
        assert!(markup.value.contains("factory()"));
        assert!(markup.value.contains("No static source location"));
    }

    #[test]
    fn test_target_project_paths_uses_open_tar_config_store() {
        let tempdir = tempdir().expect("expected tempdir");
        let targets_uri =
            Url::from_file_path(tempdir.path().join("_targets.R")).expect("expected targets uri");
        let analysis_uri =
            Url::from_file_path(tempdir.path().join("analysis.R")).expect("expected analysis uri");
        let mut state = WorldState::default();
        state.documents.insert(
            targets_uri,
            Document::new(
                r#"
targets::tar_config_set(
  store = "cache/targets"
)
list()
"#,
                None,
            ),
        );

        let (_, _, store) =
            target_project_paths(&analysis_uri, &state).expect("expected target project paths");

        assert_eq!(
            PathBuf::from(store),
            tempdir.path().join("cache").join("targets")
        );
    }

    #[test]
    fn test_detached_completion_uses_static_targets_before_bridge() {
        let _lock = indexer::indexer_test_lock();
        let _guard = indexer::ResetIndexerGuard;
        indexer::indexer_clear();

        let project = tempdir().expect("expected project tempdir");
        let other_project = tempdir().expect("expected other project tempdir");
        fs::write(project.path().join("_targets.R"), "").expect("expected targets script");
        fs::write(other_project.path().join("_targets.R"), "").expect("expected targets script");

        let targets_uri =
            Url::from_file_path(project.path().join("_targets.R")).expect("expected targets uri");
        let other_targets_uri = Url::from_file_path(other_project.path().join("_targets.R"))
            .expect("expected other targets uri");
        let report_uri =
            Url::from_file_path(project.path().join("analysis.R")).expect("expected report uri");

        let targets_document = Document::new(
            "list(tar_target(clean_data, raw_data), tar_target(report, clean_data))",
            None,
        );
        let other_targets_document = Document::new("list(tar_target(other_project, 1))", None);
        indexer::update(&targets_document, &targets_uri).expect("expected target index");
        indexer::update(&other_targets_document, &other_targets_uri)
            .expect("expected other target index");

        let (text, point) = point_from_cursor("targets::tar_read(cle@)");
        let report_document = Document::new(text.as_str(), None);
        let position = report_document
            .lsp_position_from_tree_sitter_point(point)
            .expect("expected completion position");
        let mut state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            ..Default::default()
        };
        state.documents.insert(targets_uri, targets_document);
        state.documents.insert(report_uri.clone(), report_document);

        let direct_context = state
            .get_document(&report_uri)
            .expect("expected report document");
        let direct_context =
            DocumentContext::new_with_completion(direct_context, point, None, true);
        let target_context = target_name_completion_context(&direct_context)
            .expect("expected target context lookup")
            .expect("expected target context");
        assert_eq!(target_context.prefix, Some(String::from("cle")));
        let direct_items =
            provide_static_target_name_completions(&direct_context, &report_uri, &state)
                .expect("expected static target lookup")
                .expect("expected static target items");
        assert!(direct_items.iter().any(|item| item.label == "clean_data"));
        assert!(direct_items
            .iter()
            .all(|item| item.label != "other_project"));

        let result = handle_completion(
            CompletionParams {
                text_document_position: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri: report_uri },
                    position,
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
                partial_result_params: Default::default(),
                context: Some(LspCompletionContext {
                    trigger_kind: CompletionTriggerKind::INVOKED,
                    trigger_character: None,
                }),
            },
            &state,
        )
        .expect("expected static target completion");

        let Some(CompletionResponse::Array(items)) = result else {
            panic!("expected completion items");
        };

        let clean_data = items
            .iter()
            .find(|item| item.label == "clean_data")
            .expect("expected clean_data target completion");
        assert!(items.iter().all(|item| item.label != "other_project"));
        assert_eq!(clean_data.detail, Some(String::from("targets target")));
        assert_eq!(clean_data.kind, Some(CompletionItemKind::VALUE));
    }

    #[test]
    fn test_target_hover_dynamic_sections_format_bridge_payloads() {
        let network = serde_json::json!({
            "edges": [
                { "from": "raw_data", "to": "clean_data" },
                { "from": "clean_data", "to": "report" }
            ]
        });
        let meta = serde_json::json!({
            "meta": [
                {
                    "progress": "built",
                    "seconds": 1.25,
                    "bytes": 2048,
                    "format": "rds"
                }
            ]
        });
        let object_meta = serde_json::json!({
            "objectMeta": {
                "objectMeta": {
                    "summary": "10 x 3 data frame",
                    "type": "list",
                    "class": ["data.frame"],
                    "length": 3
                },
                "members": [
                    { "nameDisplay": "id" },
                    { "name_display": "value" }
                ]
            }
        });

        let network_section =
            target_network_hover_section("clean_data", &network).expect("expected network");
        assert!(network_section.contains("Upstream: `raw_data`"));
        assert!(network_section.contains("Downstream: `report`"));

        let meta_section = target_meta_hover_section(&meta).expect("expected meta");
        assert!(meta_section.contains("Status: `built`"));
        assert!(meta_section.contains("Format: `rds`"));
        assert!(target_meta_allows_hover_object_inspection(&meta));

        let object_section =
            target_object_meta_hover_section(&object_meta).expect("expected object meta");
        assert!(object_section.contains("10 x 3 data frame"));
        assert!(object_section.contains("Object class: `data.frame`"));
        assert!(object_section.contains("Members: `id`, `value`"));

        let huge_meta = serde_json::json!({ "meta": [{ "bytes": 10000000 }] });
        assert!(!target_meta_allows_hover_object_inspection(&huge_meta));
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

        assert!(result
            .expect("expected detached signature help fallback")
            .is_none());
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

    let code_actions = code_actions(&uri, doc, range, &lsp_state.capabilities, state);

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
