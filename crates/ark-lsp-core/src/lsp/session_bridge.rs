use std::collections::HashMap;
use std::collections::HashSet;
use std::hash::DefaultHasher;
use std::hash::Hash;
use std::hash::Hasher;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::RwLock;
use std::time::Duration;
use std::time::Instant;
use std::time::SystemTime;

use anyhow::anyhow;
use harp::syntax::sym_quote_invalid;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
use tower_lsp::lsp_types::Command;
use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::Documentation;
use tower_lsp::lsp_types::Hover;
use tower_lsp::lsp_types::HoverContents;
use tower_lsp::lsp_types::MarkupContent;
use tower_lsp::lsp_types::MarkupKind;
use tower_lsp::lsp_types::ParameterInformation;
use tower_lsp::lsp_types::ParameterLabel;
use tower_lsp::lsp_types::SignatureHelp;
use tower_lsp::lsp_types::SignatureInformation;
use tree_sitter::Node;
use uuid::Uuid;

use crate::lsp::call_context::analyze_call_context;
use crate::lsp::completions::dedupe_and_sort_completion_items;
use crate::lsp::completions::find_pipe_root_name;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::session_bridge_runtime::BridgeRequestClass;
use crate::lsp::session_bridge_runtime::BridgeRequestControl;
use crate::lsp::session_bridge_runtime::BridgeRuntime;
use crate::lsp::session_bridge_runtime::BridgeRuntimeDebugInfo;
use crate::lsp::session_bridge_runtime::BridgeRuntimeUnavailable;
use crate::lsp::traits::node::NodeExt;

#[derive(Clone, Debug)]
pub(crate) struct SessionBridge {
    source: SessionBridgeSource,
    session: BridgeSession,
    timeout: Duration,
    runtime: Arc<BridgeRuntime>,
    request_deadline: Option<Instant>,
    request_control: BridgeRequestControl,
}

const BROWSER_CONTEXT_SENTINEL: &str = ".ark_browser_context";
const DEBUG_COMMAND_COMPLETIONS: &[(&str, &str)] = &[
    ("c", "continue execution"),
    ("cont", "continue execution"),
    ("f", "finish current loop or function"),
    ("help", "show browser help"),
    ("n", "step over"),
    ("s", "step into"),
    ("where", "show the call stack"),
    ("r", "resume execution"),
    ("Q", "quit browser/debug mode"),
];

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionBridgeDebugInfo {
    source_kind: String,
    status_file: Option<PathBuf>,
    host: Option<String>,
    port: Option<u16>,
    backend: String,
    session_id: String,
    tmux_socket: String,
    tmux_session: String,
    tmux_pane: String,
    timeout_ms: u64,
    runtime: BridgeRuntimeDebugInfo,
}

#[derive(Clone, Debug)]
enum SessionBridgeSource {
    Fixed(SessionBridgeConnection),
    StatusFile(StatusFileSessionBridgeSource),
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct SessionBridgeConnection {
    host: String,
    port: u16,
    auth_token: String,
}

#[derive(Clone, Debug)]
struct StatusFileSessionBridgeSource {
    status_file: PathBuf,
    cached_connection: Arc<RwLock<Option<CachedStatusFileConnection>>>,
}

#[derive(Clone, Debug)]
struct CachedStatusFileConnection {
    fingerprint: StatusFileFingerprint,
    connection: SessionBridgeConnection,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct StatusFileFingerprint {
    modified: Option<SystemTime>,
    len: u64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBootstrap {
    pub search_path_symbols: Vec<String>,
    pub installed_packages: Vec<String>,
    pub library_paths: Vec<PathBuf>,
    pub static_object_members: HashMap<String, Vec<String>>,
    pub timings: SessionBootstrapTimings,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBootstrapTimings {
    pub total_ms: u64,
    pub search_path_symbols_ms: u64,
    pub library_paths_ms: u64,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBridgeConfig {
    pub host: String,
    pub port: u16,
    pub auth_token: String,
    pub status_file: Option<PathBuf>,
    pub backend: String,
    pub session_id: String,
    pub tmux_socket: String,
    pub tmux_session: String,
    pub tmux_pane: String,
    pub timeout_ms: u64,
}
mod completion;
mod protocol;

pub(crate) use completion::runtime_string_completion_takes_precedence;
pub(crate) use completion::target_name_completion_context;
use completion::*;
use protocol::BootstrapRequest;
use protocol::BootstrapResponse;
use protocol::BridgeCommandRequest;
use protocol::BridgeError;
use protocol::BridgeMember;
use protocol::BridgeSession;
pub(crate) use protocol::HelpPage;
use protocol::HelpTextRequest;
use protocol::HelpTextResponse;
use protocol::InspectOptions;
use protocol::InspectRequest;
use protocol::InspectResponse;
use protocol::ObjectMeta;
use protocol::PackageInfoResponse;
use protocol::SessionStatusPayload;
use protocol::StatusBootstrapPayload;
#[derive(Debug)]
struct SessionBridgeResponseError {
    code: String,
    message: String,
}

impl std::fmt::Display for SessionBridgeResponseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "session bridge request failed: {}: {}",
            self.code, self.message
        )
    }
}

impl std::error::Error for SessionBridgeResponseError {}

#[derive(Debug)]
struct SessionBridgeUnavailableError {
    message: String,
}

impl std::fmt::Display for SessionBridgeUnavailableError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "session bridge unavailable: {}", self.message)
    }
}

impl std::error::Error for SessionBridgeUnavailableError {}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct BridgeCompletionData {
    kind: String,
    expr: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    accessor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    member_name: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBridgeCompletion {
    pub items: Vec<CompletionItem>,
    pub merge_static: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TargetCompletionProject {
    pub root: String,
    pub script: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct TargetNameCompletionContext {
    pub prefix: Option<String>,
    pub close_string: bool,
}

impl SessionBridge {
    pub(crate) fn debug_info(&self) -> SessionBridgeDebugInfo {
        let (source_kind, status_file, host, port) = match &self.source {
            SessionBridgeSource::Fixed(connection) => (
                String::from("fixed"),
                None,
                Some(connection.host.clone()),
                Some(connection.port),
            ),
            SessionBridgeSource::StatusFile(source) => (
                String::from("status_file"),
                Some(source.status_file.clone()),
                None,
                None,
            ),
        };

        SessionBridgeDebugInfo {
            source_kind,
            status_file,
            host,
            port,
            backend: self.session.backend.clone(),
            session_id: self.session.session_id.clone(),
            tmux_socket: self.session.tmux_socket.clone(),
            tmux_session: self.session.tmux_session.clone(),
            tmux_pane: self.session.tmux_pane.clone(),
            timeout_ms: self.timeout.as_millis().min(u128::from(u64::MAX)) as u64,
            runtime: self.runtime.debug_info(),
        }
    }

    pub(crate) fn new(config: SessionBridgeConfig) -> anyhow::Result<Self> {
        let session = BridgeSession {
            backend: config.backend,
            session_id: config.session_id,
            tmux_socket: config.tmux_socket,
            tmux_session: config.tmux_session,
            tmux_pane: config.tmux_pane,
        };

        let source = if let Some(status_file) = config
            .status_file
            .filter(|status_file| !status_file.as_os_str().is_empty())
        {
            SessionBridgeSource::StatusFile(StatusFileSessionBridgeSource {
                status_file,
                cached_connection: Arc::new(RwLock::new(None)),
            })
        } else {
            if config.host.is_empty() {
                return Err(anyhow!("session bridge host is missing"));
            }
            if config.port == 0 {
                return Err(anyhow!("session bridge port is missing"));
            }

            SessionBridgeSource::Fixed(SessionBridgeConnection {
                host: config.host,
                port: config.port,
                auth_token: config.auth_token,
            })
        };

        Ok(Self {
            source,
            session,
            timeout: Duration::from_millis(config.timeout_ms.max(50)),
            runtime: Arc::new(BridgeRuntime::default()),
            request_deadline: None,
            request_control: BridgeRequestControl::default(),
        })
    }

    fn with_request_class(&self, class: BridgeRequestClass) -> Self {
        let mut bridge = self.clone();
        if bridge.request_deadline.is_none() {
            bridge.request_deadline = Some(Instant::now() + class.deadline(self.timeout));
        }
        bridge
    }

    pub(crate) fn with_request_control(&self, control: BridgeRequestControl) -> Self {
        let mut bridge = self.clone();
        bridge.request_control = control;
        bridge
    }

    fn deadline(&self) -> Instant {
        self.request_deadline
            .unwrap_or_else(|| Instant::now() + self.timeout)
    }

    fn send_request<T, R>(
        &self,
        connection: &SessionBridgeConnection,
        request: &T,
    ) -> anyhow::Result<R>
    where
        T: Serialize,
        R: DeserializeOwned,
    {
        let mut hasher = DefaultHasher::new();
        connection.hash(&mut hasher);
        self.runtime.request(
            hasher.finish(),
            connection.host.as_str(),
            connection.port,
            request,
            self.deadline(),
            &self.request_control,
        )
    }

    pub(crate) fn completion_items(
        &self,
        context: &DocumentContext,
        target_project: Option<TargetCompletionProject>,
    ) -> anyhow::Result<Option<SessionBridgeCompletion>> {
        self.with_request_class(BridgeRequestClass::Interactive)
            .completion_items_inner(context, target_project)
    }

    fn completion_items_inner(
        &self,
        context: &DocumentContext,
        target_project: Option<TargetCompletionProject>,
    ) -> anyhow::Result<Option<SessionBridgeCompletion>> {
        let Some(plan) = completion::plan(self, context, target_project.as_ref())? else {
            return Ok(None);
        };

        let merge_static = matches!(plan, CompletionPlan::Composite(_));

        let items = match plan {
            CompletionPlan::Unique(request) => match self.completion_items_for_request(&request) {
                Ok(items) => items,
                Err(err) if is_eval_missing_object_error(&err) => Vec::new(),
                Err(err) => return Err(err),
            },
            CompletionPlan::Composite(requests) => {
                let mut items = Vec::new();

                for request in requests {
                    match self.completion_items_for_request(&request) {
                        Ok(request_items) => items.extend(request_items),
                        Err(err) if is_eval_missing_object_error(&err) => {},
                        Err(err) => return Err(err),
                    }
                }

                dedupe_and_sort_completion_items(items)
            },
            CompletionPlan::HandledEmpty => Vec::new(),
        };

        Ok(Some(SessionBridgeCompletion {
            merge_static,
            items,
        }))
    }

    pub(crate) fn bootstrap(&self) -> anyhow::Result<SessionBootstrap> {
        self.with_request_class(BridgeRequestClass::Lifecycle)
            .bootstrap_inner()
    }

    fn bootstrap_inner(&self) -> anyhow::Result<SessionBootstrap> {
        match self.bootstrap_via_command() {
            Ok(bootstrap) => Ok(bootstrap),
            Err(err)
                if is_bridge_unavailable(&err) ||
                    is_ipc_auth_error(&err) ||
                    err.downcast_ref::<std::io::Error>().is_some() =>
            {
                Err(err)
            },
            Err(err) => Err(err),
        }
    }

    pub(crate) fn hover(&self, context: &DocumentContext) -> anyhow::Result<Option<Hover>> {
        self.with_request_class(BridgeRequestClass::Interactive)
            .hover_inner(context)
    }

    fn hover_inner(&self, context: &DocumentContext) -> anyhow::Result<Option<Hover>> {
        let Some(node) = locate_bridge_hover_node(context) else {
            return Ok(None);
        };

        let expr = node.node_to_string(context.document.contents.as_str())?;
        let payload = self.inspect(
            expr.as_str(),
            Some(InspectOptions {
                include_member_stats: Some(false),
                request_profile: Some(String::from("meta_only")),
                ..Default::default()
            }),
        )?;

        let Some(object_meta) = payload.object_meta else {
            return Ok(None);
        };

        let mut sections = vec![format!("```r\n{expr}\n```")];

        if !object_meta.summary.is_empty() {
            sections.push(object_meta.summary);
        }

        let mut details = vec![];
        if !object_meta.r#type.is_empty() {
            details.push(format!("Type: `{}`", object_meta.r#type));
        }
        if !object_meta.class.is_empty() {
            details.push(format!("Class: `{}`", object_meta.class.join(", ")));
        }
        if object_meta.length > 0 {
            details.push(format!("Length: `{}`", object_meta.length));
        }
        if !details.is_empty() {
            sections.push(details.join("\n"));
        }

        Ok(Some(Hover {
            contents: HoverContents::Markup(MarkupContent {
                kind: MarkupKind::Markdown,
                value: sections.join("\n\n"),
            }),
            range: None,
        }))
    }

    pub(crate) fn signature_help(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<SignatureHelp>> {
        self.with_request_class(BridgeRequestClass::Interactive)
            .signature_help_inner(context)
    }

    fn signature_help_inner(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<SignatureHelp>> {
        let Some(call) = analyze_call_context(context)? else {
            return Ok(None);
        };
        if call.callee == "." {
            return Ok(None);
        }

        let payload = self.inspect(
            call.callee.as_str(),
            Some(InspectOptions {
                include_member_stats: Some(false),
                request_profile: Some(String::from("interactive_rich")),
                ..Default::default()
            }),
        )?;

        if payload.members.is_empty() {
            return Ok(None);
        }

        let mut label = String::new();
        label.push_str(call.callee.as_str());
        label.push('(');

        let mut parameters = Vec::with_capacity(payload.members.len());
        let mut active_parameter = None;

        for (index, member) in payload.members.iter().enumerate() {
            let parameter_label = signature_parameter_label(member);
            let start = label.len() as u32;
            let end = start + parameter_label.len() as u32;

            label.push_str(parameter_label.as_str());
            label.push_str(", ");

            if call.active_argument.as_ref() == Some(&member.name_raw) {
                active_parameter = Some(index as u32);
            }

            let documentation = if member.summary.is_empty() {
                None
            } else {
                Some(Documentation::MarkupContent(MarkupContent {
                    kind: MarkupKind::Markdown,
                    value: format!("`{}`", member.summary),
                }))
            };

            parameters.push(ParameterInformation {
                label: ParameterLabel::LabelOffsets([start, end]),
                documentation,
            });
        }

        if label.ends_with(", ") {
            label.pop();
            label.pop();
        }
        label.push(')');

        if active_parameter.is_none() {
            let mut remaining = call.num_unnamed_arguments;

            for (index, member) in payload.members.iter().enumerate() {
                if call.explicit_parameters.contains(&member.name_raw) {
                    continue;
                }
                if remaining > 0 {
                    remaining -= 1;
                    continue;
                }
                active_parameter = Some(index as u32);
                break;
            }
        }

        if active_parameter.is_none() {
            active_parameter = Some(u32::try_from(payload.members.len() + 1).unwrap_or_default());
        }

        Ok(Some(SignatureHelp {
            signatures: vec![SignatureInformation {
                label,
                documentation: None,
                parameters: Some(parameters),
                active_parameter,
            }],
            active_signature: None,
            active_parameter,
        }))
    }

    pub(crate) fn help_text(&self, topic: &str) -> anyhow::Result<Option<HelpPage>> {
        self.with_request_class(BridgeRequestClass::ReadOnly)
            .help_text_inner(topic)
    }

    fn help_text_inner(&self, topic: &str) -> anyhow::Result<Option<HelpPage>> {
        let payload = match &self.source {
            SessionBridgeSource::Fixed(connection) => {
                self.help_text_with_connection(connection, topic)
            },
            SessionBridgeSource::StatusFile(source) => {
                self.run_dynamic_request(source, "bridge help text", |connection| {
                    self.help_text_with_connection(connection, topic)
                })
            },
        }?;

        if !payload.found || payload.text.trim().is_empty() {
            return Ok(None);
        }

        Ok(Some(HelpPage {
            text: payload.text,
            references: payload.references,
        }))
    }

    fn package_info(&self, package: &str) -> anyhow::Result<Option<PackageInfoResponse>> {
        let payload = self.bridge_command(
            "package_info",
            serde_json::json!({
                "package": package,
            }),
        )?;
        let payload: PackageInfoResponse = serde_json::from_value(payload)?;

        if !payload.found || payload.package.trim().is_empty() {
            return Ok(None);
        }

        Ok(Some(payload))
    }

    pub(crate) fn view_open(&self, expr: &str) -> anyhow::Result<Value> {
        self.view_command("view_open", serde_json::json!({ "expr": expr }))
    }

    pub(crate) fn view_state(&self, session_id: &str) -> anyhow::Result<Value> {
        self.view_command(
            "view_state",
            serde_json::json!({ "session_id": session_id }),
        )
    }

    pub(crate) fn view_page(
        &self,
        session_id: &str,
        offset: u32,
        limit: u32,
        columns: &[u32],
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_page",
            serde_json::json!({
                "session_id": session_id,
                "offset": offset,
                "limit": limit,
                "columns": columns,
            }),
        )
    }

    pub(crate) fn view_sort(
        &self,
        session_id: &str,
        column_index: u32,
        direction: &str,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_sort",
            serde_json::json!({
                "session_id": session_id,
                "column_index": column_index,
                "direction": direction,
            }),
        )
    }

    pub(crate) fn view_filter(
        &self,
        session_id: &str,
        column_index: u32,
        query: &str,
        mode: &str,
        value_key: &str,
        label: &str,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_filter",
            serde_json::json!({
                "session_id": session_id,
                "column_index": column_index,
                "query": query,
                "mode": mode,
                "value_key": value_key,
                "label": label,
            }),
        )
    }

    pub(crate) fn view_values(&self, session_id: &str, column_index: u32) -> anyhow::Result<Value> {
        self.view_command(
            "view_values",
            serde_json::json!({
                "session_id": session_id,
                "column_index": column_index,
            }),
        )
    }

    pub(crate) fn view_schema_search(
        &self,
        session_id: &str,
        query: &str,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_schema_search",
            serde_json::json!({
                "session_id": session_id,
                "query": query,
            }),
        )
    }

    pub(crate) fn view_profile(
        &self,
        session_id: &str,
        column_index: u32,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_profile",
            serde_json::json!({
                "session_id": session_id,
                "column_index": column_index,
            }),
        )
    }

    pub(crate) fn view_code(&self, session_id: &str) -> anyhow::Result<Value> {
        self.view_command("view_code", serde_json::json!({ "session_id": session_id }))
    }

    pub(crate) fn view_export(&self, session_id: &str, format: &str) -> anyhow::Result<Value> {
        self.view_command(
            "view_export",
            serde_json::json!({
                "session_id": session_id,
                "format": format,
            }),
        )
    }

    pub(crate) fn view_cell(
        &self,
        session_id: &str,
        row_index: u32,
        column_index: u32,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "view_cell",
            serde_json::json!({
                "session_id": session_id,
                "row_index": row_index,
                "column_index": column_index,
            }),
        )
    }

