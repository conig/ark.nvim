use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::RwLock;
use std::time::Duration;
use std::time::SystemTime;

use anyhow::anyhow;
use harp::syntax::sym_quote_invalid;
use regex::Regex;
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
use tree_sitter::Point;
use uuid::Uuid;

use crate::lsp::completions::dedupe_and_sort_completion_items;
use crate::lsp::completions::find_pipe_root_name;
use crate::lsp::completions::call_node_position_type;
use crate::lsp::completions::CallNodePositionType;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::traits::node::NodeExt;
use crate::lsp::traits::point::PointExt;
use crate::treesitter::node_find_containing_call;
use crate::treesitter::node_find_parent_call;
use crate::treesitter::node_find_string;
use crate::treesitter::ExtractOperatorType;
use crate::treesitter::NamespaceOperatorType;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;

#[derive(Clone, Debug)]
pub(crate) struct SessionBridge {
    source: SessionBridgeSource,
    session: BridgeSession,
    timeout: Duration,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SessionBridgeDebugInfo {
    source_kind: String,
    status_file: Option<PathBuf>,
    host: Option<String>,
    port: Option<u16>,
    tmux_socket: String,
    tmux_session: String,
    tmux_pane: String,
    timeout_ms: u64,
}

#[derive(Clone, Debug)]
enum SessionBridgeSource {
    Fixed(SessionBridgeConnection),
    StatusFile(StatusFileSessionBridgeSource),
}

#[derive(Clone, Debug, Eq, PartialEq)]
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
    pub tmux_socket: String,
    pub tmux_session: String,
    pub tmux_pane: String,
    pub timeout_ms: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HelpReference {
    pub label: String,
    pub topic: String,
    #[serde(default)]
    pub package: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HelpPage {
    pub text: String,
    #[serde(default)]
    pub references: Vec<HelpReference>,
}

#[derive(Clone, Debug, Serialize)]
struct InspectRequest {
    request_id: String,
    auth_token: String,
    expr: String,
    session: BridgeSession,
    #[serde(skip_serializing_if = "Option::is_none")]
    options: Option<InspectOptions>,
}

#[derive(Clone, Debug, Default, Serialize)]
struct InspectOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    accessor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    include_member_stats: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_members: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    member_name_filter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    member_name_prefix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_profile: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct BridgeSession {
    tmux_socket: String,
    tmux_session: String,
    tmux_pane: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct InspectResponse {
    #[serde(default)]
    error: Option<BridgeError>,
    #[serde(default)]
    object_meta: Option<ObjectMeta>,
    #[serde(default)]
    members: Vec<BridgeMember>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct BridgeError {
    #[serde(default)]
    code: String,
    #[serde(default)]
    message: String,
}

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

#[derive(Clone, Debug, Default, Deserialize)]
struct ObjectMeta {
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    class: Vec<String>,
    #[serde(default)]
    length: usize,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    r#type: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct BridgeMember {
    #[serde(default)]
    insert_text: String,
    #[serde(default)]
    name_display: String,
    #[serde(default)]
    name_raw: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    r#type: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct SessionStatusPayload {
    #[serde(default)]
    status: String,
    #[serde(default)]
    port: Option<u16>,
    #[serde(default)]
    auth_token: String,
    #[serde(default)]
    repl_seq: Option<u64>,
    #[serde(default)]
    bootstrap: Option<StatusBootstrapPayload>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct StatusBootstrapPayload {
    #[serde(default)]
    repl_seq: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    search_path_symbols: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    library_paths: Vec<String>,
    #[serde(default)]
    total_ms: Option<u64>,
    #[serde(default)]
    search_path_symbols_ms: Option<u64>,
    #[serde(default)]
    library_paths_ms: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
struct BootstrapRequest {
    request_id: String,
    auth_token: String,
    command: String,
    session: BridgeSession,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct BootstrapResponse {
    #[serde(default)]
    error: Option<BridgeError>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    search_path_symbols: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    library_paths: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
struct HelpTextRequest {
    request_id: String,
    auth_token: String,
    command: String,
    topic: String,
    session: BridgeSession,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct HelpTextResponse {
    #[serde(default)]
    error: Option<BridgeError>,
    #[serde(default)]
    found: bool,
    #[serde(default)]
    text: String,
    #[serde(default)]
    references: Vec<HelpReference>,
}

#[derive(Clone, Debug)]
struct CallContext {
    active_argument: Option<String>,
    explicit_parameters: Vec<String>,
    num_unnamed_arguments: usize,
    callee: String,
}

#[derive(Clone, Copy)]
enum PackageCompletionMode {
    String,
    BareSymbol,
}

#[derive(Clone, Copy)]
struct PackageArgumentSpec {
    callee: &'static str,
    named_argument: &'static str,
    allow_bare_symbol: bool,
}

const PACKAGE_ARGUMENT_SPECS: &[PackageArgumentSpec] = &[
    PackageArgumentSpec {
        callee: "library",
        named_argument: "package",
        allow_bare_symbol: true,
    },
    PackageArgumentSpec {
        callee: "require",
        named_argument: "package",
        allow_bare_symbol: true,
    },
    PackageArgumentSpec {
        callee: "requireNamespace",
        named_argument: "package",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "loadNamespace",
        named_argument: "package",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "getNamespace",
        named_argument: "name",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "asNamespace",
        named_argument: "ns",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "unloadNamespace",
        named_argument: "ns",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "find.package",
        named_argument: "package",
        allow_bare_symbol: false,
    },
    PackageArgumentSpec {
        callee: "packageVersion",
        named_argument: "pkg",
        allow_bare_symbol: false,
    },
];

#[derive(Clone, Debug, PartialEq)]
struct CallArgument {
    name: Option<String>,
    value_expr: String,
}

#[derive(Clone, Copy, Debug)]
enum CompletionFlavor {
    Argument,
    ComparisonString,
    Extractor,
    Namespace,
    Package,
    Pipe,
    Subset,
    Symbol,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SubsetCompletionKind {
    Subset,
    Subset2,
    StringSubset,
    StringSubset2,
}

#[derive(Clone, Debug)]
struct CompletionRequest {
    expr: String,
    flavor: CompletionFlavor,
    prefix: Option<String>,
    accessor: Option<String>,
    close_string: bool,
    quote_insert: bool,
    subset_kind: Option<SubsetCompletionKind>,
}

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
            tmux_socket: self.session.tmux_socket.clone(),
            tmux_session: self.session.tmux_session.clone(),
            tmux_pane: self.session.tmux_pane.clone(),
            timeout_ms: self.timeout.as_millis().min(u128::from(u64::MAX)) as u64,
        }
    }

    pub(crate) fn new(config: SessionBridgeConfig) -> anyhow::Result<Self> {
        let session = BridgeSession {
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
        })
    }

    pub(crate) fn completion_items(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<SessionBridgeCompletion>> {
        let Some(plan) = self.completion_plan(context)? else {
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
        };

        Ok(Some(SessionBridgeCompletion {
            merge_static,
            items,
        }))
    }

    pub(crate) fn bootstrap(&self) -> anyhow::Result<SessionBootstrap> {
        match self.bootstrap_via_command() {
            Ok(bootstrap) => Ok(bootstrap),
            Err(err)
                if is_bridge_unavailable(&err) ||
                    is_ipc_auth_error(&err) ||
                    err.downcast_ref::<std::io::Error>().is_some() =>
            {
                Err(err)
            },
            Err(err) => {
                log::warn!(
                    "Detached bootstrap command failed, falling back to legacy bootstrap: {err:?}"
                );
                self.bootstrap_legacy()
            },
        }
    }

    pub(crate) fn hover(&self, context: &DocumentContext) -> anyhow::Result<Option<Hover>> {
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

    pub(crate) fn resolve_completion_item(
        &self,
        mut item: CompletionItem,
    ) -> anyhow::Result<CompletionItem> {
        let Some(data) = item.data.clone() else {
            return Ok(item);
        };

        let Ok(data) = serde_json::from_value::<BridgeCompletionData>(data) else {
            return Ok(item);
        };

        if data.kind != "session_bridge_inspect" {
            return Ok(item);
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

            return Ok(item);
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

        Ok(item)
    }

    fn completion_plan(&self, context: &DocumentContext) -> anyhow::Result<Option<CompletionPlan>> {
        if context.is_empty_assignment_rhs() {
            return Ok(None);
        }

        if let Some(request) = completion_request_from_extractor(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_namespace(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_comparison_string(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_package_string(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_custom_call(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_argument_string(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_string_subset(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_subset(context)? {
            let call_request = completion_request_from_call(context)?;

            if call_request.is_some() {
                let mut requests = vec![request];
                requests.extend(call_request);

                if let Some(search_path) = completion_request_from_search_path(context)? {
                    requests.push(search_path);
                }

                return Ok(Some(CompletionPlan::Composite(requests)));
            }

            if request.prefix.is_some() {
                let mut requests = vec![request];

                if let Some(search_path) = completion_request_from_search_path(context)? {
                    requests.push(search_path);
                }

                return Ok(Some(CompletionPlan::Composite(requests)));
            }

            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_package_call(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_explicit_pipe_root(context)? {
            if let Some(search_path) = completion_request_from_search_path(context)? {
                return Ok(Some(CompletionPlan::Composite(vec![request, search_path])));
            }

            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = self.completion_request_from_data_context(context)? {
            if let Some(search_path) = completion_request_from_search_path(context)? {
                return Ok(Some(CompletionPlan::Composite(vec![request, search_path])));
            }

            return Ok(Some(CompletionPlan::Unique(request)));
        }

        let mut requests = Vec::new();

        if let Some(request) = completion_request_from_call(context)? {
            requests.push(request);
        }
        if let Some(request) = completion_request_from_pipe(context)? {
            requests.push(request);
        }
        if let Some(request) = completion_request_from_search_path(context)? {
            requests.push(request);
        }

        if requests.is_empty() {
            Ok(None)
        } else {
            Ok(Some(CompletionPlan::Composite(requests)))
        }
    }

    fn completion_request_from_data_context(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<CompletionRequest>> {
        if !context.explicit_completion_request {
            return Ok(None);
        }

        if argument_prefix(context)?.is_some() {
            return Ok(None);
        }

        let prefix = symbol_prefix(context)?;
        let Some(mut call_node) = node_find_containing_call(context.node) else {
            return Ok(None);
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

    fn data_completion_expr_for_call(
        &self,
        context: &DocumentContext,
        call_node: &Node,
        pipe_root_expr: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
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
        if payload.members.is_empty() {
            return Ok(vec![]);
        }

        let object_meta = payload.object_meta.as_ref();

        Ok(payload
            .members
            .into_iter()
            .enumerate()
            .map(|(index, member)| completion_item(member, request, object_meta, index))
            .collect())
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

    fn bootstrap_legacy(&self) -> anyhow::Result<SessionBootstrap> {
        let total_start = std::time::Instant::now();
        let search_path_start = std::time::Instant::now();
        let search_path_symbols = self.inspect_names(search_path_completion_expr().as_str())?;
        let search_path_symbols_ms = duration_ms(search_path_start.elapsed());
        let library_paths_start = std::time::Instant::now();
        let library_paths = match self.inspect_names(library_paths_completion_expr().as_str()) {
            Ok(paths) => paths.into_iter().map(PathBuf::from).collect::<Vec<_>>(),
            Err(err) => {
                log::warn!("Detached bootstrap couldn't inspect library paths: {err:?}");
                Vec::new()
            },
        };

        Ok(SessionBootstrap {
            search_path_symbols,
            installed_packages: Vec::new(),
            library_paths,
            timings: SessionBootstrapTimings {
                total_ms: duration_ms(total_start.elapsed()),
                search_path_symbols_ms,
                library_paths_ms: duration_ms(library_paths_start.elapsed()),
            },
        })
    }

    fn bootstrap_dynamic(
        &self,
        source: &StatusFileSessionBridgeSource,
    ) -> anyhow::Result<SessionBootstrap> {
        let status_path = source.status_file.as_path();
        let (_, status) = read_session_status(status_path)?;
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
        let mut stream = TcpStream::connect((connection.host.as_str(), connection.port))?;
        stream.set_read_timeout(Some(self.timeout))?;
        stream.set_write_timeout(Some(self.timeout))?;

        let request = InspectRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            expr: String::from(expr),
            session: self.session.clone(),
            options,
        };

        let payload = serde_json::to_vec(&request)?;
        stream.write_all(payload.as_slice())?;
        stream.write_all(b"\n")?;
        stream.shutdown(Shutdown::Write)?;

        let mut response = String::new();
        stream.read_to_string(&mut response)?;

        let payload: InspectResponse = serde_json::from_str(response.as_str())?;
        if let Some(error) = payload.error.as_ref() {
            return Err(SessionBridgeResponseError {
                code: error.code.clone(),
                message: error.message.clone(),
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
        let mut stream = TcpStream::connect((connection.host.as_str(), connection.port))?;
        stream.set_read_timeout(Some(self.timeout))?;
        stream.set_write_timeout(Some(self.timeout))?;

        let request = BootstrapRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            command: String::from("bootstrap"),
            session: self.session.clone(),
        };

        let payload = serde_json::to_vec(&request)?;
        stream.write_all(payload.as_slice())?;
        stream.write_all(b"\n")?;
        stream.shutdown(Shutdown::Write)?;

        let mut response = String::new();
        stream.read_to_string(&mut response)?;

        let payload: BootstrapResponse = serde_json::from_str(response.as_str())?;
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
        let mut stream = TcpStream::connect((connection.host.as_str(), connection.port))?;
        stream.set_read_timeout(Some(self.timeout))?;
        stream.set_write_timeout(Some(self.timeout))?;

        let request = HelpTextRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: connection.auth_token.clone(),
            command: String::from("help_text"),
            topic: String::from(topic),
            session: self.session.clone(),
        };

        let payload = serde_json::to_vec(&request)?;
        stream.write_all(payload.as_slice())?;
        stream.write_all(b"\n")?;
        stream.shutdown(Shutdown::Write)?;

        let mut response = String::new();
        stream.read_to_string(&mut response)?;

        let payload: HelpTextResponse = serde_json::from_str(response.as_str())?;
        if let Some(error) = payload.error.as_ref() {
            return Err(SessionBridgeResponseError {
                code: error.code.clone(),
                message: error.message.clone(),
            }
            .into());
        }

        Ok(payload)
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
        let mut connection = source.current_connection()?;
        let max_attempts = 3;

        for attempt in 0..max_attempts {
            match request(&connection) {
                Ok(payload) => return Ok(payload),
                Err(err) if should_retry_dynamic_request(&err) => {
                    let retry_io = err.downcast_ref::<std::io::Error>().is_some();
                    let refreshed = source.refresh_connection()?;

                    if refreshed != connection {
                        connection = refreshed;
                        continue;
                    }

                    if retry_io && attempt + 1 < max_attempts {
                        if attempt > 0 {
                            std::thread::sleep(Duration::from_millis(15));
                        }
                        continue;
                    }

                    return if retry_io {
                        Err(unavailable_from_io_error(err))
                    } else {
                        Err(err)
                    };
                },
                Err(err) => return Err(err),
            }
        }

        Err(SessionBridgeUnavailableError {
            message: String::from(exhausted_message),
        }
        .into())
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

fn bootstrap_from_status(
    status_file: &Path,
    status: &SessionStatusPayload,
) -> Option<SessionBootstrap> {
    if status.status != "ready" {
        return None;
    }

    let bootstrap = status.bootstrap.as_ref()?;
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

    Some(SessionBootstrap {
        search_path_symbols: bootstrap.search_path_symbols.clone(),
        installed_packages: Vec::new(),
        library_paths: bootstrap
            .library_paths
            .iter()
            .map(PathBuf::from)
            .collect::<Vec<_>>(),
        timings: SessionBootstrapTimings {
            total_ms: bootstrap.total_ms.unwrap_or(0),
            search_path_symbols_ms: bootstrap.search_path_symbols_ms.unwrap_or(0),
            library_paths_ms: bootstrap.library_paths_ms.unwrap_or(0),
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
        .is_some()
}

fn should_retry_dynamic_request(err: &anyhow::Error) -> bool {
    is_ipc_auth_error(err) || err.downcast_ref::<std::io::Error>().is_some()
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

fn unavailable_from_io_error(err: anyhow::Error) -> anyhow::Error {
    let message = err
        .downcast_ref::<std::io::Error>()
        .map(|err| err.to_string())
        .unwrap_or_else(|| err.to_string());

    SessionBridgeUnavailableError {
        message: format!("bridge connection failed: {message}"),
    }
    .into()
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
    if !path.exists() {
        return Err(SessionBridgeUnavailableError {
            message: format!(
                "startup status file '{}' does not exist yet",
                path.display()
            ),
        }
        .into());
    }

    let metadata = std::fs::metadata(path)?;
    if !status_file_trusted_metadata(&metadata)? {
        return Err(SessionBridgeUnavailableError {
            message: format!("startup status file '{}' is not trusted", path.display()),
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
        CompletionFlavor::Symbol => member.name_raw.clone(),
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
        CompletionFlavor::Pipe => CompletionItemKind::VARIABLE,
        CompletionFlavor::Subset => CompletionItemKind::VARIABLE,
        CompletionFlavor::Symbol => CompletionItemKind::VARIABLE,
    };

    CompletionItem {
        label: member.name_display.clone(),
        detail: if member.r#type.is_empty() || member.r#type == "unknown" {
            None
        } else {
            Some(member.r#type.clone())
        },
        documentation: if member.summary.is_empty() {
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
        CompletionFlavor::Namespace | CompletionFlavor::Package => None,
    }
}

#[derive(Clone, Debug)]
enum CompletionPlan {
    Unique(CompletionRequest),
    Composite(Vec<CompletionRequest>),
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

fn completion_request_from_extractor(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let node = context.node;
    let Some(parent) = node.parent() else {
        return Ok(None);
    };

    let operator = extract_operator_node(node, parent).or_else(|| {
        if !matches!(parent.node_type(), NodeType::ExtractOperator(_)) {
            return None;
        }

        if parent.child_by_field_name("lhs") != Some(node) {
            return None;
        }

        if parent.end_position() != context.point {
            return None;
        }

        Some(parent)
    });

    let Some(operator) = operator else {
        return Ok(completion_request_from_extractor_text(context));
    };

    let Some(lhs) = operator.child_by_field_name("lhs") else {
        return Ok(None);
    };

    let expr = lhs.node_to_string(context.document.contents.as_str())?;
    let prefix = operator
        .child_by_field_name("rhs")
        .map(|rhs| rhs.node_to_string(context.document.contents.as_str()))
        .transpose()?;

    let accessor = match operator.node_type() {
        NodeType::ExtractOperator(ExtractOperatorType::At) => Some(String::from("@")),
        NodeType::ExtractOperator(ExtractOperatorType::Dollar) => Some(String::from("$")),
        _ => None,
    };

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Extractor,
        prefix,
        accessor,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_extractor_text(context: &DocumentContext) -> Option<CompletionRequest> {
    static EXTRACTOR_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*(?P<accessor>\$|@)(?P<prefix>[A-Za-z0-9._]*)$"#,
        )
        .unwrap()
    });

    let trigger = context.trigger.as_deref()?;
    if !matches!(trigger, "$" | "@") {
        return None;
    }

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = EXTRACTOR_RE.captures(prefix.as_str())?;
    let accessor = captures.name("accessor")?.as_str();

    if accessor != trigger {
        return None;
    }

    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Extractor,
        prefix: capture_prefix(&captures, "prefix"),
        accessor: Some(accessor.to_string()),
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    })
}

fn completion_request_from_namespace(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let node = context.node;

    if node.node_type() == NodeType::Identifier {
        let Some(parent) = node.parent() else {
            return Ok(None);
        };

        if parent.is_namespace_operator() && parent.child_by_field_name("lhs") == Some(node) {
            return Ok(Some(CompletionRequest {
                expr: installed_packages_completion_expr(),
                flavor: CompletionFlavor::Package,
                prefix: Some(node.node_to_string(context.document.contents.as_str())?),
                accessor: None,
                close_string: false,
                quote_insert: false,
                subset_kind: None,
            }));
        }
    }

    let operator = match node.node_type() {
        NodeType::Anonymous(kind) if matches!(kind.as_str(), "::" | ":::") => {
            namespace_operator_from_colons(node, context.point)
        },
        NodeType::Identifier => namespace_operator_from_identifier(node),
        _ => None,
    };

    let Some(operator) = operator else {
        return Ok(None);
    };

    let Some(lhs) = operator.child_by_field_name("lhs") else {
        return Ok(None);
    };

    let package = lhs.node_to_string(context.document.contents.as_str())?;
    let prefix = operator
        .child_by_field_name("rhs")
        .map(|rhs| rhs.node_to_string(context.document.contents.as_str()))
        .transpose()?;

    let expr = namespace_completion_expr(
        package.as_str(),
        matches!(
            operator.node_type(),
            NodeType::NamespaceOperator(NamespaceOperatorType::External)
        ),
    );

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Namespace,
        prefix,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_string_subset(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(string_node) = node_find_string(&context.node) else {
        return Ok(completion_request_from_string_subset_text(context));
    };

    let Some((object_node, subset_kind)) = find_string_subset_object(&string_node, context) else {
        return Ok(completion_request_from_string_subset_text(context));
    };

    let expr = object_node.node_to_string(context.document.contents.as_str())?;

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Subset,
        prefix: None,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: Some(subset_kind),
    }))
}

fn completion_request_from_subset(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let text_request = completion_request_from_subset_text(context);
    let Some((subset_node, subset_kind)) = find_subset_node(context) else {
        return Ok(text_request);
    };

    let Some(object_node) = subset_node.child_by_field_name("function") else {
        return Ok(None);
    };

    let expr = object_node.node_to_string(context.document.contents.as_str())?;
    let request = CompletionRequest {
        expr,
        flavor: CompletionFlavor::Subset,
        prefix: symbol_prefix(context)?,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: Some(subset_kind),
    };

    let Some(text_request) = text_request else {
        return Ok(Some(request));
    };

    if request.expr != text_request.expr || request.prefix != text_request.prefix {
        return Ok(Some(text_request));
    }

    Ok(Some(request))
}

fn completion_request_from_comparison_string(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };
    let prefix = line.chars().take(context.point.column).collect::<String>();

    if let Some((expr, value_prefix)) = comparison_string_data_table_expr(prefix.as_str()) {
        return Ok(Some(CompletionRequest {
            expr,
            flavor: CompletionFlavor::ComparisonString,
            prefix: Some(value_prefix),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        }));
    }

    if let Some((expr, value_prefix)) = comparison_string_expr(prefix.as_str()) {
        return Ok(Some(CompletionRequest {
            expr,
            flavor: CompletionFlavor::ComparisonString,
            prefix: Some(value_prefix),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        }));
    }

    Ok(None)
}

fn completion_request_from_package_string(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(string_node) = node_find_string(&context.node) else {
        return Ok(completion_request_from_package_string_text(context));
    };

    let Some(call) = analyze_call_context(context)? else {
        return Ok(completion_request_from_package_string_text(context));
    };

    if !call_matches_package_argument(&call, PackageCompletionMode::String) {
        return Ok(completion_request_from_package_string_text(context));
    }

    let prefix = string_prefix(&string_node, context)?;
    if prefix.is_none() && context.trigger.is_none() {
        return Ok(None);
    }

    Ok(Some(CompletionRequest {
        expr: installed_packages_completion_expr(),
        flavor: CompletionFlavor::Package,
        prefix,
        accessor: None,
        close_string: true,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_package_string_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
    static PACKAGE_STRING_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            ^\s*
            (?:(?:[A-Za-z.][A-Za-z0-9._]*)(?:::|:::))?
            (?P<callee>
                library |
                require |
                requireNamespace |
                loadNamespace |
                getNamespace |
                asNamespace |
                unloadNamespace |
                find\.package |
                packageVersion
            )
            \s*\(\s*
            (?:(?P<argument>[A-Za-z.][A-Za-z0-9._]*)\s*=\s*)?
            "(?P<prefix>[^"]*)$
            "#,
        )
        .unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = PACKAGE_STRING_RE.captures(prefix.as_str())?;
    let callee = captures.name("callee")?.as_str();
    let argument = captures.name("argument").map(|capture| capture.as_str());

    if !text_matches_package_argument(callee, argument, PackageCompletionMode::String) {
        return None;
    }

    Some(CompletionRequest {
        expr: installed_packages_completion_expr(),
        flavor: CompletionFlavor::Package,
        prefix: captures
            .name("prefix")
            .map(|capture| capture.as_str().to_string()),
        accessor: None,
        close_string: true,
        quote_insert: false,
        subset_kind: None,
    })
}

fn completion_request_from_argument_string(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(string_node) = node_find_string(&context.node) else {
        return Ok(completion_request_from_argument_string_text(context));
    };

    let Some(call) = analyze_call_context(context)? else {
        return Ok(completion_request_from_argument_string_text(context));
    };

    let Some(formal_name) = call.active_argument.as_deref() else {
        return Ok(completion_request_from_argument_string_text(context));
    };

    let prefix = string_prefix(&string_node, context)?;
    if prefix.is_none() && context.trigger.is_none() {
        return Ok(None);
    }

    Ok(Some(CompletionRequest {
        expr: literal_character_choices_completion_expr(call.callee.as_str(), formal_name),
        flavor: CompletionFlavor::ComparisonString,
        prefix,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_argument_string_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
    static ARGUMENT_STRING_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            ^\s*
            (?P<callee>
                [A-Za-z.][A-Za-z0-9._]*
                (?:
                    :{2,3}[A-Za-z.][A-Za-z0-9._]*
                )?
            )
            \s*\(
            .*?
            (?:^|,)\s*
            (?P<formal>[A-Za-z.][A-Za-z0-9._]*)\s*=\s*"(?P<prefix>[^"]*)$
            "#,
        )
        .unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = ARGUMENT_STRING_RE.captures(prefix.as_str())?;

    Some(CompletionRequest {
        expr: literal_character_choices_completion_expr(
            captures.name("callee")?.as_str(),
            captures.name("formal")?.as_str(),
        ),
        flavor: CompletionFlavor::ComparisonString,
        prefix: captures
            .name("prefix")
            .map(|capture| capture.as_str().to_string()),
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    })
}

fn completion_request_from_custom_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };

    let in_string = node_find_string(&context.node).is_some();
    let position = call_node_position_type(&context.node, context.point);

    match call.callee.as_str() {
        "Sys.getenv" | "Sys.unsetenv" | "getOption" => {
            if !custom_string_call_target(&call, position, in_string) {
                return Ok(None);
            }

            let prefix = if let Some(string_node) = node_find_string(&context.node) {
                string_prefix(&string_node, context)?
            } else {
                symbol_prefix(context)?
            };

            if prefix.is_none() && context.trigger.is_none() {
                return Ok(None);
            }

            let expr = match call.callee.as_str() {
                "getOption" => option_names_completion_expr(),
                _ => env_names_completion_expr(),
            };

            Ok(Some(CompletionRequest {
                expr,
                flavor: CompletionFlavor::ComparisonString,
                prefix,
                accessor: None,
                close_string: in_string,
                quote_insert: !in_string,
                subset_kind: None,
            }))
        },
        "options" | "Sys.setenv" => {
            if !custom_argument_call_target(position) {
                return Ok(None);
            }

            let prefix = symbol_prefix(context)?;
            if prefix.is_none() && context.trigger.is_none() {
                return Ok(None);
            }

            let expr = match call.callee.as_str() {
                "options" => option_names_completion_expr(),
                _ => env_names_completion_expr(),
            };

            Ok(Some(CompletionRequest {
                expr,
                flavor: CompletionFlavor::Argument,
                prefix,
                accessor: Some(String::from("arg")),
                close_string: false,
                quote_insert: false,
                subset_kind: None,
            }))
        },
        _ => Ok(None),
    }
}

fn custom_string_call_target(
    call: &CallContext,
    position: CallNodePositionType,
    in_string: bool,
) -> bool {
    if let Some(active_argument) = call.active_argument.as_deref() {
        return active_argument == "x";
    }

    if call.num_unnamed_arguments > 0 {
        return false;
    }

    if in_string {
        return true;
    }

    matches!(
        position,
        CallNodePositionType::Name | CallNodePositionType::Ambiguous
    )
}

fn custom_argument_call_target(position: CallNodePositionType) -> bool {
    matches!(
        position,
        CallNodePositionType::Name | CallNodePositionType::Ambiguous
    )
}

fn completion_request_from_string_subset_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
    static STRING_SUBSET2_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\[\s*"(?P<prefix>[^"]*)$"#).unwrap()
    });
    static STRING_SUBSET_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\s*(?:[^,\]]*,\s*(?:c\s*\(\s*)?)?"(?P<prefix>[^"]*)$"#,
        )
        .unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();

    if let Some(captures) = STRING_SUBSET2_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: None,
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::StringSubset2),
        });
    }

    let captures = STRING_SUBSET_RE.captures(prefix.as_str())?;
    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Subset,
        prefix: None,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: Some(SubsetCompletionKind::StringSubset),
    })
}

fn completion_request_from_subset_text(context: &DocumentContext) -> Option<CompletionRequest> {
    static SUBSET2_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\[\s*(?P<prefix>[A-Za-z0-9._]*)$"#)
            .unwrap()
    });
    static SUBSET_DOT_CALL_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\s*[^,\]]*,\s*\.\(\s*(?P<prefix>[A-Za-z0-9._]*)$"#,
        )
        .unwrap()
    });
    static SUBSET_C_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\s*[^,\]]*,\s*c\s*\(\s*(?P<prefix>[A-Za-z0-9._]*)$"#,
        )
        .unwrap()
    });
    static SUBSET_J_NESTED_CALL_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*
            \[
            \s*[^,\]]*,\s*
            (?:\.\(|list\s*\()
            .*?(?:\(|,)\s*(?P<prefix>[A-Za-z0-9._]*)$
            "#,
        )
        .unwrap()
    });
    static SUBSET_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\s*(?P<prefix>[A-Za-z0-9._]*)$"#)
            .unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();

    if let Some(captures) = SUBSET2_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::Subset2),
        });
    }

    if let Some(captures) = SUBSET_DOT_CALL_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::Subset),
        });
    }

    if let Some(captures) = SUBSET_C_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::Subset),
        });
    }

    if let Some(captures) = SUBSET_J_NESTED_CALL_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::Subset),
        });
    }

    let captures = SUBSET_RE.captures(prefix.as_str())?;
    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Subset,
        prefix: capture_prefix(&captures, "prefix"),
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: Some(SubsetCompletionKind::Subset),
    })
}

