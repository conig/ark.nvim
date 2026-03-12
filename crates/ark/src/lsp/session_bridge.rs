use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::time::Duration;

use anyhow::anyhow;
use serde::Deserialize;
use serde::Serialize;
use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::CompletionResponse;
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

use crate::lsp::document_context::DocumentContext;
use crate::lsp::traits::node::NodeExt;
use crate::lsp::traits::point::PointExt;
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
#[serde(rename_all = "camelCase")]
struct InspectRequest {
    request_id: String,
    auth_token: String,
    expr: String,
    session: BridgeSession,
    #[serde(skip_serializing_if = "Option::is_none")]
    options: Option<InspectOptions>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct InspectOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    accessor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    include_member_stats: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_members: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    member_name_prefix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_profile: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeSession {
    tmux_socket: String,
    tmux_session: String,
    tmux_pane: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InspectResponse {
    #[serde(default)]
    error: Option<BridgeError>,
    #[serde(default)]
    object_meta: Option<ObjectMeta>,
    #[serde(default)]
    members: Vec<BridgeMember>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeError {
    #[serde(default)]
    code: String,
    #[serde(default)]
    message: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectMeta {
    #[serde(default)]
    class: Vec<String>,
    #[serde(default)]
    length: usize,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    r#type: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
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
    Extractor,
    Namespace,
}

#[derive(Clone, Debug)]
struct CompletionRequest {
    expr: String,
    flavor: CompletionFlavor,
    prefix: Option<String>,
    accessor: Option<String>,
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

    pub(crate) fn completion_response(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<CompletionResponse>> {
        let Some(request) = self.completion_request(context)? else {
            return Ok(None);
        };

        let payload = self.inspect(
            request.expr.as_str(),
            Some(InspectOptions {
                accessor: request.accessor,
                include_member_stats: Some(false),
                max_members: Some(200),
                member_name_prefix: request.prefix,
                request_profile: Some(String::from("completion_lean")),
            }),
        )?;

        if payload.members.is_empty() {
            return Ok(None);
        }

        let items = payload
            .members
            .into_iter()
            .enumerate()
            .map(|(index, member)| completion_item(member, request.flavor, index))
            .collect::<Vec<_>>();

        Ok(Some(CompletionResponse::Array(items)))
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
            active_parameter =
                Some(u32::try_from(payload.members.len() + 1).unwrap_or_default());
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

    fn completion_request(
        &self,
        context: &DocumentContext,
    ) -> anyhow::Result<Option<CompletionRequest>> {
        if let Some(request) = completion_request_from_extractor(context)? {
            return Ok(Some(request));
        }
        if let Some(request) = completion_request_from_namespace(context)? {
            return Ok(Some(request));
        }
        completion_request_from_call(context)
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
}

fn completion_item(member: BridgeMember, flavor: CompletionFlavor, index: usize) -> CompletionItem {
    let insert_text = match flavor {
        CompletionFlavor::Argument => {
            if !member.insert_text.is_empty() {
                member.insert_text.clone()
            } else {
                format!("{} = ", member.name_raw)
            }
        },
        CompletionFlavor::Extractor | CompletionFlavor::Namespace => member.name_raw.clone(),
    };

    let kind = match flavor {
        CompletionFlavor::Argument => CompletionItemKind::VARIABLE,
        CompletionFlavor::Extractor | CompletionFlavor::Namespace => CompletionItemKind::FIELD,
    };

    CompletionItem {
        label: member.name_display.clone(),
        detail: if member.r#type.is_empty() {
            None
        } else {
            Some(member.r#type)
        },
        documentation: if member.summary.is_empty() {
            None
        } else {
            Some(Documentation::MarkupContent(MarkupContent {
                kind: MarkupKind::Markdown,
                value: member.summary,
            }))
        },
        filter_text: Some(member.name_raw.clone()),
        insert_text: Some(insert_text),
        kind: Some(kind),
        sort_text: Some(format!("{index:04}")),
        ..Default::default()
    }
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
    }))
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

    Ok(Some(node.node_to_string(context.document.contents.as_str())?))
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
        Some(parent) if matches!(parent.node_type(), NodeType::NamespaceOperator(_)) => Some(parent),
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