    pub(crate) fn view_close(&self, session_id: &str) -> anyhow::Result<Value> {
        self.view_command(
            "view_close",
            serde_json::json!({ "session_id": session_id }),
        )
    }

    pub(crate) fn object_children(
        &self,
        session_id: &str,
        node_id: &str,
        offset: u32,
        limit: u32,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "object_children",
            serde_json::json!({
                "session_id": session_id,
                "node_id": node_id,
                "offset": offset,
                "limit": limit,
            }),
        )
    }

    pub(crate) fn object_detail(&self, session_id: &str, node_id: &str) -> anyhow::Result<Value> {
        self.view_command(
            "object_detail",
            serde_json::json!({
                "session_id": session_id,
                "node_id": node_id,
            }),
        )
    }

    pub(crate) fn object_table(&self, session_id: &str, node_id: &str) -> anyhow::Result<Value> {
        self.view_command(
            "object_table",
            serde_json::json!({
                "session_id": session_id,
                "node_id": node_id,
            }),
        )
    }

    pub(crate) fn object_search(
        &self,
        session_id: &str,
        query: &str,
        max_nodes: u32,
        max_results: u32,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "object_search",
            serde_json::json!({
                "session_id": session_id,
                "query": query,
                "max_nodes": max_nodes,
                "max_results": max_results,
            }),
        )
    }

    pub(crate) fn targets_project_info(
        &self,
        root: String,
        script: String,
        store: String,
    ) -> anyhow::Result<Value> {
        self.bridge_command(
            "targets_project_info",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
            }),
        )
    }

    pub(crate) fn targets_manifest(
        &self,
        root: String,
        script: String,
        store: String,
    ) -> anyhow::Result<Value> {
        self.bridge_command(
            "targets_manifest",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
            }),
        )
    }

    pub(crate) fn targets_network(
        &self,
        root: String,
        script: String,
        store: String,
    ) -> anyhow::Result<Value> {
        self.bridge_command(
            "targets_network",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
            }),
        )
    }

    pub(crate) fn targets_meta(
        &self,
        root: String,
        script: String,
        store: String,
        names: Vec<String>,
    ) -> anyhow::Result<Value> {
        self.bridge_command(
            "targets_meta",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
                "names": names,
            }),
        )
    }

    pub(crate) fn targets_object_meta(
        &self,
        root: String,
        script: String,
        store: String,
        name: String,
    ) -> anyhow::Result<Value> {
        self.bridge_command(
            "targets_object_meta",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
                "name": name,
            }),
        )
    }

    pub(crate) fn targets_view_open(
        &self,
        root: String,
        script: String,
        store: String,
        name: String,
    ) -> anyhow::Result<Value> {
        self.view_command(
            "targets_view_open",
            serde_json::json!({
                "root": root,
                "script": script,
                "store": store,
                "name": name,
            }),
        )
    }

    pub(crate) fn targets_action(
        &self,
        action: String,
        root: String,
        script: String,
        store: String,
        names: Vec<String>,
    ) -> anyhow::Result<Value> {
        self.with_request_class(BridgeRequestClass::Mutating)
            .bridge_command(
                "targets_action",
                serde_json::json!({
                    "action": action,
                    "root": root,
                    "script": script,
                    "store": store,
                    "names": names,
                }),
            )
    }

    pub(crate) fn package_install(
        &self,
        packages: Vec<String>,
        description: String,
        dry_run: bool,
    ) -> anyhow::Result<Value> {
        self.with_request_class(BridgeRequestClass::Mutating)
            .bridge_command(
                "package_install",
                serde_json::json!({
                    "packages": packages,
                    "description": description,
                    "dry_run": dry_run,
                }),
            )
    }

    pub(crate) fn resolve_completion_item(
        &self,
        item: CompletionItem,
    ) -> anyhow::Result<(CompletionItem, bool)> {
        self.with_request_class(BridgeRequestClass::Interactive)
            .resolve_completion_item_inner(item)
    }

    fn resolve_completion_item_inner(
        &self,
        mut item: CompletionItem,
    ) -> anyhow::Result<(CompletionItem, bool)> {
        let Some(data) = item.data.clone() else {
            return Ok((item, false));
        };

        let Ok(data) = serde_json::from_value::<BridgeCompletionData>(data) else {
            return Ok((item, false));
        };

        if data.kind == "session_bridge_package" {
            if let Some(package_info) = self.package_info(data.expr.as_str())? {
                apply_package_completion_docs(&mut item, &package_info);
            }

            return Ok((item, true));
        }

        if data.kind != "session_bridge_inspect" {
            return Ok((item, false));
        }

        if let Some(member_name) = data.member_name.as_deref() {
            let payload = self.inspect(
                data.expr.as_str(),
                Some(InspectOptions {
                    accessor: data.accessor.clone(),
                    include_member_stats: Some(false),
                    max_members: Some(1),
                    member_name_filter: Some(String::from(member_name)),
                    request_profile: Some(String::from("interactive_rich")),
                    ..Default::default()
                }),
            )?;

            if let Some(member) = payload.members.into_iter().next() {
                apply_member_completion_docs(&mut item, &member);
            }

            return Ok((item, true));
        }

        let payload = self.inspect(
            data.expr.as_str(),
            Some(InspectOptions {
                include_member_stats: Some(false),
                request_profile: Some(String::from("meta_only")),
                ..Default::default()
            }),
        )?;

        if let Some(object_meta) = payload.object_meta.as_ref() {
            apply_object_completion_docs(&mut item, object_meta, data.expr.as_str());
        }

        Ok((item, true))
    }

    fn completion_request_from_data_context(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<CompletionRequest>> {
        if !context.explicit_completion_request {
            return Ok(None);
        }

        if call_argument_syntax_position(context) {
            return Ok(None);
        }

        if argument_prefix(context)?.is_some() {
            return Ok(None);
        }

        let prefix = symbol_prefix(context)?;
        let Some(mut call_node) = data_context_call_node(context) else {
            return self.completion_request_from_incomplete_data_context(context, prefix);
        };
        let pipe_root_expr =
            find_pipe_root_name(context, &call_node)?.or_else(|| pipe_root_text_expr(context));
        let pipe_fallback_request = pipe_root_expr.as_ref().map(|expr| CompletionRequest {
            expr: expr.clone(),
            flavor: CompletionFlavor::Pipe,
            prefix: prefix.clone(),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        });

        loop {
            if let Some(expr) =
                self.data_completion_expr_for_call(context, &call_node, pipe_root_expr.as_deref())?
            {
                return Ok(Some(CompletionRequest {
                    expr,
                    flavor: CompletionFlavor::Pipe,
                    prefix,
                    accessor: None,
                    close_string: false,
                    quote_insert: false,
                    subset_kind: None,
                }));
            }

            let Some(parent) = next_enclosing_call(call_node) else {
                return Ok(pipe_fallback_request);
            };

            call_node = parent;
        }
    }

    fn completion_request_from_incomplete_data_context(
        &self,
        context: &DocumentContext,
        prefix: Option<String>,
    ) -> anyhow::Result<Option<CompletionRequest>> {
        let Some(call) = incomplete_data_context_call(context)? else {
            return Ok(None);
        };

        let formals = self.call_formals(call.callee.as_str())?;
        if !formals.iter().any(|formal| formal == "data") {
            return Ok(None);
        }

        let expr =
            resolve_bound_argument_expr(formals.as_slice(), call.arguments.as_slice(), "data")
                .or_else(|| pipe_root_text_expr(context));
        Ok(expr.map(|expr| CompletionRequest {
            expr,
            flavor: CompletionFlavor::Pipe,
            prefix,
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        }))
    }

    fn data_completion_expr_for_call(
        &self,
        context: &DocumentContext,
        call_node: &Node,
        pipe_root_expr: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        if !call_argument_contains_point(call_node, context.point) {
            return Ok(None);
        }

        let Some(callee) = call_node.child_by_field_name("function") else {
            return Ok(None);
        };

        let callee = callee.node_to_string(context.document.contents.as_str())?;
        let formals = self.call_formals(callee.as_str())?;

        if !formals.iter().any(|formal| formal == "data") {
            return Ok(None);
        }

        let arguments = call_arguments(context.document.contents.as_str(), call_node)?;
        if let Some(expr) =
            resolve_bound_argument_expr(formals.as_slice(), arguments.as_slice(), "data")
        {
            return Ok(Some(expr));
        }

        if let Some(expr) = pipe_root_expr {
            return Ok(Some(String::from(expr)));
        }

        find_pipe_root_name(context, call_node)
    }

    fn call_formals(&self, callee: &str) -> anyhow::Result<Vec<String>> {
        self.inspect_names(call_formals_completion_expr(callee).as_str())
    }

    fn completion_items_for_request(
        &self,
        request: &CompletionRequest,
    ) -> anyhow::Result<Vec<CompletionItem>> {
        let payload = self.completion_payload(request)?;
        let object_meta = payload.object_meta.as_ref();

        let mut items = payload
            .members
            .into_iter()
            .enumerate()
            .map(|(index, member)| completion_item(member, request, object_meta, index))
            .collect::<Vec<_>>();

        self.append_browser_debug_command_completion_items(request, &mut items)?;
        prioritize_bare_symbol_completion_items(request, &mut items);

        Ok(items)
    }

    fn inspect(
        &self,
        expr: &str,
        options: Option<InspectOptions>,
    ) -> anyhow::Result<InspectResponse> {
        match &self.source {
            SessionBridgeSource::Fixed(connection) => {
                self.inspect_with_connection(connection, expr, options)
            },
            SessionBridgeSource::StatusFile(source) => self.inspect_dynamic(source, expr, options),
        }
    }

    fn bootstrap_via_command(&self) -> anyhow::Result<SessionBootstrap> {
        match &self.source {
            SessionBridgeSource::Fixed(connection) => self.bootstrap_with_connection(connection),
            SessionBridgeSource::StatusFile(source) => self.bootstrap_dynamic(source),
        }
    }

    fn bootstrap_dynamic(
        &self,
        source: &StatusFileSessionBridgeSource,
    ) -> anyhow::Result<SessionBootstrap> {
        let status_path = source.status_file.as_path();
        let (_, status) = read_session_status(status_path)?;
        validate_status_compatibility(status_path, &status)?;
        if let Some(bootstrap) = bootstrap_from_status(status_path, &status) {
            return Ok(bootstrap);
        }

        self.run_dynamic_request(source, "bridge bootstrap", |connection| {
            self.bootstrap_with_connection(connection)
        })
    }

    fn inspect_dynamic(
        &self,
        source: &StatusFileSessionBridgeSource,
        expr: &str,
        options: Option<InspectOptions>,
    ) -> anyhow::Result<InspectResponse> {
        self.run_dynamic_request(source, "bridge request", |connection| {
            self.inspect_with_connection(connection, expr, options.clone())
        })
    }

    fn inspect_with_connection(
        &self,
        connection: &SessionBridgeConnection,
        expr: &str,
        options: Option<InspectOptions>,
    ) -> anyhow::Result<InspectResponse> {
        let request = InspectRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            expr: String::from(expr),
            session: self.session.clone(),
            options,
        };

        let payload: InspectResponse = self.send_request(connection, &request)?;
        if let Some(error) = payload.error.as_ref() {
            return Err(SessionBridgeResponseError {
                code: error.code.clone(),
                message: error.message.clone(),
            }
            .into());
        }

        Ok(payload)
    }

    fn bridge_command(&self, command: &str, payload: Value) -> anyhow::Result<Value> {
        self.with_request_class(BridgeRequestClass::ReadOnly)
            .bridge_command_inner(command, payload)
    }

    fn bridge_command_inner(&self, command: &str, payload: Value) -> anyhow::Result<Value> {
        match &self.source {
            SessionBridgeSource::Fixed(connection) => {
                self.bridge_command_with_connection(connection, command, payload)
            },
            SessionBridgeSource::StatusFile(source) => {
                self.run_dynamic_request(source, "bridge command", |connection| {
                    self.bridge_command_with_connection(connection, command, payload.clone())
                })
            },
        }
    }

    fn view_command(&self, command: &str, payload: Value) -> anyhow::Result<Value> {
        self.with_request_class(BridgeRequestClass::ReadOnly)
            .bridge_command(command, payload)
    }

    fn bridge_command_with_connection<T>(
        &self,
        connection: &SessionBridgeConnection,
        command: &str,
        payload: T,
    ) -> anyhow::Result<Value>
    where
        T: Serialize,
    {
        let payload: Value = self.command_with_connection(connection, command, payload)?;
        if let Some(error) = bridge_error_from_value(&payload)? {
            return Err(SessionBridgeResponseError {
                code: error.code,
                message: error.message,
            }
            .into());
        }
        Ok(payload)
    }

    fn bootstrap_with_connection(
        &self,
        connection: &SessionBridgeConnection,
    ) -> anyhow::Result<SessionBootstrap> {
        let total_start = std::time::Instant::now();
        let request = BootstrapRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            command: String::from("bootstrap"),
            session: self.session.clone(),
        };

        let payload: BootstrapResponse = self.send_request(connection, &request)?;
        if let Some(error) = payload.error.as_ref() {
            return Err(SessionBridgeResponseError {
                code: error.code.clone(),
                message: error.message.clone(),
            }
            .into());
        }

        Ok(SessionBootstrap {
            search_path_symbols: payload.search_path_symbols,
            installed_packages: Vec::new(),
            library_paths: payload
                .library_paths
                .into_iter()
                .map(PathBuf::from)
                .collect::<Vec<_>>(),
            static_object_members: HashMap::new(),
            timings: SessionBootstrapTimings {
                total_ms: duration_ms(total_start.elapsed()),
                search_path_symbols_ms: 0,
                library_paths_ms: 0,
            },
        })
    }

    fn help_text_with_connection(
        &self,
        connection: &SessionBridgeConnection,
        topic: &str,
    ) -> anyhow::Result<HelpTextResponse> {
        let request = HelpTextRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            command: String::from("help_text"),
            topic: String::from(topic),
            session: self.session.clone(),
        };

        let payload: HelpTextResponse = self.send_request(connection, &request)?;
        if let Some(error) = payload.error.as_ref() {
            return Err(SessionBridgeResponseError {
                code: error.code.clone(),
                message: error.message.clone(),
            }
            .into());
        }

        Ok(payload)
    }

    fn command_with_connection<T, R>(
        &self,
        connection: &SessionBridgeConnection,
        command: &str,
        payload: T,
    ) -> anyhow::Result<R>
    where
        T: Serialize,
        R: DeserializeOwned,
    {
        let request = BridgeCommandRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            command: String::from(command),
            session: self.session.clone(),
            payload,
        };

        self.send_request(connection, &request)
    }

    fn run_dynamic_request<T, Request>(
        &self,
        source: &StatusFileSessionBridgeSource,
        exhausted_message: &'static str,
        mut request: Request,
    ) -> anyhow::Result<T>
    where
        Request: FnMut(&SessionBridgeConnection) -> anyhow::Result<T>,
    {
        let connection = source.current_connection()?;
        match request(&connection) {
            Ok(payload) => Ok(payload),
            Err(err) if should_refresh_dynamic_request(&err) => {
                let refreshed = source.refresh_connection()?;
                if refreshed == connection {
                    return Err(err);
                }

                request(&refreshed).map_err(|retry_err| {
                    if is_bridge_unavailable(&retry_err) {
                        SessionBridgeUnavailableError {
                            message: format!("{exhausted_message}: {retry_err}"),
                        }
                        .into()
                    } else {
                        retry_err
                    }
                })
            },
            Err(err) => Err(err),
        }
    }

    fn completion_payload(&self, request: &CompletionRequest) -> anyhow::Result<InspectResponse> {
        if request.subset_kind.is_some() {
            return self.subset_completion_payload(request);
        }

        let payload = self.inspect(
            request.expr.as_str(),
            Some(InspectOptions {
                accessor: request.accessor.clone(),
                include_member_stats: Some(false),
                max_members: Some(200),
                member_name_prefix: request.prefix.clone(),
                request_profile: Some(String::from("completion_lean")),
                ..Default::default()
            }),
        )?;

        if !payload.members.is_empty() || !matches!(request.flavor, CompletionFlavor::Symbol) {
            return Ok(payload);
        }

        self.browser_symbol_completion_payload(request)
    }

    fn subset_completion_payload(
        &self,
        request: &CompletionRequest,
    ) -> anyhow::Result<InspectResponse> {
        let payload = self.inspect(
            request.expr.as_str(),
            Some(InspectOptions {
                include_member_stats: Some(false),
                max_members: Some(200),
                member_name_prefix: request.prefix.clone(),
                request_profile: Some(String::from("completion_lean")),
                ..Default::default()
            }),
        )?;

        if payload.members.is_empty() && is_matrix_like(payload.object_meta.as_ref()) {
            return self.inspect(
                matrix_subset_completion_expr(request.expr.as_str()).as_str(),
                Some(InspectOptions {
                    include_member_stats: Some(false),
                    max_members: Some(200),
                    member_name_prefix: request.prefix.clone(),
                    request_profile: Some(String::from("completion_lean")),
                    ..Default::default()
                }),
            );
        }

        Ok(payload)
    }

    fn browser_symbol_completion_payload(
        &self,
        request: &CompletionRequest,
    ) -> anyhow::Result<InspectResponse> {
        let Some(prefix) = request
            .prefix
            .as_deref()
            .filter(|prefix| !prefix.is_empty())
        else {
            return Ok(InspectResponse::default());
        };

        let expr = browser_locals_completion_expr(prefix);
        let mut payload = self.inspect(
            expr.as_str(),
            Some(InspectOptions {
                include_member_stats: Some(false),
                max_members: Some(200),
                member_name_prefix: request.prefix.clone(),
                request_profile: Some(String::from("completion_lean")),
                ..Default::default()
            }),
        )?;

        payload.members.retain(|member| {
            let name = if member.name_raw.is_empty() {
                member.name_display.as_str()
            } else {
                member.name_raw.as_str()
            };
            !is_internal_browser_name(name)
        });

        Ok(payload)
    }

    fn append_browser_debug_command_completion_items(
        &self,
        request: &CompletionRequest,
        items: &mut Vec<CompletionItem>,
    ) -> anyhow::Result<()> {
        if !matches!(request.flavor, CompletionFlavor::Symbol) {
            return Ok(());
        }

        let Some(prefix) = request
            .prefix
            .as_deref()
            .filter(|prefix| !prefix.is_empty())
        else {
            return Ok(());
        };

        let debug_items = debug_command_completion_items(prefix);
        if debug_items.is_empty() {
            return Ok(());
        }

        if !self.browser_context_active()? {
            return Ok(());
        }

        for item in debug_items {
            items.retain(|existing| existing.label != item.label);
            items.push(item);
        }

        Ok(())
    }

    fn browser_context_active(&self) -> anyhow::Result<bool> {
        let names = self.inspect_names(browser_context_completion_expr())?;
        Ok(names.iter().any(|name| name == BROWSER_CONTEXT_SENTINEL))
    }

    fn inspect_names(&self, expr: &str) -> anyhow::Result<Vec<String>> {
        let payload = self.inspect(
            expr,
            Some(InspectOptions {
                include_member_stats: Some(false),
                max_members: Some(50_000),
                request_profile: Some(String::from("completion_lean")),
                ..Default::default()
            }),
        )?;

        Ok(payload
            .members
            .into_iter()
            .filter_map(|member| {
                if !member.name_raw.is_empty() {
                    Some(member.name_raw)
                } else if !member.name_display.is_empty() {
                    Some(member.name_display)
                } else {
                    None
                }
            })
            .collect())
    }
}