fn capture_prefix(captures: &regex::Captures, name: &str) -> Option<String> {
    captures
        .name(name)
        .map(|capture| capture.as_str())
        .filter(|prefix| !prefix.is_empty())
        .map(String::from)
}

fn completion_request_from_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };
    if call.callee == "." {
        return Ok(None);
    }

    let prefix = argument_prefix(context)?;

    Ok(Some(CompletionRequest {
        expr: call.callee,
        flavor: CompletionFlavor::Argument,
        prefix,
        accessor: Some(String::from("arg")),
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_pipe(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call_node) = node_find_containing_call(context.node) else {
        return Ok(completion_request_from_pipe_text(context));
    };

    let Some(expr) = find_pipe_root_name(context, &call_node)? else {
        return Ok(completion_request_from_pipe_text(context));
    };

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Pipe,
        prefix: symbol_prefix(context)?,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_pipe_text(context: &DocumentContext) -> Option<CompletionRequest> {
    static PIPE_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)^\s*(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*(?:\|>|%>%).*[,(]\s*(?P<prefix>[A-Za-z0-9._]*)$"#,
        )
        .unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = PIPE_RE.captures(prefix.as_str())?;

    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Pipe,
        prefix: capture_prefix(&captures, "prefix"),
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    })
}

fn completion_request_from_package_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };

    if !call_matches_package_argument(&call, PackageCompletionMode::BareSymbol) {
        return Ok(None);
    }

    let prefix = symbol_prefix(context)?;
    if prefix.is_none() && context.trigger.is_none() {
        return Ok(None);
    }

    Ok(Some(CompletionRequest {
        expr: installed_packages_completion_expr(),
        flavor: CompletionFlavor::Package,
        prefix,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_search_path(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let prefix = symbol_prefix(context)?;
    if prefix.is_none() {
        match context.trigger.as_deref() {
            None | Some(" ") => return Ok(None),
            _ => {},
        }
    }

    Ok(Some(CompletionRequest {
        expr: search_path_completion_expr(),
        flavor: CompletionFlavor::Symbol,
        prefix,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

fn completion_request_from_explicit_pipe_root(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    if !context.explicit_completion_request {
        return Ok(None);
    }

    let prefix = symbol_prefix(context)?;
    let expr = completion_request_from_pipe(context)?
        .map(|request| request.expr)
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

fn analyze_call_context(context: &DocumentContext) -> anyhow::Result<Option<CallContext>> {
    let ast = &context.document.ast;
    let Some(mut node) = ast.root_node().find_closest_node_to_point(context.point) else {
        return Ok(None);
    };

    if node.node_type() == NodeType::Comma && node.start_position().is_before(context.point) {
        if let Some(sibling) = node.next_sibling() {
            node = sibling;
        }
    }

    if node.node_type() == NodeType::Anonymous(String::from(")")) {
        if let Some(sibling) = node.prev_sibling() {
            node = sibling;
        }
    }

    let mut parent = match node.parent() {
        Some(parent) => parent,
        None => return Ok(None),
    };

    let mut explicit_parameters = vec![];
    let mut num_unnamed_arguments = 0usize;
    let mut active_argument = None;
    let mut found_child = false;

    let call = loop {
        if parent.node_type() == NodeType::Arguments {
            if let Some(name) = node.child_by_field_name("name") {
                active_argument = Some(name.node_to_string(context.document.contents.as_str())?);
            }

            for child in NodeExt::children_of(parent) {
                if let Some(name) = child.child_by_field_name("name") {
                    explicit_parameters
                        .push(name.node_to_string(context.document.contents.as_str())?);
                    num_unnamed_arguments = num_unnamed_arguments.saturating_sub(1);
                }

                if !found_child && child.node_type() == NodeType::Comma {
                    num_unnamed_arguments += 1;
                }

                if child == node {
                    found_child = true;
                }
            }
        }

        if parent.is_call() {
            break parent;
        }

        node = parent;
        parent = match node.parent() {
            Some(parent) => parent,
            None => return Ok(None),
        };
    };

    if !is_within_call_parentheses(&context.point, &call) {
        return Ok(None);
    }

    let Some(callee) = call.child(0) else {
        return Ok(None);
    };

    let callee = callee.node_to_string(context.document.contents.as_str())?;

    Ok(Some(CallContext {
        active_argument,
        explicit_parameters,
        num_unnamed_arguments,
        callee,
    }))
}

fn call_matches_package_argument(call: &CallContext, mode: PackageCompletionMode) -> bool {
    let Some(spec) = package_argument_spec(call.callee.as_str(), mode) else {
        return false;
    };

    match call.active_argument.as_deref() {
        Some(active_argument) => active_argument == spec.named_argument,
        None => call.num_unnamed_arguments == 0,
    }
}

fn text_matches_package_argument(
    callee: &str,
    argument: Option<&str>,
    mode: PackageCompletionMode,
) -> bool {
    let Some(spec) = package_argument_spec(callee, mode) else {
        return false;
    };

    match argument {
        Some(argument) => argument == spec.named_argument,
        None => true,
    }
}

fn package_argument_spec(
    callee: &str,
    mode: PackageCompletionMode,
) -> Option<&'static PackageArgumentSpec> {
    let callee = call_callee_basename(callee);

    PACKAGE_ARGUMENT_SPECS.iter().find(|spec| {
        spec.callee == callee
            && match mode {
                PackageCompletionMode::String => true,
                PackageCompletionMode::BareSymbol => spec.allow_bare_symbol,
            }
    })
}

fn call_callee_basename(callee: &str) -> &str {
    if let Some((_, basename)) = callee.rsplit_once(":::") {
        return basename;
    }

    if let Some((_, basename)) = callee.rsplit_once("::") {
        return basename;
    }

    callee
}

fn argument_prefix(context: &DocumentContext) -> anyhow::Result<Option<String>> {
    let node = context.node;
    if !node.is_identifier() {
        return Ok(None);
    }

    let Some(parent) = node.parent() else {
        return Ok(None);
    };

    let Some(name) = parent.child_by_field_name("name") else {
        return Ok(None);
    };

    if name != node {
        return Ok(None);
    }

    Ok(Some(
        node.node_to_string(context.document.contents.as_str())?,
    ))
}

fn next_enclosing_call<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    let mut current = node.parent()?;

    loop {
        if current.is_call() {
            return Some(current);
        }

        if current.is_braced_expression() {
            return None;
        }

        current = current.parent()?;
    }
}

fn call_arguments(contents: &str, call_node: &Node) -> anyhow::Result<Vec<CallArgument>> {
    let Some(arguments) = call_node.child_by_field_name("arguments") else {
        return Ok(vec![]);
    };

    let mut cursor = arguments.walk();
    let mut values = Vec::new();

    for argument in arguments.children_by_field_name("argument", &mut cursor) {
        let value = match argument.child_by_field_name("value") {
            Some(value) => value,
            None => continue,
        };

        let name = argument
            .child_by_field_name("name")
            .map(|name| name.node_to_string(contents))
            .transpose()?;

        values.push(CallArgument {
            name,
            value_expr: value.node_to_string(contents)?,
        });
    }

    Ok(values)
}

#[cfg(test)]
fn resolve_active_formal_name(formals: &[String], call: &CallContext) -> Option<String> {
    if let Some(active) = call.active_argument.clone() {
        return Some(active);
    }

    let mut remaining = call.num_unnamed_arguments;

    for formal in formals {
        if call.explicit_parameters.contains(formal) {
            continue;
        }

        if remaining > 0 {
            remaining -= 1;
            continue;
        }

        return Some(formal.clone());
    }

    None
}

fn resolve_bound_argument_expr(
    formals: &[String],
    arguments: &[CallArgument],
    formal_name: &str,
) -> Option<String> {
    if let Some(argument) = arguments
        .iter()
        .find(|argument| argument.name.as_deref() == Some(formal_name))
    {
        return Some(argument.value_expr.clone());
    }

    let mut unnamed = arguments.iter().filter(|argument| argument.name.is_none());

    for formal in formals {
        if arguments
            .iter()
            .any(|argument| argument.name.as_deref() == Some(formal.as_str()))
        {
            continue;
        }

        let argument = unnamed.next()?;
        if formal == formal_name {
            return Some(argument.value_expr.clone());
        }
    }

    None
}

fn symbol_prefix(context: &DocumentContext) -> anyhow::Result<Option<String>> {
    if context.node.is_identifier() {
        return Ok(Some(
            context
                .node
                .node_to_string(context.document.contents.as_str())?,
        ));
    }

    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };

    let prefix = line
        .chars()
        .take(context.point.column)
        .collect::<String>()
        .chars()
        .rev()
        .take_while(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.'))
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();

    if prefix.is_empty() {
        return Ok(None);
    }

    Ok(Some(prefix))
}

fn string_prefix(string_node: &Node, context: &DocumentContext) -> anyhow::Result<Option<String>> {
    let contents = string_node.node_to_string(context.document.contents.as_str())?;
    if contents.len() < 2 {
        return Ok(None);
    }

    let offset = context
        .point
        .column
        .saturating_sub(string_node.start_position().column)
        .min(contents.len());

    if offset <= 1 {
        return Ok(Some(String::new()));
    }

    let prefix = contents
        .chars()
        .skip(1)
        .take(offset.saturating_sub(1))
        .collect::<String>();

    Ok(Some(prefix))
}

fn comparison_string_expr(line_prefix: &str) -> Option<(String, String)> {
    static COMPARISON_STRING_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?P<expr>
                [A-Za-z.][A-Za-z0-9._]*
                (?:
                    \$[A-Za-z.][A-Za-z0-9._]*
                    |
                    \[\[\s*(?:"[^"]+"|'[^']+'|[A-Za-z.][A-Za-z0-9._]*)\s*\]\]
                )*
            )
            \s*(?:==|!=)\s*"(?P<prefix>[^"]*)$
            "#,
        )
        .unwrap()
    });

    let captures = COMPARISON_STRING_RE.captures(line_prefix)?;
    let expr = captures.name("expr")?.as_str();
    let value_prefix = captures.name("prefix")?.as_str();

    Some((
        comparison_values_completion_expr(expr),
        String::from(value_prefix),
    ))
}

fn comparison_string_data_table_expr(line_prefix: &str) -> Option<(String, String)> {
    static DATA_TABLE_COMPARISON_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?P<table>[A-Za-z.][A-Za-z0-9._]*)\s*
            \[
            \s*(?P<column>[A-Za-z.][A-Za-z0-9._]*)\s*(?:==|!=)\s*"(?P<prefix>[^"]*)$
            "#,
        )
        .unwrap()
    });

    let captures = DATA_TABLE_COMPARISON_RE.captures(line_prefix)?;
    let table = captures.name("table")?.as_str();
    let column = captures.name("column")?.as_str();
    let value_prefix = captures.name("prefix")?.as_str();

    let expr = format!("({})[[\"{}\"]]", table, escape_r_string(column),);

    Some((
        comparison_values_completion_expr(expr.as_str()),
        String::from(value_prefix),
    ))
}

