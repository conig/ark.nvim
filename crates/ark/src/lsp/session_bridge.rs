use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::anyhow;
use harp::syntax::sym_quote_invalid;
use regex::Regex;
use serde::Deserialize;
use serde::Serialize;
use serde_json::Value;
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
    host: String,
    port: u16,
    auth_token: String,
    session: BridgeSession,
    timeout: Duration,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBootstrap {
    pub search_path_symbols: Vec<String>,
    pub installed_packages: Vec<String>,
    pub library_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionBridgeConfig {
    pub host: String,
    pub port: u16,
    pub auth_token: String,
    pub tmux_socket: String,
    pub tmux_session: String,
    pub tmux_pane: String,
    pub timeout_ms: u64,
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

#[derive(Clone, Debug)]
struct CallContext {
    active_argument: Option<String>,
    explicit_parameters: Vec<String>,
    num_unnamed_arguments: usize,
    callee: String,
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
    pub(crate) fn new(config: SessionBridgeConfig) -> anyhow::Result<Self> {
        if config.host.is_empty() {
            return Err(anyhow!("session bridge host is missing"));
        }
        if config.port == 0 {
            return Err(anyhow!("session bridge port is missing"));
        }

        Ok(Self {
            host: config.host,
            port: config.port,
            auth_token: config.auth_token,
            session: BridgeSession {
                tmux_socket: config.tmux_socket,
                tmux_session: config.tmux_session,
                tmux_pane: config.tmux_pane,
            },
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
            CompletionPlan::Unique(request) => self.completion_items_for_request(&request)?,
            CompletionPlan::Composite(requests) => {
                let mut items = Vec::new();

                for request in requests {
                    items.extend(self.completion_items_for_request(&request)?);
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
        let search_path_symbols = self.inspect_names(search_path_completion_expr().as_str())?;
        let installed_packages =
            self.inspect_names(installed_packages_completion_expr().as_str())?;
        let library_paths = self
            .inspect_names(library_paths_completion_expr().as_str())?
            .into_iter()
            .map(PathBuf::from)
            .collect::<Vec<_>>();

        Ok(SessionBootstrap {
            search_path_symbols,
            installed_packages,
            library_paths,
        })
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
        if let Some(request) = completion_request_from_extractor(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_namespace(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_comparison_string(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_string_subset(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_subset(context)? {
            if request.prefix.is_some() {
                let mut requests = vec![request];

                if let Some(search_path) = completion_request_from_search_path(context)? {
                    requests.push(search_path);
                }

                return Ok(Some(CompletionPlan::Composite(requests)));
            }

            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_library_string(context)? {
            return Ok(Some(CompletionPlan::Unique(request)));
        }
        if let Some(request) = completion_request_from_library_call(context)? {
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
        let mut stream = TcpStream::connect((self.host.as_str(), self.port))?;
        stream.set_read_timeout(Some(self.timeout))?;
        stream.set_write_timeout(Some(self.timeout))?;

        let request = InspectRequest {
            request_id: format!("ark-{}", Uuid::new_v4()),
            auth_token: self.auth_token.clone(),
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
            return Err(anyhow!(
                "session bridge request failed: {}: {}",
                error.code,
                error.message
            ));
        }

        Ok(payload)
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
        CompletionFlavor::ComparisonString => escape_r_double_quoted(member.name_raw.as_str()),
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
        sort_text: Some(format!("{index:04}")),
        data: completion_item_data(request, &member)
            .and_then(|data| serde_json::to_value(data).ok()),
        ..Default::default()
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

    let Some(operator) = extract_operator_node(node, parent) else {
        return Ok(None);
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
        subset_kind: None,
    }))
}

fn completion_request_from_namespace(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let node = context.node;

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
        subset_kind: Some(subset_kind),
    }))
}

fn completion_request_from_subset(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some((subset_node, subset_kind)) = find_subset_node(context) else {
        return Ok(completion_request_from_subset_text(context));
    };

    let Some(object_node) = subset_node.child_by_field_name("function") else {
        return Ok(None);
    };

    let expr = object_node.node_to_string(context.document.contents.as_str())?;

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Subset,
        prefix: symbol_prefix(context)?,
        accessor: None,
        subset_kind: Some(subset_kind),
    }))
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
            subset_kind: None,
        }));
    }

    if let Some((expr, value_prefix)) = comparison_string_expr(prefix.as_str()) {
        return Ok(Some(CompletionRequest {
            expr,
            flavor: CompletionFlavor::ComparisonString,
            prefix: Some(value_prefix),
            accessor: None,
            subset_kind: None,
        }));
    }

    Ok(None)
}

fn completion_request_from_library_string(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(string_node) = node_find_string(&context.node) else {
        return Ok(completion_request_from_library_string_text(context));
    };

    let Some(call) = analyze_call_context(context)? else {
        return Ok(completion_request_from_library_string_text(context));
    };

    if !matches!(call.callee.as_str(), "library" | "require") || call.num_unnamed_arguments > 0 {
        return Ok(completion_request_from_library_string_text(context));
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
        subset_kind: None,
    }))
}