impl StatusFileSessionBridgeSource {
    fn current_connection(&self) -> anyhow::Result<SessionBridgeConnection> {
        self.current_connection_with_policy(StatusFileCachePolicy::AllowCached)
    }

    fn refresh_connection(&self) -> anyhow::Result<SessionBridgeConnection> {
        self.current_connection_with_policy(StatusFileCachePolicy::Refresh)
    }

    fn current_connection_with_policy(
        &self,
        policy: StatusFileCachePolicy,
    ) -> anyhow::Result<SessionBridgeConnection> {
        let path = self.status_file.as_path();
        let fingerprint = trusted_status_file_fingerprint(path)?;

        if matches!(policy, StatusFileCachePolicy::AllowCached) {
            if let Some(connection) = self.cached_connection(&fingerprint) {
                return Ok(connection);
            }
        }

        let (fingerprint, status) = read_session_status(path)?;
        let connection = connection_from_status(path, status)?;
        self.store_cached_connection(fingerprint, connection.clone());
        Ok(connection)
    }

    fn cached_connection(
        &self,
        fingerprint: &StatusFileFingerprint,
    ) -> Option<SessionBridgeConnection> {
        let cache = self.cached_connection.read().ok()?;
        let cached = cache.as_ref()?;

        if &cached.fingerprint != fingerprint {
            return None;
        }

        Some(cached.connection.clone())
    }