fn find_string_subset_object<'tree>(
    string_node: &Node<'tree>,
    context: &DocumentContext,
) -> Option<(Node<'tree>, SubsetCompletionKind)> {
    if !string_node.is_string() {
        return None;
    }

    let mut node = node_find_parent_call(string_node)?;

    if node.is_call() {
        if !node_is_c_call(&node, context.document.contents.as_str()) {
            return None;
        }

        node = node_find_parent_call(&node)?;
        if !node.is_subset() && !node.is_subset2() {
            return None;
        }
    }

    if !subset_contains_point(&context.point, &node) {
        return None;
    }

    let subset_kind = if node.is_subset2() {
        SubsetCompletionKind::StringSubset2
    } else {
        SubsetCompletionKind::StringSubset
    };

    let object = node.child_by_field_name("function")?;
    Some((object, subset_kind))
}

fn find_subset_node<'tree>(
    context: &'tree DocumentContext,
) -> Option<(Node<'tree>, SubsetCompletionKind)> {
    let mut node = context.node;

    loop {
        if node.is_subset() || node.is_subset2() {
            break;
        }

        if node.is_braced_expression() {
            return None;
        }

        node = node.parent()?;
    }

    if !subset_contains_point(&context.point, &node) {
        return None;
    }

    let subset_kind = if node.is_subset2() {
        SubsetCompletionKind::Subset2
    } else {
        SubsetCompletionKind::Subset
    };

    Some((node, subset_kind))
}