fn completion_request_from_library_string_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
    static LIBRARY_STRING_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)^\s*(?:library|require)\s*\(\s*"(?P<prefix>[^"]*)$"#).unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = LIBRARY_STRING_RE.captures(prefix.as_str())?;

    Some(CompletionRequest {
        expr: installed_packages_completion_expr(),
        flavor: CompletionFlavor::Package,
        prefix: captures
            .name("prefix")
            .map(|capture| capture.as_str().to_string()),
        accessor: None,
        subset_kind: None,
    })
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
            subset_kind: Some(SubsetCompletionKind::StringSubset2),
        });
    }

    let captures = STRING_SUBSET_RE.captures(prefix.as_str())?;
    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Subset,
        prefix: None,
        accessor: None,
        subset_kind: Some(SubsetCompletionKind::StringSubset),
    })
}

fn completion_request_from_subset_text(context: &DocumentContext) -> Option<CompletionRequest> {
    static SUBSET2_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\[\s*(?P<prefix>[A-Za-z0-9._]*)$"#)
            .unwrap()
    });
    static SUBSET_C_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*\[\s*[^,\]]*,\s*c\s*\(\s*(?P<prefix>[A-Za-z0-9._]*)$"#,
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
            subset_kind: Some(SubsetCompletionKind::Subset2),
        });
    }

    if let Some(captures) = SUBSET_C_RE.captures(prefix.as_str()) {
        return Some(CompletionRequest {
            expr: captures.name("expr")?.as_str().to_string(),
            flavor: CompletionFlavor::Subset,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: None,
            subset_kind: Some(SubsetCompletionKind::Subset),
        });
    }

    let captures = SUBSET_RE.captures(prefix.as_str())?;
    Some(CompletionRequest {
        expr: captures.name("expr")?.as_str().to_string(),
        flavor: CompletionFlavor::Subset,
        prefix: capture_prefix(&captures, "prefix"),
        accessor: None,
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

    let prefix = argument_prefix(context)?;

    Ok(Some(CompletionRequest {
        expr: call.callee,
        flavor: CompletionFlavor::Argument,
        prefix,
        accessor: Some(String::from("arg")),
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
        subset_kind: None,
    })
}

fn completion_request_from_library_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };

    if !matches!(call.callee.as_str(), "library" | "require") {
        return Ok(None);
    }

    if call.num_unnamed_arguments > 0 {
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
        subset_kind: None,
    }))
}

fn completion_request_from_search_path(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let prefix = symbol_prefix(context)?;
    if prefix.is_none() && context.trigger.is_none() {
        return Ok(None);
    }

    Ok(Some(CompletionRequest {
        expr: search_path_completion_expr(),
        flavor: CompletionFlavor::Symbol,
        prefix,
        accessor: None,
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
    let Some(mut node) = root.find_closest_node_to_point(context.point) else {
        return None;
    };

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
    use super::*;
    use crate::fixtures::point_from_cursor;
    use crate::lsp::document::Document;

    #[test]
    fn test_symbol_prefix_prefers_typed_subset_identifier() {
        let (text, point) = point_from_cursor("dt_ark[as.char@");
        let document = Document::new(text.as_str(), None);
        let context = DocumentContext::new(&document, point, None);

        assert_eq!(symbol_prefix(&context).unwrap(), Some(String::from("as.char")));
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
}