    fn store_cached_connection(
        &self,
        fingerprint: StatusFileFingerprint,
        connection: SessionBridgeConnection,
    ) {
        if let Ok(mut cache) = self.cached_connection.write() {
            *cache = Some(CachedStatusFileConnection {
                fingerprint,
                connection,
            });
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StatusFileCachePolicy {
    AllowCached,
    Refresh,
}

fn connection_from_status(
    status_file: &Path,
    status: SessionStatusPayload,
) -> anyhow::Result<SessionBridgeConnection> {
    if status.status != "ready" {
        return Err(SessionBridgeUnavailableError {
            message: if status.status.is_empty() {
                format!(
                    "startup status file '{}' has no ready state yet",
                    status_file.display()
                )
            } else {
                format!(
                    "startup status file '{}' is '{}'",
                    status_file.display(),
                    status.status
                )
            },
        }
        .into());
    }

    validate_status_compatibility(status_file, &status)?;

    let Some(port) = status.port else {
        return Err(SessionBridgeUnavailableError {
            message: format!(
                "startup status file '{}' does not publish a bridge port",
                status_file.display()
            ),
        }
        .into());
    };

    Ok(SessionBridgeConnection {
        host: String::from("127.0.0.1"),
        port,
        auth_token: status.auth_token,
    })
}

fn validate_status_compatibility(
    status_file: &Path,
    status: &SessionStatusPayload,
) -> anyhow::Result<()> {
    if cfg!(test) && status.product_version.is_empty() && status.bridge_schema.is_empty() {
        return Ok(());
    }

    if status.product_version != env!("ARK_PRODUCT_VERSION") {
        return Err(SessionBridgeUnavailableError {
            message: format!(
                "startup status file '{}' has incompatible product version '{}' (expected '{}')",
                status_file.display(),
                status.product_version,
                env!("ARK_PRODUCT_VERSION")
            ),
        }
        .into());
    }
    if status.bridge_schema != env!("ARK_BRIDGE_SCHEMA") {
        return Err(SessionBridgeUnavailableError {
            message: format!(
                "startup status file '{}' has incompatible bridge schema '{}' (expected '{}')",
                status_file.display(),
                status.bridge_schema,
                env!("ARK_BRIDGE_SCHEMA")
            ),
        }
        .into());
    }
    Ok(())
}

fn resolve_related_artifact_path(status_file: &Path, artifact_path: &str) -> Option<PathBuf> {
    let path = PathBuf::from(artifact_path);
    if path.is_absolute() {
        return Some(path);
    }

    status_file.parent().map(|parent| parent.join(path))
}

fn read_cached_bootstrap_payload(
    status_file: &Path,
    artifact_path: &str,
) -> anyhow::Result<StatusBootstrapPayload> {
    let path = resolve_related_artifact_path(status_file, artifact_path)
        .ok_or_else(|| anyhow!("startup bootstrap file path is invalid"))?;
    trusted_artifact_file_fingerprint(path.as_path(), "startup bootstrap file")?;
    let payload = std::fs::read_to_string(path.as_path())?;
    Ok(serde_json::from_str(payload.as_str())?)
}

fn bootstrap_payload_from_status(
    status_file: &Path,
    status: &SessionStatusPayload,
) -> Option<StatusBootstrapPayload> {
    if let Some(bootstrap) = status.bootstrap.clone() {
        return Some(bootstrap);
    }

    let bootstrap_path = status.bootstrap_path.as_deref()?;
    match read_cached_bootstrap_payload(status_file, bootstrap_path) {
        Ok(bootstrap) => Some(bootstrap),
        Err(err) => {
            log::trace!(
                "Ignoring cached startup bootstrap from '{}' because bootstrap artifact load failed: {err:?}",
                status_file.display()
            );
            None
        },
    }
}

fn bootstrap_from_status(
    status_file: &Path,
    status: &SessionStatusPayload,
) -> Option<SessionBootstrap> {
    if status.status != "ready" {
        return None;
    }

    let bootstrap = bootstrap_payload_from_status(status_file, status)?;
    if bootstrap.search_path_symbols.is_empty() || bootstrap.library_paths.is_empty() {
        return None;
    }

    if bootstrap.repl_seq.is_some() && bootstrap.repl_seq != status.repl_seq {
        log::trace!(
            "Ignoring cached startup bootstrap from '{}' because repl_seq changed",
            status_file.display()
        );
        return None;
    }

    let StatusBootstrapPayload {
        search_path_symbols,
        library_paths,
        total_ms,
        search_path_symbols_ms,
        library_paths_ms,
        ..
    } = bootstrap;

    Some(SessionBootstrap {
        search_path_symbols,
        installed_packages: Vec::new(),
        library_paths: library_paths
            .into_iter()
            .map(PathBuf::from)
            .collect::<Vec<_>>(),
        static_object_members: HashMap::new(),
        timings: SessionBootstrapTimings {
            total_ms: total_ms.unwrap_or(0),
            search_path_symbols_ms: search_path_symbols_ms.unwrap_or(0),
            library_paths_ms: library_paths_ms.unwrap_or(0),
        },
    })
}

pub(crate) fn is_ipc_auth_error(err: &anyhow::Error) -> bool {
    err.downcast_ref::<SessionBridgeResponseError>()
        .map(|err| err.code == "E_IPC_AUTH")
        .unwrap_or(false)
}

pub(crate) fn is_eval_missing_object_error(err: &anyhow::Error) -> bool {
    err.downcast_ref::<SessionBridgeResponseError>()
        .map(|err| {
            err.code == "E_EVAL" &&
                err.message.starts_with("object '") &&
                err.message.ends_with("not found")
        })
        .unwrap_or(false)
}

pub(crate) fn is_bridge_unavailable(err: &anyhow::Error) -> bool {
    err.downcast_ref::<SessionBridgeUnavailableError>()
        .is_some() ||
        err.downcast_ref::<BridgeRuntimeUnavailable>().is_some()
}

fn should_refresh_dynamic_request(err: &anyhow::Error) -> bool {
    is_ipc_auth_error(err) || is_bridge_unavailable(err)
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

fn read_session_status(
    path: &Path,
) -> anyhow::Result<(StatusFileFingerprint, SessionStatusPayload)> {
    let fingerprint = trusted_status_file_fingerprint(path)?;
    let payload = std::fs::read_to_string(path)?;
    let status: SessionStatusPayload = serde_json::from_str(payload.as_str())?;
    Ok((fingerprint, status))
}

fn trusted_status_file_fingerprint(path: &Path) -> anyhow::Result<StatusFileFingerprint> {
    trusted_artifact_file_fingerprint(path, "startup status file")
}

fn trusted_artifact_file_fingerprint(
    path: &Path,
    label: &str,
) -> anyhow::Result<StatusFileFingerprint> {
    if !path.exists() {
        return Err(SessionBridgeUnavailableError {
            message: format!("{label} '{}' does not exist yet", path.display()),
        }
        .into());
    }

    let metadata = std::fs::metadata(path)?;
    if !status_file_trusted_metadata(&metadata)? {
        return Err(SessionBridgeUnavailableError {
            message: format!("{label} '{}' is not trusted", path.display()),
        }
        .into());
    }

    Ok(StatusFileFingerprint {
        modified: metadata.modified().ok(),
        len: metadata.len(),
    })
}

fn status_file_trusted_metadata(metadata: &std::fs::Metadata) -> anyhow::Result<bool> {
    if !metadata.is_file() {
        return Ok(false);
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let current_uid = unsafe { libc::geteuid() };
        if metadata.uid() != current_uid {
            return Ok(false);
        }

        if metadata.mode() & 0o022 != 0 {
            return Ok(false);
        }
    }

    Ok(true)
}

fn completion_item(
    member: BridgeMember,
    request: &CompletionRequest,
    object_meta: Option<&ObjectMeta>,
    index: usize,
) -> CompletionItem {
    let label = if member.name_display.is_empty() {
        member.name_raw.clone()
    } else {
        member.name_display.clone()
    };

    let insert_text = match request.flavor {
        CompletionFlavor::Argument => {
            if !member.insert_text.is_empty() {
                member.insert_text.clone()
            } else {
                format!("{} = ", member.name_raw)
            }
        },
        CompletionFlavor::ComparisonString => {
            let escaped = escape_r_double_quoted(member.name_raw.as_str());
            if request.quote_insert {
                format!("\"{escaped}\"")
            } else {
                escaped
            }
        },
        CompletionFlavor::Extractor |
        CompletionFlavor::Namespace |
        CompletionFlavor::Package |
        CompletionFlavor::Symbol |
        CompletionFlavor::Target => member.name_raw.clone(),
        CompletionFlavor::Pipe => sym_quote_invalid(member.name_raw.as_str()),
        CompletionFlavor::Subset => subset_insert_text(
            member.name_raw.as_str(),
            request.subset_kind,
            object_meta.map(|meta| meta.class.as_slice()),
        ),
    };

    let kind = match request.flavor {
        CompletionFlavor::Argument => CompletionItemKind::VARIABLE,
        CompletionFlavor::ComparisonString => CompletionItemKind::VALUE,
        CompletionFlavor::Extractor | CompletionFlavor::Namespace => CompletionItemKind::FIELD,
        CompletionFlavor::Package => CompletionItemKind::MODULE,
        CompletionFlavor::Pipe | CompletionFlavor::Subset | CompletionFlavor::Symbol => {
            runtime_completion_item_kind(&member)
        },
        CompletionFlavor::Target => CompletionItemKind::VALUE,
    };

    let mut item = CompletionItem {
        label,
        detail: if member.r#type.is_empty() ||
            member.r#type == "unknown" ||
            matches!(request.flavor, CompletionFlavor::Package) && member.r#type == "NULL"
        {
            None
        } else {
            Some(member.r#type.clone())
        },
        documentation: if member.summary.is_empty() ||
            matches!(request.flavor, CompletionFlavor::Package) && member.summary == "NULL"
        {
            None
        } else {
            Some(Documentation::MarkupContent(MarkupContent {
                kind: MarkupKind::Markdown,
                value: member.summary.clone(),
            }))
        },
        filter_text: Some(member.name_raw.clone()),
        insert_text: Some(insert_text),
        kind: Some(kind),
        sort_text: Some(completion_sort_text(request, index)),
        command: completion_item_command(request),
        data: completion_item_data(request, &member)
            .and_then(|data| serde_json::to_value(data).ok()),
        ..Default::default()
    };

    if matches!(request.flavor, CompletionFlavor::Target) {
        item.detail = Some(String::from("targets target"));
    }

    item
}

fn debug_command_completion_items(prefix: &str) -> Vec<CompletionItem> {
    DEBUG_COMMAND_COMPLETIONS
        .iter()
        .enumerate()
        .filter(|(_, (label, _))| label.starts_with(prefix))
        .map(|(index, (label, description))| CompletionItem {
            label: String::from(*label),
            detail: Some(String::from("R browser command")),
            documentation: Some(Documentation::MarkupContent(MarkupContent {
                kind: MarkupKind::Markdown,
                value: String::from(*description),
            })),
            filter_text: Some(String::from(*label)),
            insert_text: Some(String::from(*label)),
            kind: Some(CompletionItemKind::KEYWORD),
            sort_text: Some(format!("0-debug-{index:04}")),
            ..Default::default()
        })
        .collect()
}

fn runtime_completion_item_kind(member: &BridgeMember) -> CompletionItemKind {
    match member.r#type.as_str() {
        "builtin" | "closure" | "function" | "special" => CompletionItemKind::FUNCTION,
        _ => CompletionItemKind::VARIABLE,
    }
}

fn completion_item_command(request: &CompletionRequest) -> Option<Command> {
    if !completion_needs_string_delimiter(request) {
        return None;
    }

    Some(Command {
        title: String::from("Complete String Delimiter"),
        command: String::from("ark.completeStringDelimiter"),
        ..Default::default()
    })
}

fn completion_needs_string_delimiter(request: &CompletionRequest) -> bool {
    if request.quote_insert {
        return false;
    }

    if matches!(request.flavor, CompletionFlavor::ComparisonString) {
        return true;
    }

    if request.close_string {
        return true;
    }

    matches!(
        request.subset_kind,
        Some(SubsetCompletionKind::StringSubset | SubsetCompletionKind::StringSubset2)
    )
}

fn completion_sort_text(request: &CompletionRequest, index: usize) -> String {
    match request.flavor {
        // Keep live subset completions above merged static items in contexts
        // like `dt[, .(m)]`, where the user is almost always asking for
        // columns rather than generic `m...` symbols from the search path.
        CompletionFlavor::Subset => format!("0-{index:04}"),
        _ => format!("{index:04}"),
    }
}

fn prioritize_bare_symbol_completion_items(
    request: &CompletionRequest,
    items: &mut [CompletionItem],
) {
    if !matches!(request.flavor, CompletionFlavor::Symbol) {
        return;
    }

    let names = items
        .iter()
        .map(|item| completion_item_symbol_name(item).to_string())
        .collect::<HashSet<_>>();

    let mut group_starts: HashMap<String, usize> = HashMap::new();
    for (index, item) in items.iter().enumerate() {
        let name = completion_item_symbol_name(item);
        let Some(generic) = symbol_completion_generic_name(name, &names) else {
            continue;
        };

        group_starts
            .entry(generic.to_string())
            .and_modify(|existing| *existing = (*existing).min(index))
            .or_insert(index);
    }

    if group_starts.is_empty() {
        return;
    }

    for (index, item) in items.iter().enumerate() {
        let name = completion_item_symbol_name(item);
        if let Some(group_start) = group_starts.get(name).copied() {
            group_starts.insert(name.to_string(), group_start.min(index));
        }
    }

    for (index, item) in items.iter_mut().enumerate() {
        let name = completion_item_symbol_name(item).to_string();
        let Some((group_start, tier)) = group_starts
            .get(name.as_str())
            .map(|group_start| (*group_start, 0))
            .or_else(|| {
                symbol_completion_generic_name(name.as_str(), &names).and_then(|generic| {
                    group_starts
                        .get(generic)
                        .map(|group_start| (*group_start, 1))
                })
            })
        else {
            continue;
        };

        item.sort_text = Some(format!("{group_start:04}-{tier}-{name}-{index:04}"));
    }
}

fn completion_item_symbol_name(item: &CompletionItem) -> &str {
    item.filter_text.as_deref().unwrap_or(item.label.as_str())
}

fn symbol_completion_generic_name<'a>(name: &'a str, names: &HashSet<String>) -> Option<&'a str> {
    name.char_indices().rev().find_map(|(index, ch)| {
        if ch != '.' || index == 0 {
            return None;
        }

        let generic = &name[..index];
        names.contains(generic).then_some(generic)
    })
}

fn completion_item_data(
    request: &CompletionRequest,
    member: &BridgeMember,
) -> Option<BridgeCompletionData> {
    match request.flavor {
        CompletionFlavor::Argument | CompletionFlavor::Extractor => Some(BridgeCompletionData {
            kind: String::from("session_bridge_inspect"),
            expr: request.expr.clone(),
            accessor: request.accessor.clone(),
            member_name: Some(member.name_raw.clone()),
        }),
        CompletionFlavor::ComparisonString => None,
        CompletionFlavor::Symbol => Some(BridgeCompletionData {
            kind: String::from("session_bridge_inspect"),
            expr: member.name_raw.clone(),
            accessor: None,
            member_name: None,
        }),
        CompletionFlavor::Subset => Some(BridgeCompletionData {
            kind: String::from("session_bridge_inspect"),
            expr: request.expr.clone(),
            accessor: Some(String::from("$")),
            member_name: Some(member.name_raw.clone()),
        }),
        CompletionFlavor::Pipe => Some(BridgeCompletionData {
            kind: String::from("session_bridge_inspect"),
            expr: request.expr.clone(),
            accessor: Some(String::from("$")),
            member_name: Some(member.name_raw.clone()),
        }),
        CompletionFlavor::Package => Some(BridgeCompletionData {
            kind: String::from("session_bridge_package"),
            expr: member.name_raw.clone(),
            accessor: None,
            member_name: None,
        }),
        CompletionFlavor::Namespace | CompletionFlavor::Target => None,
    }
}

fn apply_member_completion_docs(item: &mut CompletionItem, member: &BridgeMember) {
    if !member.r#type.is_empty() && member.r#type != "unknown" {
        item.detail = Some(member.r#type.clone());
    }

    if !member.summary.is_empty() {
        item.documentation = Some(Documentation::MarkupContent(MarkupContent {
            kind: MarkupKind::Markdown,
            value: member.summary.clone(),
        }));
    }
}

fn apply_object_completion_docs(item: &mut CompletionItem, object_meta: &ObjectMeta, expr: &str) {
    if !object_meta.r#type.is_empty() && object_meta.r#type != "unknown" {
        item.detail = Some(object_meta.r#type.clone());
    }

    let mut sections = vec![format!("```r\n{expr}\n```")];
    if !object_meta.summary.is_empty() {
        sections.push(object_meta.summary.clone());
    }

    let mut details = vec![];
    if !object_meta.r#type.is_empty() {
        details.push(format!("Type: `{}`", object_meta.r#type));
    }
    if !object_meta.class.is_empty() {
        details.push(format!("Class: `{}`", object_meta.class.join(", ")));
    }
    if object_meta.length > 0 {
        details.push(format!("Length: `{}`", object_meta.length));
    }
    if !details.is_empty() {
        sections.push(details.join("\n"));
    }

    item.documentation = Some(Documentation::MarkupContent(MarkupContent {
        kind: MarkupKind::Markdown,
        value: sections.join("\n\n"),
    }));
}

fn apply_package_completion_docs(item: &mut CompletionItem, package_info: &PackageInfoResponse) {
    item.detail = if package_info.version.is_empty() {
        Some(String::from("R package"))
    } else {
        Some(format!("R package {}", package_info.version))
    };

    let mut sections = vec![format!("Package: `{}`", package_info.package)];

    if !package_info.title.is_empty() {
        sections.push(package_info.title.clone());
    }
    if !package_info.description.is_empty() {
        sections.push(package_info.description.clone());
    }

    let mut details = Vec::new();
    if !package_info.version.is_empty() {
        details.push(format!("Version: `{}`", package_info.version));
    }
    if !package_info.license.is_empty() {
        details.push(format!("License: `{}`", package_info.license));
    }
    if !package_info.url.is_empty() {
        details.push(format!("URL: {}", package_info.url));
    }
    if !package_info.lib_path.is_empty() {
        details.push(format!("Library: `{}`", package_info.lib_path));
    }
    if !details.is_empty() {
        sections.push(details.join("\n"));
    }

    item.documentation = Some(Documentation::MarkupContent(MarkupContent {
        kind: MarkupKind::Markdown,
        value: sections.join("\n\n"),
    }));
}

fn bridge_error_from_value(value: &Value) -> anyhow::Result<Option<BridgeError>> {
    let Some(error) = value.get("error") else {
        return Ok(None);
    };

    if error.is_null() {
        return Ok(None);
    }

    serde_json::from_value(error.clone())
        .map(Some)
        .map_err(|err| err.into())
}

fn deserialize_string_vec<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Value::deserialize(deserializer)?;

    match value {
        Value::Null => Ok(vec![]),
        Value::String(value) => Ok(vec![value]),
        Value::Array(values) => values
            .into_iter()
            .map(|value| match value {
                Value::String(value) => Ok(value),
                other => Err(serde::de::Error::custom(format!(
                    "expected string in array, got {other}"
                ))),
            })
            .collect(),
        other => Err(serde::de::Error::custom(format!(
            "expected string or array of strings, got {other}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::io::Write;
    use std::net::TcpListener;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::sync::Barrier;
    use std::thread;

    use tree_sitter::Point;

    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::call_context::CallContext;
    use crate::lsp::document::Document;
    use crate::lsp::document::DocumentKind;
    use crate::lsp::session_bridge::protocol::HelpReference;
    use crate::treesitter::node_find_containing_call;

    fn ready_status(port: u16, auth_token: &str) -> String {
        serde_json::json!({
            "status": "ready",
            "port": port,
            "auth_token": auth_token,
            "product_version": env!("ARK_PRODUCT_VERSION"),
            "bridge_schema": env!("ARK_BRIDGE_SCHEMA"),
            "repl_ready": true,
        })
        .to_string()
    }

    #[test]
    fn test_completion_resolve_declines_static_item_ownership() {
        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port: 1,
            timeout_ms: 50,
            ..Default::default()
        })
        .unwrap();
        let item = CompletionItem {
            label: String::from("head"),
            data: Some(serde_json::json!({
                "Function": { "name": "head", "package": "utils" }
            })),
            ..Default::default()
        };

        let (resolved, owned) = bridge.resolve_completion_item(item).unwrap();

        assert!(!owned);
        assert_eq!(resolved.label, "head");
        assert!(resolved.documentation.is_none());
    }

    #[test]
    fn test_symbol_prefix_prefers_typed_subset_identifier() {
        let (text, point) = point_from_cursor("dt_ark[as.char@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert_eq!(
            symbol_prefix(&context).unwrap(),
            Some(String::from("as.char"))
        );
    }

    #[test]
    fn test_resolve_bound_argument_expr_prefers_named_data_argument() {
        let formals = vec![
            String::from("mapping"),
            String::from("data"),
            String::from("dots"),
        ];
        let arguments = vec![
            CallArgument {
                name: Some(String::from("mapping")),
                value_expr: String::from("aes(mpg, cyl)"),
            },
            CallArgument {
                name: Some(String::from("data")),
                value_expr: String::from("mtcars"),
            },
        ];

        assert_eq!(
            resolve_bound_argument_expr(formals.as_slice(), arguments.as_slice(), "data"),
            Some(String::from("mtcars"))
        );
    }

    #[test]
    fn test_resolve_bound_argument_expr_supports_positional_data_argument() {
        let formals = vec![String::from("data"), String::from("expr")];
        let arguments = vec![
            CallArgument {
                name: None,
                value_expr: String::from("mtcars"),
            },
            CallArgument {
                name: None,
                value_expr: String::from("mean(mpg)"),
            },
        ];

        assert_eq!(
            resolve_bound_argument_expr(formals.as_slice(), arguments.as_slice(), "data"),
            Some(String::from("mtcars"))
        );
    }

    #[test]
    fn test_resolve_active_formal_name_supports_positional_matching() {
        let formals = vec![String::from("data"), String::from("expr")];
        let call = CallContext {
            active_argument: None,
            explicit_parameters: vec![],
            num_unnamed_arguments: 0,
            callee: String::from("with"),
        };

        assert_eq!(
            resolve_active_formal_name(formals.as_slice(), &call),
            Some(String::from("data"))
        );
    }

    #[test]
    fn test_call_arguments_collects_named_and_positional_arguments() {
        let (text, point) = point_from_cursor("ggplot(mtcars, data = iris, aes(mpg, cyl@))");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);
        let call = node_find_containing_call(context.node).expect("expected call node");

        let arguments = call_arguments(context.document.contents.as_str(), &call)
            .expect("expected call arguments");

        assert_eq!(arguments, vec![
            CallArgument {
                name: None,
                value_expr: String::from("mpg"),
            },
            CallArgument {
                name: None,
                value_expr: String::from("cyl"),
            },
        ]);
    }

    #[test]
    fn test_incomplete_data_context_call_extracts_outer_data_argument() {
        let (text, point) = point_from_cursor("ggplot(mtcars, aes(@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);
        let call = incomplete_data_context_call(&context)
            .expect("expected call parse")
            .unwrap();

        assert_eq!(call.callee, "ggplot");
        assert_eq!(call.arguments, vec![CallArgument {
            name: None,
            value_expr: String::from("mtcars"),
        }]);
    }

    #[test]
    fn test_next_enclosing_call_finds_outer_call_through_pipe() {
        let (text, point) = point_from_cursor("mtcars |> ggplot(aes(cy@))");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);
        let inner = node_find_containing_call(context.node).expect("expected inner call");

        assert_eq!(
            inner
                .child_by_field_name("function")
                .expect("expected function")
                .node_to_string(context.document.contents.as_str())
                .expect("expected function text"),
            "aes"
        );

        let outer = next_enclosing_call(inner).expect("expected outer call");
        assert_eq!(
            outer
                .child_by_field_name("function")
                .expect("expected function")
                .node_to_string(context.document.contents.as_str())
                .expect("expected function text"),
            "ggplot"
        );
    }

    #[test]
    fn test_pipe_root_text_expr_extracts_root_for_nested_pipe_call() {
        let (text, point) = point_from_cursor("mtcars |> ggplot(aes(cy@))");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert_eq!(pipe_root_text_expr(&context), Some(String::from("mtcars")));
    }

    #[test]
    fn test_pipe_root_text_expr_extracts_root_for_closed_nested_pipe_call() {
        let text = "mtcars |> ggplot(aes(cy))";
        let point = Point::new(0, 22);
        let document = Document::new(text, None);
        let context = DocumentContext::new(&document, point, None);

        assert_eq!(pipe_root_text_expr(&context), Some(String::from("mtcars")));
    }

    #[test]
    fn test_analyze_call_context_prefers_inner_call_inside_piped_nested_call() {
        let (text, point) = point_from_cursor("mtcars |> ggplot(aes(cy@))");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let call = analyze_call_context(&context)
            .expect("expected call analysis")
            .expect("expected call context");

        assert_eq!(call.callee, "aes");
    }

    #[test]
    fn test_completion_request_from_call_text_handles_named_arg_then_comma() {
        let (text, point) = point_from_cursor("lm(data = mtcars, @");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_call(&context)
            .unwrap()
            .expect("expected argument completion request");

        assert_eq!(request.expr, "lm");
        assert!(matches!(request.flavor, CompletionFlavor::Argument));
        assert_eq!(request.prefix, None);

        let (text, point) = point_from_cursor("lm(data = mtcars, sub@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_call(&context)
            .unwrap()
            .expect("expected prefixed argument completion request");

        assert_eq!(request.expr, "lm");
        assert!(matches!(request.flavor, CompletionFlavor::Argument));
        assert_eq!(request.prefix, Some(String::from("sub")));
    }

    #[test]
    fn test_completion_request_from_call_text_ignores_value_position() {
        let (text, point) = point_from_cursor("lm(data = mtcars, subset = @");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_call(&context).unwrap();

        assert!(request.is_none());
    }

    #[test]
    fn test_search_path_completion_is_suppressed_for_empty_call_paren_trigger() {
        let (text, point) = point_from_cursor("corx::corx(@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("(")));

        let request = completion_request_from_search_path(&context).unwrap();

        assert!(request.is_none());
    }

    #[test]
    fn test_completion_plan_prefers_argument_after_named_arg_in_console_transcript() {
        let (text, point) = point_from_cursor("cat(\"ready\\n\")\n#> ready\nlm(data = mtcars, @");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);
        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port: 1,
            auth_token: String::new(),
            status_file: None,
            backend: String::new(),
            session_id: String::new(),
            tmux_socket: String::new(),
            tmux_session: String::new(),
            tmux_pane: String::new(),
            timeout_ms: 1000,
        })
        .unwrap();

        let plan = completion::plan(&bridge, &context, None)
            .unwrap()
            .expect("expected completion plan");

        match plan {
            CompletionPlan::Unique(request) => {
                assert!(matches!(request.flavor, CompletionFlavor::Argument));
                assert_eq!(request.expr, "lm");
                assert_eq!(request.prefix, None);
            },
            CompletionPlan::Composite(requests) => {
                assert!(requests.iter().any(|request| {
                    matches!(request.flavor, CompletionFlavor::Argument) &&
                        request.expr == "lm" &&
                        request.prefix.is_none()
                }));
            },
            CompletionPlan::HandledEmpty => panic!("expected argument completion plan"),
        }
    }

    #[test]
    fn test_call_text_after_named_argument_does_not_claim_data_mask_slot() {
        let (text, point) = point_from_cursor("filter(mtcars, cy@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let slot = call_text_argument_slot_after_named_argument(&context).unwrap();

        assert!(slot.is_none());
    }

    #[test]
    fn test_subset_completion_request_uses_typed_prefix() {
        let (text, point) = point_from_cursor("dt_ark[as.char@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, Some(String::from("as.char")));
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_subset_completion_request_canonicalizes_namespaced_tar_read_object() {
        let (text, point) = point_from_cursor("targets::tar_read(table1)[[\"@\"]]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("\"")));

        let request = completion_request_from_string_subset(&context)
            .unwrap()
            .expect("expected string subset completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("table1"));
        assert_eq!(
            request.subset_kind,
            Some(SubsetCompletionKind::StringSubset2)
        );
    }

    #[test]
    fn test_extractor_completion_request_supports_empty_rhs_at_point() {
        let (text, point) = point_from_cursor("mtcars$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_canonicalizes_tar_read_object() {
        let (text, point) = point_from_cursor("tar_read(clean_data)$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("clean_data"));
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_canonicalizes_namespaced_tar_read_object() {
        let (text, point) = point_from_cursor("targets::tar_read(clean_data)$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("clean_data"));
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_canonicalizes_tar_read_assignment() {
        let (text, point) =
            point_from_cursor("clean_data <- targets::tar_read(\"clean_data\")\nclean_data$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("clean_data"));
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_does_not_cross_shadowing_assignment() {
        let (text, point) = point_from_cursor(
            "clean_data <- targets::tar_read(\"clean_data\")\nclean_data <- list()\nclean_data$@",
        );
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "clean_data");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_string_subset_completion_request_canonicalizes_tar_read_assignment() {
        let (text, point) = point_from_cursor("table1 <- tar_read(table1)\ntable1[[\"@\"]]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("\"")));

        let request = completion_request_from_string_subset(&context)
            .unwrap()
            .expect("expected string subset completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("table1"));
        assert_eq!(
            request.subset_kind,
            Some(SubsetCompletionKind::StringSubset2)
        );
    }

    #[test]
    fn test_string_subset_text_fallback_canonicalizes_tar_read_assignment() {
        let (text, point) = point_from_cursor("table1 <- tar_read(table1)\ntable1[[\"@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("\"")));

        let request = completion_request_from_string_subset(&context)
            .unwrap()
            .expect("expected string subset completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("table1"));
        assert_eq!(
            request.subset_kind,
            Some(SubsetCompletionKind::StringSubset2)
        );
    }

    #[test]
    fn test_extractor_completion_request_text_fallback_supports_empty_rhs() {
        let (text, point) = point_from_cursor("mylist$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor_text(&context)
            .expect("expected text fallback extractor completion request");

        assert_eq!(request.expr, "mylist");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_text_fallback_canonicalizes_tar_read_object() {
        let (text, point) = point_from_cursor("targets::tar_read(clean_data)$@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor_text(&context)
            .expect("expected text fallback extractor completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("clean_data"));
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_supports_prefixed_rhs() {
        let (text, point) = point_from_cursor("mtcars$mp@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, Some(String::from("mp")));
    }

    #[test]
    fn test_extractor_completion_request_text_fallback_supports_prefixed_rhs() {
        let (text, point) = point_from_cursor("mylist$xy@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("$")));

        let request = completion_request_from_extractor_text(&context)
            .expect("expected text fallback extractor completion request");

        assert_eq!(request.expr, "mylist");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, Some(String::from("xy")));
    }

    #[test]
    fn test_extractor_completion_request_treats_next_line_as_rhs_continuation() {
        let document = Document::new("mtcars$\nmtcars$mp\n", None);
        let context = DocumentContext::new(&document, Point::new(0, 7), None);

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, Some(String::from("mtcars")));
    }

    #[test]
    fn test_extractor_completion_request_trigger_ignores_next_line_rhs() {
        let document = Document::new("mtcars$\nclean_data <- tar_read(clean_data)\n", None);
        let context = DocumentContext::new(&document, Point::new(0, 7), Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_extractor_completion_request_supports_single_line_with_trailing_newline() {
        let document = Document::new("mtcars$\n", None);
        let context = DocumentContext::new(&document, Point::new(0, 7), Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_data_table_j_completion_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_ark[, .(m@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, Some(String::from("m")));
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_data_table_j_completion_does_not_use_dot_call_context() {
        let (text, point) = point_from_cursor("dt_ark[, .(m@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert!(completion_request_from_call(&context).unwrap().is_none());
    }

    #[test]
    fn test_empty_data_table_dot_j_completion_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_ark[, .(@)]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, None);
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_empty_data_table_list_j_completion_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_ark[, list(@)]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, None);
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_data_table_list_j_after_comma_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_ark[, list(mpg,@)]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, None);
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_closed_data_table_j_completion_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_ark[, .(m@)]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_ark");
        assert_eq!(request.prefix, Some(String::from("m")));
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_closed_data_table_j_completion_does_not_use_dot_call_context() {
        let (text, point) = point_from_cursor("dt_ark[, .(m@)]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert!(completion_request_from_call(&context).unwrap().is_none());
    }

    #[test]
    fn test_data_table_nested_call_completion_uses_composite_plan() {
        let (text, point) =
            point_from_cursor("dt_iris_ark[Species == \"setosa\", .(mean = mean(@))]");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("(")));
        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port: 1,
            auth_token: String::new(),
            status_file: None,
            backend: String::new(),
            session_id: String::new(),
            tmux_socket: String::new(),
            tmux_session: String::new(),
            tmux_pane: String::new(),
            timeout_ms: 1000,
        })
        .unwrap();

        let plan = completion::plan(&bridge, &context, None)
            .unwrap()
            .expect("expected completion plan");

        let CompletionPlan::Composite(requests) = plan else {
            panic!("expected composite completion plan");
        };

        assert!(requests
            .iter()
            .any(|request| matches!(request.flavor, CompletionFlavor::Subset)));
        assert!(requests
            .iter()
            .any(|request| matches!(request.flavor, CompletionFlavor::Argument)));
    }

    #[test]
    fn test_data_table_open_nested_call_text_fallback_prefers_subset_context() {
        let (text, point) = point_from_cursor("dt_iris_ark[Species == \"setosa\", .(mean = mean(@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("(")));

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_iris_ark");
        assert_eq!(request.prefix, None);
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_data_table_open_nested_call_prefers_text_subset_request_in_document() {
        let text = "dt_iris_ark[Species == \"setosa\", .(mean = mean(\nvalue <- 1\n";
        let point = Point::new(0, 47);
        let document = Document::new(text, None);
        let context = DocumentContext::new(&document, point, Some(String::from("(")));

        let request = completion_request_from_subset(&context)
            .unwrap()
            .expect("expected subset completion request");

        assert_eq!(request.expr, "dt_iris_ark");
        assert_eq!(request.prefix, None);
        assert_eq!(request.subset_kind, Some(SubsetCompletionKind::Subset));
    }

    #[test]
    fn test_custom_call_request_quotes_bare_sys_unsetenv_completion() {
        let (text, point) = point_from_cursor("Sys.unsetenv(PA@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected custom completion request");

        assert!(matches!(request.flavor, CompletionFlavor::ComparisonString));
        assert_eq!(request.prefix, Some(String::from("PA")));
        assert!(request.quote_insert);
        assert!(!request.close_string);
    }

    #[test]
    fn test_custom_call_request_closes_in_string_getenv_completion() {
        let (text, point) = point_from_cursor("Sys.getenv(\"PA@\")");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected custom completion request");

        assert!(matches!(request.flavor, CompletionFlavor::ComparisonString));
        assert_eq!(request.prefix, Some(String::from("PA")));
        assert!(!request.quote_insert);
        assert!(request.close_string);
    }

    #[test]
    fn test_target_call_request_completes_bare_target_names() {
        let (text, point) = point_from_cursor("targets::tar_read(raw_@)");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("raw_")));
        assert!(!request.quote_insert);
        assert!(!request.close_string);
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_target_call_request_scopes_empty_tar_load_to_project() {
        let (text, point) = point_from_cursor("```{r}\ntar_load(@)\n```\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, Some(String::from("(")));
        let project = TargetCompletionProject {
            root: String::from("/tmp/ark-target-project"),
            script: String::from("/tmp/ark-target-project/_targets.R"),
        };

        let request = completion_request_from_custom_call(&context, Some(&project))
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, None);
        assert!(request.expr.contains("setwd(\"/tmp/ark-target-project\")"));
        assert!(request
            .expr
            .contains("targets::tar_manifest(script = \"/tmp/ark-target-project/_targets.R\")"));
    }

    #[test]
    fn test_target_call_request_completes_names_argument_strings() {
        let (text, point) = point_from_cursor("tar_make(names = \"clean_@\")");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("clean_")));
        assert!(!request.quote_insert);
        assert!(request.close_string);
    }

    #[test]
    fn test_target_call_request_completes_snipe_fuzzy_helpers() {
        let (text, point) = point_from_cursor("snipe::tar_fuzzy_make(\"clean_@\")");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("clean_")));
        assert!(!request.quote_insert);
        assert!(request.close_string);
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_target_call_request_completes_snipe_fuzzy_invalidate_helpers() {
        let (text, point) = point_from_cursor("tar_fuzzy_invalidate(clean_@)");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("clean_")));
        assert!(!request.quote_insert);
        assert!(!request.close_string);
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_target_call_request_completes_tar_render_target_name() {
        let (text, point) = point_from_cursor("tarchetypes::tar_render(rep_@)");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("rep_")));
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_target_call_request_completes_in_literate_fenced_chunk() {
        let (text, point) = point_from_cursor("```{r}\ntargets::tar_read(clean_@)\n```\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("clean_")));
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_target_call_request_completes_in_literate_inline_r() {
        let (text, point) = point_from_cursor("Report uses `r targets::tar_read(clean_@)`.\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_custom_call(&context, None)
            .unwrap()
            .expect("expected target completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Target));
        assert_eq!(request.prefix, Some(String::from("clean_")));
        assert!(request.expr.contains("targets::tar_manifest()"));
    }

    #[test]
    fn test_comparison_string_request_canonicalizes_tar_read_extractor_object() {
        let (text, point) = point_from_cursor("tar_read(clean_data)$indigenous == \"y@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, Some(String::from("\"")));

        let request = completion_request_from_comparison_string(&context)
            .unwrap()
            .expect("expected target comparison string completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("clean_data"));
        assert!(request.expr.contains("[[\"indigenous\"]]"));
        assert_eq!(request.prefix, Some(String::from("y")));
        assert!(matches!(request.flavor, CompletionFlavor::ComparisonString));
    }

    #[test]
    fn test_string_subset_request_canonicalizes_tar_read_assignment_in_literate_chunk() {
        let (text, point) =
            point_from_cursor("```{r}\ntable1 <- tar_read(table1)\ntable1[[\"@\"]]\n```\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let context = DocumentContext::new(&document, point, Some(String::from("\"")));

        let request = completion_request_from_string_subset(&context)
            .unwrap()
            .expect("expected string subset completion request");

        assert!(request.expr.contains(".ark_targets_read_for_completion"));
        assert!(request.expr.contains("table1"));
        assert_eq!(
            request.subset_kind,
            Some(SubsetCompletionKind::StringSubset2)
        );
    }

    #[test]
    fn test_namespace_lhs_request_uses_installed_package_completion_for_external_operator() {
        let (text, point) = point_from_cursor("uti@::adist");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_namespace(&context)
            .unwrap()
            .expect("expected namespace completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("uti")));
    }

    #[test]
    fn test_namespace_lhs_request_uses_installed_package_completion_for_internal_operator() {
        let (text, point) = point_from_cursor("uti@:::as.bibentry.bibentry");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_namespace(&context)
            .unwrap()
            .expect("expected namespace completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("uti")));
    }

    #[test]
    fn test_package_string_request_supports_require_namespace() {
        let (text, point) = point_from_cursor("requireNamespace(\"ut@\")");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_package_string(&context)
            .unwrap()
            .expect("expected package-string completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("ut")));
        assert!(request.close_string);
    }

    #[test]
    fn test_package_string_request_supports_require_namespace_single_quotes() {
        let (text, point) = point_from_cursor("requireNamespace('ut@')");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_package_string(&context)
            .unwrap()
            .expect("expected package-string completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("ut")));
        assert!(request.close_string);
    }

    #[test]
    fn test_package_string_text_fallback_supports_package_version_named_argument() {
        let (text, point) = point_from_cursor("packageVersion(pkg = \"ut@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_package_string(&context)
            .unwrap()
            .expect("expected package-string completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("ut")));
    }

    #[test]
    fn test_package_string_text_fallback_supports_package_version_named_argument_single_quotes() {
        let (text, point) = point_from_cursor("packageVersion(pkg = 'ut@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_package_string(&context)
            .unwrap()
            .expect("expected package-string completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, Some(String::from("ut")));
    }

    #[test]
    fn test_package_string_text_fallback_ignores_non_package_named_arguments() {
        let (text, point) = point_from_cursor("library(character.only = \"ut@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert!(completion_request_from_package_string(&context)
            .unwrap()
            .is_none());
    }

    #[test]
    fn test_package_call_request_does_not_expand_require_namespace_bare_symbols() {
        let (text, point) = point_from_cursor("requireNamespace(ut@)");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert!(completion_request_from_package_call(&context)
            .unwrap()
            .is_none());
    }

    #[test]
    fn test_empty_library_call_trigger_completion_is_suppressed() {
        let (text, point) = point_from_cursor("library(@)");
        let document = Document::new(text.as_str(), None);
        let context =
            DocumentContext::new_with_completion(&document, point, Some(String::from("(")), false);

        assert!(empty_package_call_autotrigger_is_suppressed(&context).unwrap());
        assert!(completion_request_from_package_call(&context)
            .unwrap()
            .is_none());
    }

    #[test]
    fn test_package_call_request_supports_explicit_empty_library_completion() {
        let (text, point) = point_from_cursor("library(@)");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new_with_completion(&document, point, None, true);

        let request = completion_request_from_package_call(&context)
            .unwrap()
            .expect("expected package-call completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Package));
        assert_eq!(request.expr, installed_packages_completion_expr());
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_search_path_request_rejects_explicit_empty_completion() {
        let (text, point) = point_from_cursor("@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new_with_completion(&document, point, None, true);

        let request = completion_request_from_search_path(&context).unwrap();
        assert!(request.is_none());
    }

    #[test]
    fn test_search_path_request_supports_empty_inline_r_space_trigger() {
        let (text, point) = point_from_cursor("Text `r @`.\n");
        let document = Document::new_with_kind(text.as_str(), None, DocumentKind::LiterateR);
        let context =
            DocumentContext::new_with_completion(&document, point, Some(String::from(" ")), false);

        let request = completion_request_from_search_path(&context)
            .unwrap()
            .expect("expected inline search-path completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Symbol));
        assert_eq!(
            request.expr,
            prioritized_empty_search_path_completion_expr()
        );
        assert_eq!(request.prefix, None);
    }

    #[test]
    fn test_search_path_request_pushes_typed_prefix_into_bridge_expr() {
        let (text, point) = point_from_cursor("arkenv_@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        let request = completion_request_from_search_path(&context)
            .unwrap()
            .expect("expected search-path completion request");

        assert!(matches!(request.flavor, CompletionFlavor::Symbol));
        assert_eq!(request.prefix, Some(String::from("arkenv_")));
        assert!(request.expr.contains(".prefix <- tolower(\"arkenv_\")"));
        assert!(request.expr.contains("startsWith(tolower(.x), .prefix)"));
    }

    #[test]
    fn test_subset_completion_items_use_priority_sort_text() {
        let item = completion_item(
            BridgeMember {
                name_display: String::from("mpg"),
                name_raw: String::from("mpg"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: String::from("dt_ark"),
                flavor: CompletionFlavor::Subset,
                prefix: Some(String::from("m")),
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: Some(SubsetCompletionKind::Subset),
            },
            None,
            0,
        );

        assert_eq!(item.sort_text, Some(String::from("0-0000")));
    }

    #[test]
    fn test_string_subset_completion_adds_delimiter_command() {
        let item = completion_item(
            BridgeMember {
                name_display: String::from("mpg"),
                name_raw: String::from("mpg"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: String::from("mtcars"),
                flavor: CompletionFlavor::Subset,
                prefix: None,
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: Some(SubsetCompletionKind::StringSubset2),
            },
            None,
            0,
        );

        assert_eq!(
            item.command.map(|command| command.command),
            Some(String::from("ark.completeStringDelimiter"))
        );
    }

    #[test]
    fn test_custom_bare_string_completion_wraps_quotes_without_delimiter_command() {
        let item = completion_item(
            BridgeMember {
                name_display: String::from("PATH"),
                name_raw: String::from("PATH"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: env_names_completion_expr(),
                flavor: CompletionFlavor::ComparisonString,
                prefix: Some(String::from("PA")),
                accessor: None,
                close_string: false,
                quote_insert: true,
                subset_kind: None,
            },
            None,
            0,
        );

        assert_eq!(item.insert_text, Some(String::from("\"PATH\"")));
        assert!(item.command.is_none());
    }

    #[test]
    fn test_symbol_completion_items_use_function_kind_for_callable_members() {
        let item = completion_item(
            BridgeMember {
                name_display: String::from("lapply"),
                name_raw: String::from("lapply"),
                r#type: String::from("closure"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: String::from("baseenv()"),
                flavor: CompletionFlavor::Symbol,
                prefix: Some(String::from("la")),
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: None,
            },
            None,
            0,
        );

        assert_eq!(item.kind, Some(CompletionItemKind::FUNCTION));
    }

    #[test]
    fn test_symbol_completion_items_use_variable_kind_for_unknown_members() {
        let item = completion_item(
            BridgeMember {
                name_display: String::from("letters"),
                name_raw: String::from("letters"),
                r#type: String::from("character"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: String::from("baseenv()"),
                flavor: CompletionFlavor::Symbol,
                prefix: Some(String::from("le")),
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: None,
            },
            None,
            0,
        );

        assert_eq!(item.kind, Some(CompletionItemKind::VARIABLE));
    }

    #[test]
    fn test_completion_item_label_falls_back_to_raw_name() {
        let item = completion_item(
            BridgeMember {
                name_raw: String::from("arkenv_candidate_001"),
                r#type: String::from("integer"),
                ..Default::default()
            },
            &CompletionRequest {
                expr: String::from("baseenv()"),
                flavor: CompletionFlavor::Symbol,
                prefix: Some(String::from("arkenv_")),
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: None,
            },
            None,
            0,
        );

        assert_eq!(item.label, "arkenv_candidate_001");
        assert_eq!(item.filter_text, Some(String::from("arkenv_candidate_001")));
        assert_eq!(item.insert_text, Some(String::from("arkenv_candidate_001")));
    }

    #[test]
    fn test_symbol_completion_items_prioritize_generic_before_s3_methods() {
        let request = CompletionRequest {
            expr: String::from("baseenv()"),
            flavor: CompletionFlavor::Symbol,
            prefix: Some(String::from("summ")),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        };

        let mut items = vec![
            completion_item(
                BridgeMember {
                    name_display: String::from("summary.aov"),
                    name_raw: String::from("summary.aov"),
                    r#type: String::from("closure"),
                    ..Default::default()
                },
                &request,
                None,
                0,
            ),
            completion_item(
                BridgeMember {
                    name_display: String::from("summary.glm"),
                    name_raw: String::from("summary.glm"),
                    r#type: String::from("closure"),
                    ..Default::default()
                },
                &request,
                None,
                1,
            ),
            completion_item(
                BridgeMember {
                    name_display: String::from("summary"),
                    name_raw: String::from("summary"),
                    r#type: String::from("closure"),
                    ..Default::default()
                },
                &request,
                None,
                2,
            ),
        ];

        prioritize_bare_symbol_completion_items(&request, &mut items);

        let generic = items
            .iter()
            .find(|item| item.label == "summary")
            .expect("expected summary completion item");
        let method = items
            .iter()
            .find(|item| item.label == "summary.aov")
            .expect("expected summary.aov completion item");

        assert_eq!(generic.sort_text.as_deref(), Some("0000-0-summary-0002"));
        assert_eq!(method.sort_text.as_deref(), Some("0000-1-summary.aov-0000"));
        assert!(generic.sort_text < method.sort_text);
    }

    #[test]
    fn test_debug_command_completion_items_include_uppercase_quit_command() {
        let items = debug_command_completion_items("Q");

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].label, "Q");
        assert_eq!(items[0].insert_text, Some(String::from("Q")));
        assert_eq!(items[0].kind, Some(CompletionItemKind::KEYWORD));
        assert_eq!(items[0].sort_text, Some(String::from("0-debug-0008")));
    }

    #[test]
    fn test_debug_command_completion_items_are_case_sensitive() {
        assert!(debug_command_completion_items("q").is_empty());
    }

    #[test]
    fn test_bootstrap_does_not_fallback_to_legacy_on_transient_io_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        listener
            .set_nonblocking(true)
            .expect("expected nonblocking listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let connections = Arc::new(AtomicUsize::new(0));
        let connections_bg = connections.clone();

        let handle = thread::spawn(move || {
            let start = std::time::Instant::now();
            while start.elapsed() < Duration::from_millis(250) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        connections_bg.fetch_add(1, Ordering::SeqCst);
                        drop(stream);
                    },
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    },
                    Err(err) => panic!("unexpected accept error: {err}"),
                }
            }
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("ark-test-token"),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let err = bridge.bootstrap().expect_err("expected bootstrap failure");
        handle.join().expect("expected listener thread to join");

        assert!(
            err.downcast_ref::<std::io::Error>().is_some() || is_bridge_unavailable(&err),
            "expected transient bootstrap error, got: {err:?}"
        );
        assert_eq!(
            connections.load(Ordering::SeqCst),
            1,
            "transient bootstrap failure should not fall back to legacy inspect requests"
        );
    }

    #[test]
    fn test_bootstrap_command_error_does_not_fall_back_to_legacy_inspect_requests() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let connections = Arc::new(AtomicUsize::new(0));
        let connections_bg = connections.clone();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected bridge request");
            connections_bg.fetch_add(1, Ordering::SeqCst);
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected bridge request payload");

            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected bootstrap request");
            assert_eq!(
                payload
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "bootstrap"
            );
            stream
                .write_all(
                    br#"{"error":{"code":"E_IPC_BOOTSTRAP","message":"bootstrap unavailable"}}"#,
                )
                .expect("expected bootstrap error response");
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("ark-test-token"),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let err = bridge
            .bootstrap()
            .expect_err("expected bootstrap command failure");
        handle.join().expect("expected listener thread to join");

        assert!(
            err.to_string().contains("bootstrap unavailable"),
            "expected direct bootstrap error, got: {err:?}"
        );
        assert_eq!(
            connections.load(Ordering::SeqCst),
            1,
            "bootstrap command error should not fall back to legacy inspect requests"
        );
    }

    #[test]
    fn test_status_file_current_connection_refreshes_when_file_changes() {
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(status.path(), ready_status(41001, "token-one"))
            .expect("expected status file");

        let source = StatusFileSessionBridgeSource {
            status_file: status.path().to_path_buf(),
            cached_connection: Arc::new(RwLock::new(None)),
        };

        let first = source
            .current_connection()
            .expect("expected initial connection");
        assert_eq!(first.auth_token, "token-one");
        assert!(source.cached_connection.read().unwrap().is_some());

        std::fs::write(status.path(), ready_status(41002, "token-two-longer"))
            .expect("expected updated status file");

        let second = source
            .current_connection()
            .expect("expected refreshed connection");
        assert_eq!(second.port, 41002);
        assert_eq!(second.auth_token, "token-two-longer");
    }

    #[test]
    fn test_status_file_rejects_incompatible_product_and_schema_versions() {
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            r#"{"status":"ready","port":41001,"auth_token":"token","product_version":"incompatible","bridge_schema":"v999","repl_ready":true}"#,
        )
        .expect("expected status file");

        let source = StatusFileSessionBridgeSource {
            status_file: status.path().to_path_buf(),
            cached_connection: Arc::new(RwLock::new(None)),
        };
        let err = source
            .current_connection()
            .expect_err("incompatible bridge metadata must be rejected");

        assert!(
            is_bridge_unavailable(&err),
            "version skew should be an actionable unavailable state: {err:?}"
        );
        assert!(
            err.to_string().contains("incompatible"),
            "version skew error should name the incompatibility: {err:?}"
        );
    }

    #[test]
    fn test_bootstrap_dynamic_refreshes_connection_after_auth_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(status.path(), ready_status(port, "token-one"))
            .expect("expected initial status file");
        let status_path = status.path().to_path_buf();

        let handle = thread::spawn(move || {
            let (mut first, _) = listener.accept().expect("expected first bootstrap request");
            let mut request = String::new();
            first
                .read_to_string(&mut request)
                .expect("expected first request payload");
            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected json bootstrap request");
            assert_eq!(
                payload
                    .get("auth_token")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "token-one"
            );

            std::fs::write(&status_path, ready_status(port, "token-two"))
                .expect("expected rotated status file");

            first
                .write_all(br#"{"error":{"code":"E_IPC_AUTH","message":"stale token"}}"#)
                .expect("expected auth error response");

            let (mut second, _) = listener
                .accept()
                .expect("expected second bootstrap request");
            let mut request = String::new();
            second
                .read_to_string(&mut request)
                .expect("expected second request payload");
            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected json bootstrap request");
            assert_eq!(
                payload
                    .get("auth_token")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "token-two"
            );

            second
                .write_all(
                    br#"{"status":"ok","search_path_symbols":["library","mtcars"],"library_paths":["/tmp/ark-test-library"]}"#,
                )
                .expect("expected successful bootstrap response");
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            status_file: Some(status.path().to_path_buf()),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let bootstrap = bridge.bootstrap().expect("expected bootstrap to recover");
        handle.join().expect("expected listener thread to join");

        assert_eq!(bootstrap.search_path_symbols, vec![
            String::from("library"),
            String::from("mtcars")
        ]);
        assert_eq!(bootstrap.library_paths, vec![PathBuf::from(
            "/tmp/ark-test-library"
        )]);
    }

    #[test]
    fn test_bootstrap_dynamic_uses_cached_status_payload_when_repl_seq_matches() {
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            r#"{
                "status":"ready",
                "port":41001,
                "auth_token":"token-one",
                "repl_ready":true,
                "repl_seq":0,
                "bootstrap":{
                    "repl_seq":0,
                    "search_path_symbols":["library","mtcars"],
                    "library_paths":["/tmp/ark-test-library"],
                    "total_ms":9,
                    "search_path_symbols_ms":4,
                    "library_paths_ms":1
                }
            }"#,
        )
        .expect("expected status file");

        let bridge = SessionBridge::new(SessionBridgeConfig {
            status_file: Some(status.path().to_path_buf()),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let bootstrap = bridge.bootstrap().expect("expected cached bootstrap");
        assert_eq!(bootstrap.search_path_symbols, vec![
            String::from("library"),
            String::from("mtcars")
        ]);
        assert_eq!(bootstrap.library_paths, vec![PathBuf::from(
            "/tmp/ark-test-library"
        )]);
        assert_eq!(bootstrap.timings.total_ms, 9);
        assert_eq!(bootstrap.timings.search_path_symbols_ms, 4);
        assert_eq!(bootstrap.timings.library_paths_ms, 1);
    }

    #[test]
    fn test_bootstrap_dynamic_uses_cached_bootstrap_artifact_when_present() {
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let status_path = tempdir.path().join("session.json");
        let bootstrap_path = tempdir.path().join("session-bootstrap.json");

        std::fs::write(
            &bootstrap_path,
            r#"{
                "repl_seq":0,
                "search_path_symbols":["library","mtcars"],
                "library_paths":["/tmp/ark-test-library"],
                "total_ms":7,
                "search_path_symbols_ms":3,
                "library_paths_ms":1
            }"#,
        )
        .expect("expected bootstrap artifact");

        std::fs::write(
            &status_path,
            r#"{
                "status":"ready",
                "port":41001,
                "auth_token":"token-one",
                "repl_ready":true,
                "repl_seq":0,
                "bootstrap_path":"session-bootstrap.json"
            }"#,
        )
        .expect("expected status file");

        let bridge = SessionBridge::new(SessionBridgeConfig {
            status_file: Some(status_path),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let bootstrap = bridge.bootstrap().expect("expected cached bootstrap");
        assert_eq!(bootstrap.search_path_symbols, vec![
            String::from("library"),
            String::from("mtcars")
        ]);
        assert_eq!(bootstrap.library_paths, vec![PathBuf::from(
            "/tmp/ark-test-library"
        )]);
        assert_eq!(bootstrap.timings.total_ms, 7);
        assert_eq!(bootstrap.timings.search_path_symbols_ms, 3);
        assert_eq!(bootstrap.timings.library_paths_ms, 1);
    }

    #[test]
    fn test_bootstrap_dynamic_ignores_stale_cached_status_payload() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            format!(
                r#"{{
                    "status":"ready",
                    "port":{},
                    "auth_token":"token-one",
                    "repl_ready":true,
                    "repl_seq":1,
                    "bootstrap":{{
                        "repl_seq":0,
                        "search_path_symbols":["stale_symbol"],
                        "library_paths":["/tmp/stale-library"]
                    }}
                }}"#,
                port
            ),
        )
        .expect("expected status file");

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected bootstrap request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected bootstrap request payload");
            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected json bootstrap request");
            assert_eq!(
                payload
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "bootstrap"
            );

            stream
                .write_all(
                    br#"{"status":"ok","search_path_symbols":["library","mtcars"],"library_paths":["/tmp/ark-test-library"]}"#,
                )
                .expect("expected successful bootstrap response");
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            status_file: Some(status.path().to_path_buf()),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let bootstrap = bridge
            .bootstrap()
            .expect("expected live bootstrap fallback");
        handle.join().expect("expected listener thread to join");

        assert_eq!(bootstrap.search_path_symbols, vec![
            String::from("library"),
            String::from("mtcars")
        ]);
        assert_eq!(bootstrap.library_paths, vec![PathBuf::from(
            "/tmp/ark-test-library"
        )]);
    }

    #[test]
    fn test_help_text_request_returns_full_text() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected help text request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected request payload");

            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected json help request");
            assert_eq!(
                payload
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "help_text"
            );
            assert_eq!(
                payload
                    .get("topic")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "dplyr::mutate"
            );

            stream
                .write_all(br#"{"found":true,"text":"mutate {dplyr}\n\nModify columns.","references":[{"label":"group_by()","topic":"group_by","package":"dplyr"}]}"#)
                .expect("expected help text response");
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("ark-test-token"),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let page = bridge
            .help_text("dplyr::mutate")
            .expect("expected help text request to succeed");
        handle.join().expect("expected listener thread to join");

        assert_eq!(
            page,
            Some(HelpPage {
                text: String::from("mutate {dplyr}\n\nModify columns."),
                references: vec![HelpReference {
                    label: String::from("group_by()"),
                    topic: String::from("group_by"),
                    package: Some(String::from("dplyr")),
                }],
            })
        );
    }

    #[test]
    fn test_targets_project_info_request_uses_bridge_command() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("expected target request");
            let mut request = String::new();
            stream
                .read_to_string(&mut request)
                .expect("expected target request payload");
            let payload: serde_json::Value =
                serde_json::from_str(request.trim()).expect("expected json target request");

            assert_eq!(
                payload
                    .get("command")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "targets_project_info"
            );
            assert_eq!(
                payload
                    .get("root")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "/tmp/ark-targets-project"
            );
            assert_eq!(
                payload
                    .get("script")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "/tmp/ark-targets-project/_targets.R"
            );
            assert_eq!(
                payload
                    .get("store")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default(),
                "/tmp/ark-targets-project/_targets"
            );

            stream
                .write_all(
                    br#"{"status":"ok","project":{"root":"/tmp/ark-targets-project"},"targets_available":true}"#,
                )
                .expect("expected target response");
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("ark-test-token"),
            timeout_ms: 50,
            ..Default::default()
        })
        .expect("expected bridge");

        let response = bridge
            .targets_project_info(
                String::from("/tmp/ark-targets-project"),
                String::from("/tmp/ark-targets-project/_targets.R"),
                String::from("/tmp/ark-targets-project/_targets"),
            )
            .expect("expected target response");
        handle.join().expect("expected listener thread to join");

        assert_eq!(
            response
                .get("project")
                .and_then(|project| project.get("root"))
                .and_then(serde_json::Value::as_str),
            Some("/tmp/ark-targets-project")
        );
        assert_eq!(
            response
                .get("targets_available")
                .and_then(serde_json::Value::as_bool),
            Some(true)
        );
    }

    #[test]
    fn test_dynamic_connection_refusal_obeys_interactive_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        drop(listener);

        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(status.path(), ready_status(port, "deadline-token"))
            .expect("expected status file");

        let bridge = SessionBridge::new(SessionBridgeConfig {
            status_file: Some(status.path().to_path_buf()),
            session_id: String::from("deadline-session"),
            timeout_ms: 1000,
            ..Default::default()
        })
        .expect("expected bridge");
        let document = Document::new("slow_object", None);
        let context = DocumentContext::new(&document, Point::new(0, 5), None);

        let started = std::time::Instant::now();
        let err = bridge.hover(&context).expect_err("expected refused bridge");
        let elapsed = started.elapsed();

        assert!(
            is_bridge_unavailable(&err) || err.downcast_ref::<std::io::Error>().is_some(),
            "expected unavailable bridge error, got {err:?}"
        );
        assert!(
            elapsed < Duration::from_millis(1200),
            "interactive bridge refusal exceeded its end-to-end deadline: {elapsed:?}"
        );
    }

    #[test]
    fn test_bridge_requests_are_serialized_before_entering_r() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let active = Arc::new(AtomicUsize::new(0));
        let max_active = Arc::new(AtomicUsize::new(0));

        let active_server = active.clone();
        let max_active_server = max_active.clone();
        let server = thread::spawn(move || {
            let mut handlers = Vec::new();
            for _ in 0..4 {
                let (mut stream, _) = listener.accept().expect("expected bridge request");
                let active = active_server.clone();
                let max_active = max_active_server.clone();
                handlers.push(thread::spawn(move || {
                    let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                    max_active.fetch_max(current, Ordering::SeqCst);
                    let mut request = String::new();
                    stream
                        .read_to_string(&mut request)
                        .expect("expected request body");
                    thread::sleep(Duration::from_millis(100));
                    stream
                        .write_all(br#"{"found":true,"text":"help"}"#)
                        .expect("expected response write");
                    active.fetch_sub(1, Ordering::SeqCst);
                }));
            }
            for handler in handlers {
                handler.join().expect("expected bridge handler");
            }
        });

        let bridge = SessionBridge::new(SessionBridgeConfig {
            host: String::from("127.0.0.1"),
            port,
            auth_token: String::from("queue-token"),
            timeout_ms: 1000,
            ..Default::default()
        })
        .expect("expected bridge");
        let start = Arc::new(Barrier::new(5));
        let mut clients = Vec::new();
        for index in 0..4 {
            let bridge = bridge.clone();
            let start = start.clone();
            clients.push(thread::spawn(move || {
                start.wait();
                bridge
                    .help_text(format!("topic-{index}").as_str())
                    .expect("expected bridge help response")
            }));
        }
        start.wait();
        for client in clients {
            client.join().expect("expected bridge client");
        }
        server.join().expect("expected bridge server");

        assert_eq!(
            max_active.load(Ordering::SeqCst),
            1,
            "only one request may enter the interactive R bridge at a time"
        );
    }
}