fn node_is_c_call(node: &Node, contents: &str) -> bool {
    if !node.is_call() {
        return false;
    }

    let Some(function) = node.child_by_field_name("function") else {
        return false;
    };

    if !function.is_identifier() {
        return false;
    }

    let Ok(text) = function.node_as_str(contents) else {
        return false;
    };

    text == "c"
}

fn subset_contains_point(point: &Point, subset_node: &Node) -> bool {
    let Some(arguments) = subset_node.child_by_field_name("arguments") else {
        return false;
    };

    let Some(open) = arguments.child_by_field_name("open") else {
        return false;
    };
    let Some(close) = arguments.child_by_field_name("close") else {
        return false;
    };

    point.is_after_or_equal(open.end_position()) && point.is_before_or_equal(close.start_position())
}

fn locate_bridge_hover_node<'tree>(context: &'tree DocumentContext) -> Option<Node<'tree>> {
    let root = context.document.ast.root_node();
    let mut node = root.find_closest_node_to_point(context.point)?;

    while !node.is_identifier() && !node.is_string() && !node.is_keyword() {
        if let Some(sibling) = node.prev_sibling() {
            node = sibling;
        } else if let Some(parent) = node.parent() {
            node = parent;
        } else {
            return None;
        }
    }

    match node.parent() {
        Some(parent) if matches!(parent.node_type(), NodeType::NamespaceOperator(_)) => {
            Some(parent)
        },
        Some(parent) if matches!(parent.node_type(), NodeType::ExtractOperator(_)) => Some(parent),
        Some(parent) if parent.is_call() => Some(node),
        Some(_) => Some(node),
        None => Some(node),
    }
}

fn extract_operator_node<'tree>(node: Node<'tree>, parent: Node<'tree>) -> Option<Node<'tree>> {
    if !matches!(parent.node_type(), NodeType::ExtractOperator(_)) {
        return None;
    }

    match node.node_type() {
        NodeType::Anonymous(operator) if matches!(operator.as_str(), "$" | "@") => Some(parent),
        NodeType::Identifier if parent.child_by_field_name("rhs") == Some(node) => Some(parent),
        _ => None,
    }
}

fn namespace_operator_from_colons<'tree>(node: Node<'tree>, point: Point) -> Option<Node<'tree>> {
    if node.end_position() != point {
        return None;
    }

    let parent = node.parent()?;
    if !matches!(parent.node_type(), NodeType::NamespaceOperator(_)) {
        return None;
    }

    Some(parent)
}

fn namespace_operator_from_identifier<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    let parent = node.parent()?;
    if !parent.is_namespace_operator() {
        return None;
    }

    if parent.child_by_field_name("lhs") == Some(node) {
        return None;
    }

    Some(parent)
}

fn namespace_completion_expr(package: &str, exports_only: bool) -> String {
    let package = package.replace('\\', "\\\\").replace('"', "\\\"");

    if exports_only {
        return format!(
            "local({{ .x <- getNamespaceExports(\"{package}\"); stats::setNames(vector(\"list\", length(.x)), .x) }})"
        );
    }

    format!("as.list(asNamespace(\"{package}\"), all.names = TRUE)")
}

fn signature_parameter_label(member: &BridgeMember) -> String {
    if member.summary.is_empty() || member.summary == "<required>" {
        return member.name_display.clone();
    }

    format!("{} = {}", member.name_display, member.summary)
}

fn search_path_completion_expr() -> String {
    String::from(
        "local({ .envs <- lapply(search(), as.environment); .names <- unique(unlist(lapply(.envs, ls, all.names = TRUE), use.names = FALSE)); stats::setNames(vector(\"list\", length(.names)), .names) })",
    )
}

fn matrix_subset_completion_expr(expr: &str) -> String {
    let expr = expr.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "local({{ .x <- tryCatch(colnames(({expr})), error = function(e) NULL); if (is.null(.x)) .x <- character(); stats::setNames(vector(\"list\", length(.x)), .x) }})"
    )
}

fn comparison_values_completion_expr(expr: &str) -> String {
    format!(
        "local({{ .x <- tryCatch(({expr}), error = function(e) NULL); if (is.null(.x)) {{ stats::setNames(list(), character()) }} else {{ .vals <- if (is.factor(.x)) {{ levels(.x) }} else if (is.character(.x)) {{ unique(.x) }} else {{ character() }}; .vals <- .vals[!is.na(.vals)]; .vals <- unique(as.character(.vals)); .vals <- utils::head(.vals, 200L); stats::setNames(vector(\"list\", length(.vals)), .vals) }} }})"
    )
}

fn installed_packages_completion_expr() -> String {
    String::from(
        "local({ .x <- base::.packages(all.available = TRUE); stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

fn option_names_completion_expr() -> String {
    String::from(
        "local({ .x <- names(options()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

fn env_names_completion_expr() -> String {
    String::from(
        "local({ .x <- names(Sys.getenv()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

fn call_formals_completion_expr(callee: &str) -> String {
    format!(
        "local({{ .x <- tryCatch(names(formals({callee})), error = function(e) character()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) }})"
    )
}

fn literal_character_choices_completion_expr(callee: &str, formal_name: &str) -> String {
    let formal_name = escape_r_string(formal_name);

    format!(
        "local({{ .f <- tryCatch(formals({callee}), error = function(e) NULL); if (is.null(.f)) {{ stats::setNames(list(), character()) }} else {{ .arg <- .f[[\"{formal_name}\"]]; .vals <- character(); if (is.character(.arg)) {{ .vals <- .arg }} else if (is.call(.arg) && length(.arg) >= 2L && identical(.arg[[1]], as.name(\"c\"))) {{ .elts <- as.list(.arg)[-1]; if (length(.elts) && all(vapply(.elts, function(x) is.character(x) && length(x) == 1L, logical(1)))) {{ .vals <- unlist(.elts, use.names = FALSE) }} }}; .vals <- .vals[!is.na(.vals)]; .vals <- unique(as.character(.vals)); stats::setNames(vector(\"list\", length(.vals)), .vals) }} }})"
    )
}

fn library_paths_completion_expr() -> String {
    String::from(
        "local({ .x <- base::.libPaths(); stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

fn browser_locals_completion_expr(prefix: &str) -> String {
    let prefix = escape_r_string(prefix);

    format!(
        "local({{ .prefix <- \"{prefix}\"; .frames <- sys.frames(); .target <- NULL; for (.env in .frames) {{ .names <- tryCatch(ls(envir = .env, all.names = TRUE), error = function(e) character()); if (length(.names) && any(startsWith(tolower(.names), tolower(.prefix)))) {{ .target <- .env; break }} }}; if (is.null(.target)) {{ stats::setNames(list(), character()) }} else {{ .names <- ls(envir = .target, all.names = TRUE); stats::setNames(vector(\"list\", length(.names)), .names) }} }})"
    )
}

fn pipe_root_text_expr(context: &DocumentContext) -> Option<String> {
    static PIPE_ROOT_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)^\s*(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*(?:\|>|%>%)"#).unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = PIPE_ROOT_RE.captures(prefix.as_str())?;

    Some(captures.name("expr")?.as_str().to_string())
}

fn escape_r_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn escape_r_double_quoted(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn subset_insert_text(
    name: &str,
    subset_kind: Option<SubsetCompletionKind>,
    classes: Option<&[String]>,
) -> String {
    let Some(subset_kind) = subset_kind else {
        return name.to_string();
    };

    match subset_kind {
        SubsetCompletionKind::StringSubset | SubsetCompletionKind::StringSubset2 => {
            escape_r_double_quoted(name)
        },
        SubsetCompletionKind::Subset2 => format!("\"{}\"", escape_r_double_quoted(name)),
        SubsetCompletionKind::Subset => {
            if is_data_table_like(classes) {
                sym_quote_invalid(name)
            } else {
                format!("\"{}\"", escape_r_double_quoted(name))
            }
        },
    }
}

fn is_data_table_like(classes: Option<&[String]>) -> bool {
    classes
        .into_iter()
        .flatten()
        .any(|class| class == "data.table")
}

fn is_matrix_like(object_meta: Option<&ObjectMeta>) -> bool {
    let Some(object_meta) = object_meta else {
        return false;
    };

    object_meta
        .class
        .iter()
        .any(|class| matches!(class.as_str(), "matrix" | "array"))
}

fn is_internal_browser_name(name: &str) -> bool {
    name.starts_with('.') || name.contains("rscope")
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

fn is_within_call_parentheses(point: &Point, node: &Node) -> bool {
    if node.node_type() != NodeType::Call {
        return false;
    }

    let Some(arguments) = node.child_by_field_name("arguments") else {
        return false;
    };
    let Some(open) = arguments.child_by_field_name("open") else {
        return false;
    };
    let Some(close) = arguments.child_by_field_name("close") else {
        return false;
    };

    point.is_after_or_equal(open.end_position()) && point.is_before_or_equal(close.start_position())
}

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::io::Write;
    use std::net::TcpListener;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;
    use std::sync::Arc;
    use std::thread;

    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::document::Document;

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
        let context = DocumentContext::new(&document, Point::new(0, 7), Some(String::from("$")));

        let request = completion_request_from_extractor(&context)
            .unwrap()
            .expect("expected extractor completion request");

        assert_eq!(request.expr, "mtcars");
        assert_eq!(request.accessor, Some(String::from("$")));
        assert_eq!(request.prefix, Some(String::from("mtcars")));
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
            tmux_socket: String::new(),
            tmux_session: String::new(),
            tmux_pane: String::new(),
            timeout_ms: 1000,
        })
        .unwrap();

        let plan = bridge
            .completion_plan(&context)
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

        let request = completion_request_from_custom_call(&context)
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

        let request = completion_request_from_custom_call(&context)
            .unwrap()
            .expect("expected custom completion request");

        assert!(matches!(request.flavor, CompletionFlavor::ComparisonString));
        assert_eq!(request.prefix, Some(String::from("PA")));
        assert!(!request.quote_insert);
        assert!(request.close_string);
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
    fn test_bootstrap_falls_back_to_legacy_on_bootstrap_command_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let connections = Arc::new(AtomicUsize::new(0));
        let connections_bg = connections.clone();

        let handle = thread::spawn(move || {
            for expected in ["bootstrap", "search_path", "library_paths"] {
                let (mut stream, _) = listener.accept().expect("expected bridge request");
                connections_bg.fetch_add(1, Ordering::SeqCst);
                let mut request = String::new();
                stream
                    .read_to_string(&mut request)
                    .expect("expected bridge request payload");

                match expected {
                    "bootstrap" => {
                        let payload: serde_json::Value = serde_json::from_str(request.trim())
                            .expect("expected bootstrap request");
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
                    },
                    "search_path" => {
                        stream
                            .write_all(
                                br#"{"members":[{"name_raw":"library"},{"name_raw":"mtcars"}]}"#,
                            )
                            .expect("expected search path response");
                    },
                    "library_paths" => {
                        stream
                            .write_all(br#"{"members":[{"name_raw":"/tmp/ark-test-library"}]}"#)
                            .expect("expected library path response");
                    },
                    _ => unreachable!(),
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

        let bootstrap = bridge
            .bootstrap()
            .expect("expected legacy fallback bootstrap");
        handle.join().expect("expected listener thread to join");

        assert_eq!(bootstrap.search_path_symbols, vec![
            String::from("library"),
            String::from("mtcars")
        ]);
        assert_eq!(bootstrap.library_paths, vec![PathBuf::from(
            "/tmp/ark-test-library"
        )]);
        assert_eq!(
            connections.load(Ordering::SeqCst),
            3,
            "bootstrap command error should fall back to legacy inspect requests"
        );
    }

    #[test]
    fn test_status_file_current_connection_refreshes_when_file_changes() {
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            r#"{"status":"ready","port":41001,"auth_token":"token-one","repl_ready":true}"#,
        )
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

        std::fs::write(
            status.path(),
            r#"{"status":"ready","port":41002,"auth_token":"token-two-longer","repl_ready":true}"#,
        )
        .expect("expected updated status file");

        let second = source
            .current_connection()
            .expect("expected refreshed connection");
        assert_eq!(second.port, 41002);
        assert_eq!(second.auth_token, "token-two-longer");
    }

    #[test]
    fn test_bootstrap_dynamic_refreshes_connection_after_auth_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("expected test listener");
        let port = listener
            .local_addr()
            .expect("expected listener address")
            .port();
        let status = tempfile::NamedTempFile::new().expect("expected temp status file");
        std::fs::write(
            status.path(),
            format!(
                r#"{{"status":"ready","port":{},"auth_token":"token-one","repl_ready":true}}"#,
                port
            ),
        )
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

            std::fs::write(
                &status_path,
                format!(
                    r#"{{"status":"ready","port":{},"auth_token":"token-two","repl_ready":true}}"#,
                    port
                ),
            )
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
}
