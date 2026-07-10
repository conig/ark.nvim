use std::sync::LazyLock;

use harp::syntax::sym_quote_invalid;
use regex::Regex;
use tree_sitter::Node;
use tree_sitter::Point;

use super::protocol::BridgeMember;
use super::protocol::ObjectMeta;
use super::SessionBridge;
use super::TargetCompletionProject;
use super::TargetNameCompletionContext;
use crate::lsp::call_context::analyze_call_context;
use crate::lsp::call_context::call_matches_package_argument;
use crate::lsp::call_context::text_matches_package_argument;
use crate::lsp::call_context::CallContext;
use crate::lsp::call_context::PackageCompletionMode;
use crate::lsp::completions::call_node_position_type;
use crate::lsp::completions::find_pipe_root_name;
use crate::lsp::completions::CallNodePositionType;
use crate::lsp::completions::CompletionPlan as CanonicalCompletionPlan;
use crate::lsp::document::DocumentKind;
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

#[derive(Clone, Debug, PartialEq)]
pub(super) struct CallArgument {
    pub(super) name: Option<String>,
    pub(super) value_expr: String,
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct IncompleteDataContextCall {
    pub(super) callee: String,
    pub(super) arguments: Vec<CallArgument>,
}

#[derive(Clone, Copy, Debug)]
pub(super) enum CompletionFlavor {
    Argument,
    ComparisonString,
    Extractor,
    Namespace,
    Package,
    Pipe,
    Subset,
    Symbol,
    Target,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum SubsetCompletionKind {
    Subset,
    Subset2,
    StringSubset,
    StringSubset2,
}

#[derive(Clone, Debug)]
pub(super) struct CompletionRequest {
    pub(super) expr: String,
    pub(super) flavor: CompletionFlavor,
    pub(super) prefix: Option<String>,
    pub(super) accessor: Option<String>,
    pub(super) close_string: bool,
    pub(super) quote_insert: bool,
    pub(super) subset_kind: Option<SubsetCompletionKind>,
}

pub(super) type CompletionPlan = CanonicalCompletionPlan<CompletionRequest, Vec<CompletionRequest>>;

pub(super) fn plan(
    bridge: &SessionBridge,
    context: &DocumentContext,
    target_project: Option<&TargetCompletionProject>,
) -> anyhow::Result<Option<CompletionPlan>> {
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
    if let Some(request) = completion_request_from_custom_call(context, target_project)? {
        return Ok(Some(CompletionPlan::Unique(request)));
    }
    if let Some(request) = completion_request_from_argument_string(context)? {
        return Ok(Some(CompletionPlan::Unique(request)));
    }
    if let Some(request) = completion_request_from_string_subset(context)? {
        return Ok(Some(CompletionPlan::Unique(request)));
    }
    if plain_string_quote_trigger_is_handled_empty(context) {
        return Ok(Some(CompletionPlan::HandledEmpty));
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
    if empty_package_call_autotrigger_is_suppressed(context)? {
        return Ok(Some(CompletionPlan::HandledEmpty));
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
    if let Some(request) = completion_request_from_call_text_after_named_argument(context)? {
        if let Some(search_path) = completion_request_from_search_path(context)? {
            return Ok(Some(CompletionPlan::Composite(vec![request, search_path])));
        }

        return Ok(Some(CompletionPlan::Unique(request)));
    }
    if let Some(request) = bridge.completion_request_from_data_context(context)? {
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

pub(super) fn completion_request_from_extractor(
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

    let expr = match target_read_object_expr_from_context_node(&lhs, context)? {
        Some(expr) => expr,
        None => lhs.node_to_string(context.document.contents.as_str())?,
    };
    let accessor = match operator.node_type() {
        NodeType::ExtractOperator(ExtractOperatorType::At) => Some(String::from("@")),
        NodeType::ExtractOperator(ExtractOperatorType::Dollar) => Some(String::from("$")),
        _ => None,
    };
    let prefix = if context_at_trigger_accessor_end(context, accessor.as_deref()) {
        None
    } else {
        operator
            .child_by_field_name("rhs")
            .map(|rhs| rhs.node_to_string(context.document.contents.as_str()))
            .transpose()?
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

pub(super) fn context_at_trigger_accessor_end(
    context: &DocumentContext,
    accessor: Option<&str>,
) -> bool {
    let Some(accessor) = accessor else {
        return false;
    };
    if context.trigger.as_deref() != Some(accessor) {
        return false;
    }

    let Some(line) = context.document.get_line(context.point.row) else {
        return false;
    };
    line.chars()
        .take(context.point.column)
        .collect::<String>()
        .ends_with(accessor)
}

pub(super) fn completion_request_from_extractor_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
    static TARGET_READ_EXTRACTOR_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?:(?:[A-Za-z.][A-Za-z0-9._]*)(?:::|::))?
            tar_read
            \s*\(\s*
            (?:name\s*=\s*)?
            (?:
                "(?P<double>[^"]+)"
                |
                '(?P<single>[^']+)'
                |
                (?P<bare>[A-Za-z.][A-Za-z0-9._]*)
            )
            \s*\)
            \s*(?P<accessor>\$|@)(?P<prefix>[A-Za-z0-9._]*)$
            "#,
        )
        .unwrap()
    });
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

    if let Some(captures) = TARGET_READ_EXTRACTOR_RE.captures(prefix.as_str()) {
        let accessor = captures.name("accessor")?.as_str();
        if accessor != trigger {
            return None;
        }
        let target_name = captures
            .name("double")
            .or_else(|| captures.name("single"))
            .or_else(|| captures.name("bare"))?
            .as_str();
        return Some(CompletionRequest {
            expr: target_read_object_expr(target_name),
            flavor: CompletionFlavor::Extractor,
            prefix: capture_prefix(&captures, "prefix"),
            accessor: Some(accessor.to_string()),
            close_string: false,
            quote_insert: false,
            subset_kind: None,
        });
    }

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

pub(super) fn completion_request_from_namespace(
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

pub(super) fn completion_request_from_string_subset(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(string_node) = node_find_string(&context.node) else {
        return Ok(completion_request_from_string_subset_text(context));
    };

    let Some((object_node, subset_kind)) = find_string_subset_object(&string_node, context) else {
        return Ok(completion_request_from_string_subset_text(context));
    };

    let expr = match target_read_object_expr_from_context_node(&object_node, context)? {
        Some(expr) => expr,
        None => object_node.node_to_string(context.document.contents.as_str())?,
    };

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

pub(super) fn completion_request_from_subset(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let text_request = completion_request_from_subset_text(context);
    let Some((subset_node, subset_kind)) = find_subset_node(context) else {
        return Ok(text_request);
    };

    let Some(object_node) = subset_node.child_by_field_name("function") else {
        return Ok(None);
    };

    let expr = match target_read_object_expr_from_context_node(&object_node, context)? {
        Some(expr) => expr,
        None => object_node.node_to_string(context.document.contents.as_str())?,
    };
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

pub(super) fn completion_request_from_comparison_string(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };
    let prefix = line.chars().take(context.point.column).collect::<String>();

    if let Some((expr, value_prefix)) = comparison_string_target_read_expr(prefix.as_str()) {
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

pub(super) fn completion_request_from_package_string(
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

pub(super) fn completion_request_from_package_string_text(
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
            (?:
                "(?P<prefix_double>[^"]*)
                |
                '(?P<prefix_single>[^']*)
            )$
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
        prefix: captured_quoted_prefix(&captures).map(String::from),
        accessor: None,
        close_string: true,
        quote_insert: false,
        subset_kind: None,
    })
}

pub(super) fn completion_request_from_argument_string(
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

pub(super) fn completion_request_from_argument_string_text(
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
            (?P<formal>[A-Za-z.][A-Za-z0-9._]*)\s*=\s*
            (?:
                "(?P<prefix_double>[^"]*)
                |
                '(?P<prefix_single>[^']*)
            )$
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
        prefix: captured_quoted_prefix(&captures).map(String::from),
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    })
}

pub(super) fn completion_request_from_custom_call(
    context: &DocumentContext,
    target_project: Option<&TargetCompletionProject>,
) -> anyhow::Result<Option<CompletionRequest>> {
    if let Some(target_context) = target_name_completion_context(context)? {
        return Ok(Some(CompletionRequest {
            expr: target_names_completion_expr(target_project),
            flavor: CompletionFlavor::Target,
            prefix: target_context.prefix,
            accessor: None,
            close_string: target_context.close_string,
            quote_insert: false,
            subset_kind: None,
        }));
    }

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

pub(crate) fn target_name_completion_context(
    context: &DocumentContext,
) -> anyhow::Result<Option<TargetNameCompletionContext>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };

    if !target_name_call_callee(call.callee.as_str()) {
        return Ok(None);
    }

    let in_string = node_find_string(&context.node).is_some();
    let position = call_node_position_type(&context.node, context.point);

    if !target_name_call_target(&call, position, in_string) {
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

    Ok(Some(TargetNameCompletionContext {
        prefix,
        close_string: in_string,
    }))
}

pub(crate) fn runtime_string_completion_takes_precedence(
    context: &DocumentContext,
    target_project: Option<&TargetCompletionProject>,
) -> anyhow::Result<bool> {
    Ok(
        completion_request_from_comparison_string(context)?.is_some() ||
            completion_request_from_package_string(context)?.is_some() ||
            completion_request_from_custom_call(context, target_project)?.is_some() ||
            completion_request_from_string_subset(context)?.is_some(),
    )
}

pub(super) fn target_name_call_callee(callee: &str) -> bool {
    matches!(
        unqualified_callee(callee),
        "tar_read" |
            "tar_load" |
            "tar_make" |
            "tar_invalidate" |
            "tar_render" |
            "tar_fuzzy_make" |
            "tar_fuzzy_invalidate"
    )
}

pub(super) fn unqualified_callee(callee: &str) -> &str {
    callee
        .rsplit_once(":::")
        .or_else(|| callee.rsplit_once("::"))
        .map(|(_, name)| name)
        .unwrap_or(callee)
}

pub(super) fn target_read_object_expr_from_node(
    node: &Node,
    contents: &str,
) -> anyhow::Result<Option<String>> {
    if !node.is_call() {
        return Ok(None);
    }

    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(None);
    };
    let callee = callee.node_to_string(contents)?;
    if unqualified_callee(callee.as_str()) != "tar_read" {
        return Ok(None);
    }

    let Some(name) = target_call_name_arg(node, contents)? else {
        return Ok(None);
    };

    Ok(Some(target_read_object_expr(name.as_str())))
}

pub(super) fn target_read_object_expr_from_context_node(
    node: &Node,
    context: &DocumentContext,
) -> anyhow::Result<Option<String>> {
    if let Some(expr) = target_read_object_expr_from_node(node, context.document.contents.as_str())?
    {
        return Ok(Some(expr));
    }

    let NodeType::Identifier = node.node_type() else {
        return Ok(None);
    };

    let name = node.node_to_string(context.document.contents.as_str())?;
    target_read_assignment_expr_from_name(name.as_str(), context)
}

pub(super) fn target_read_assignment_expr_from_name(
    name: &str,
    context: &DocumentContext,
) -> anyhow::Result<Option<String>> {
    static ASSIGNMENT_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"^\s*(?P<lhs>[A-Za-z.][A-Za-z0-9._]*)\s*(?:<-|=)\s*"#).unwrap()
    });
    static TARGET_READ_ASSIGNMENT_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"^\s*(?P<lhs>[A-Za-z.][A-Za-z0-9._]*)\s*(?:<-|=)\s*(?:(?:[A-Za-z.][A-Za-z0-9._]*)(?:::|::))?tar_read\s*\(\s*(?:name\s*=\s*)?(?:"(?P<double>[^"]+)"|'(?P<single>[^']+)'|(?P<bare>[A-Za-z.][A-Za-z0-9._]*))"#,
        )
        .unwrap()
    });

    for row in (0..=context.point.row).rev() {
        let Some(line) = context.document.get_line(row) else {
            continue;
        };
        let line = if row == context.point.row {
            line.chars().take(context.point.column).collect::<String>()
        } else {
            line.to_string()
        };

        if let Some(captures) = TARGET_READ_ASSIGNMENT_RE.captures(line.as_str()) {
            if captures.name("lhs").map(|capture| capture.as_str()) != Some(name) {
                continue;
            }
            let Some(target_name) = captures
                .name("double")
                .or_else(|| captures.name("single"))
                .or_else(|| captures.name("bare"))
                .map(|capture| capture.as_str())
            else {
                return Ok(None);
            };
            return Ok(Some(target_read_object_expr(target_name)));
        }

        if ASSIGNMENT_RE
            .captures(line.as_str())
            .and_then(|captures| captures.name("lhs"))
            .is_some_and(|capture| capture.as_str() == name)
        {
            return Ok(None);
        }
    }

    Ok(None)
}

pub(super) fn target_read_object_expr(name: &str) -> String {
    format!(
        "local({{ .ark_reader <- if (\"arkbridge\" %in% loadedNamespaces() && exists(\".ark_targets_read_for_completion\", envir = asNamespace(\"arkbridge\"), mode = \"function\", inherits = FALSE)) get(\".ark_targets_read_for_completion\", envir = asNamespace(\"arkbridge\"), mode = \"function\", inherits = FALSE) else NULL; if (!is.null(.ark_reader)) .ark_reader(\"{}\") else if (!requireNamespace(\"targets\", quietly = TRUE)) NULL else targets::tar_read(name = \"{}\") }})",
        escape_r_string(name),
        escape_r_string(name)
    )
}

pub(super) fn target_call_name_arg(node: &Node, contents: &str) -> anyhow::Result<Option<String>> {
    let mut first_unnamed = None;

    for (name, value) in node.arguments() {
        let Some(value) = value else {
            continue;
        };

        if let Some(name) = name {
            if name.node_as_str(contents)? == "name" {
                return target_call_name_value(&value, contents);
            }
            continue;
        }

        if first_unnamed.is_none() {
            first_unnamed = Some(value);
        }
    }

    let Some(value) = first_unnamed else {
        return Ok(None);
    };

    target_call_name_value(&value, contents)
}

pub(super) fn target_call_name_value(
    value: &Node,
    contents: &str,
) -> anyhow::Result<Option<String>> {
    if !value.is_identifier_or_string() {
        return Ok(None);
    }

    Ok(Some(
        value.get_identifier_or_string_text(contents)?.to_string(),
    ))
}

pub(super) fn target_name_call_target(
    call: &CallContext,
    position: CallNodePositionType,
    in_string: bool,
) -> bool {
    if let Some(active_argument) = call.active_argument.as_deref() {
        return matches!(active_argument, "name" | "names");
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

pub(super) fn custom_string_call_target(
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

pub(super) fn custom_argument_call_target(position: CallNodePositionType) -> bool {
    matches!(
        position,
        CallNodePositionType::Name | CallNodePositionType::Ambiguous
    )
}

pub(super) fn completion_request_from_string_subset_text(
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
        let expr_name = captures.name("expr")?.as_str();
        let expr = target_read_assignment_expr_from_name(expr_name, context)
            .ok()
            .flatten()
            .unwrap_or_else(|| expr_name.to_string());

        return Some(CompletionRequest {
            expr,
            flavor: CompletionFlavor::Subset,
            prefix: None,
            accessor: None,
            close_string: false,
            quote_insert: false,
            subset_kind: Some(SubsetCompletionKind::StringSubset2),
        });
    }

    let captures = STRING_SUBSET_RE.captures(prefix.as_str())?;
    let expr_name = captures.name("expr")?.as_str();
    let expr = target_read_assignment_expr_from_name(expr_name, context)
        .ok()
        .flatten()
        .unwrap_or_else(|| expr_name.to_string());

    Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Subset,
        prefix: None,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: Some(SubsetCompletionKind::StringSubset),
    })
}

pub(super) fn completion_request_from_subset_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
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

pub(super) fn capture_prefix(captures: &regex::Captures, name: &str) -> Option<String> {
    captures
        .name(name)
        .map(|capture| capture.as_str())
        .filter(|prefix| !prefix.is_empty())
        .map(String::from)
}

pub(super) fn completion_request_from_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let text_argument_slot = call_text_argument_slot(context)?;
    let Some(call) = analyze_call_context(context)? else {
        return completion_request_from_call_text(context);
    };
    if call.callee == "." {
        return Ok(None);
    }

    if !call_argument_name_completion_target(context) {
        return Ok(None);
    }

    let mut prefix = argument_prefix(context)?;
    if prefix.is_none() {
        if let Some((text_callee, text_prefix)) = text_argument_slot {
            if text_callee == call.callee {
                prefix = text_prefix;
            }
        }
    }

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

pub(super) fn call_argument_syntax_position(context: &DocumentContext) -> bool {
    matches!(
        call_node_position_type(&context.node, context.point),
        CallNodePositionType::Name | CallNodePositionType::Ambiguous | CallNodePositionType::Value
    )
}

pub(super) fn call_argument_name_completion_target(context: &DocumentContext) -> bool {
    matches!(
        call_node_position_type(&context.node, context.point),
        CallNodePositionType::Name | CallNodePositionType::Ambiguous
    )
}

pub(super) fn call_argument_value_completion_target(context: &DocumentContext) -> bool {
    matches!(
        call_node_position_type(&context.node, context.point),
        CallNodePositionType::Value
    )
}

pub(super) fn completion_request_from_call_text(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some((callee, argument_prefix)) = call_text_argument_slot(context)? else {
        return Ok(None);
    };

    Ok(Some(CompletionRequest {
        expr: callee,
        flavor: CompletionFlavor::Argument,
        prefix: argument_prefix,
        accessor: Some(String::from("arg")),
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

pub(super) fn completion_request_from_call_text_after_named_argument(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some((callee, argument_prefix)) = call_text_argument_slot_after_named_argument(context)?
    else {
        return Ok(None);
    };

    Ok(Some(CompletionRequest {
        expr: callee,
        flavor: CompletionFlavor::Argument,
        prefix: argument_prefix,
        accessor: Some(String::from("arg")),
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

pub(super) fn call_text_argument_slot(
    context: &DocumentContext,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };

    let prefix = line.chars().take(context.point.column).collect::<String>();
    let Some(open) = last_unmatched_open_paren(prefix.as_str()) else {
        return Ok(None);
    };
    let Some(callee_start) = callee_start_before_open(prefix.as_str(), open) else {
        return Ok(None);
    };

    let callee = prefix[callee_start..open].trim();
    if callee.is_empty() || callee == "." {
        return Ok(None);
    }

    let arguments = &prefix[open + 1..];
    let Some(current_argument) = top_level_split(arguments, ',').last().copied() else {
        return Ok(None);
    };
    let Some(argument_prefix) = argument_name_prefix_from_text(current_argument) else {
        return Ok(None);
    };

    Ok(Some((String::from(callee), argument_prefix)))
}

pub(super) fn call_text_argument_slot_after_named_argument(
    context: &DocumentContext,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };

    let prefix = line.chars().take(context.point.column).collect::<String>();
    let Some(open) = last_unmatched_open_paren(prefix.as_str()) else {
        return Ok(None);
    };
    let Some(callee_start) = callee_start_before_open(prefix.as_str(), open) else {
        return Ok(None);
    };

    let callee = prefix[callee_start..open].trim();
    if callee.is_empty() || callee == "." {
        return Ok(None);
    }

    let arguments = &prefix[open + 1..];
    let parts = top_level_split(arguments, ',');
    if parts.len() < 2 ||
        !parts[..parts.len() - 1]
            .iter()
            .any(|argument| top_level_assignment_index(argument).is_some())
    {
        return Ok(None);
    }

    let Some(current_argument) = parts.last().copied() else {
        return Ok(None);
    };
    let Some(argument_prefix) = argument_name_prefix_from_text(current_argument) else {
        return Ok(None);
    };

    Ok(Some((String::from(callee), argument_prefix)))
}

pub(super) fn completion_request_from_pipe(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    if call_argument_value_completion_target(context) {
        return Ok(None);
    }

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

pub(super) fn completion_request_from_pipe_text(
    context: &DocumentContext,
) -> Option<CompletionRequest> {
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

pub(super) fn completion_request_from_package_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(None);
    };

    if !call_matches_package_argument(&call, PackageCompletionMode::BareSymbol) {
        return Ok(None);
    }

    let prefix = symbol_prefix(context)?;
    if prefix.is_none() && !context.explicit_completion_request {
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

pub(super) fn empty_package_call_autotrigger_is_suppressed(
    context: &DocumentContext,
) -> anyhow::Result<bool> {
    if context.explicit_completion_request {
        return Ok(false);
    }

    let Some(call) = analyze_call_context(context)? else {
        return Ok(false);
    };

    if !call_matches_package_argument(&call, PackageCompletionMode::BareSymbol) {
        return Ok(false);
    }

    Ok(symbol_prefix(context)?.is_none())
}

pub(super) fn completion_request_from_search_path(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    let prefix = symbol_prefix(context)?;
    if prefix.is_none() && empty_call_paren_trigger_is_argument_slot(context)? {
        return Ok(None);
    }

    let allow_empty_prefix = empty_inline_r_space_autotrigger_is_allowed(context);
    if prefix.is_none() && !allow_empty_prefix {
        match context.trigger.as_deref() {
            None | Some(" ") | Some(",") => return Ok(None),
            _ => {},
        }
    }

    let expr = if prefix.is_none() && allow_empty_prefix {
        prioritized_empty_search_path_completion_expr()
    } else {
        search_path_completion_expr(prefix.as_deref())
    };

    Ok(Some(CompletionRequest {
        expr,
        flavor: CompletionFlavor::Symbol,
        prefix,
        accessor: None,
        close_string: false,
        quote_insert: false,
        subset_kind: None,
    }))
}

pub(super) fn plain_string_quote_trigger_is_handled_empty(context: &DocumentContext) -> bool {
    if !matches!(context.trigger.as_deref(), Some("\"") | Some("'")) {
        return false;
    }

    if node_find_string(&context.node).is_some() {
        return true;
    }

    line_prefix_is_inside_string(context)
}

pub(super) fn line_prefix_is_inside_string(context: &DocumentContext) -> bool {
    let Some(line) = context.document.get_line(context.point.row) else {
        return false;
    };

    let mut quote = None;
    let mut escaped = false;

    for ch in line.chars().take(context.point.column) {
        let Some(active_quote) = quote else {
            if matches!(ch, '"' | '\'') {
                quote = Some(ch);
            }
            continue;
        };

        if escaped {
            escaped = false;
            continue;
        }

        if ch == '\\' {
            escaped = true;
            continue;
        }

        if ch == active_quote {
            quote = None;
        }
    }

    quote.is_some()
}

pub(super) fn empty_call_paren_trigger_is_argument_slot(
    context: &DocumentContext,
) -> anyhow::Result<bool> {
    if context.trigger.as_deref() != Some("(") {
        return Ok(false);
    }

    if call_text_argument_slot(context)?.is_some() {
        return Ok(true);
    }

    Ok(analyze_call_context(context)?.is_some())
}

pub(super) fn empty_inline_r_space_autotrigger_is_allowed(context: &DocumentContext) -> bool {
    if context.document.kind != DocumentKind::LiterateR {
        return false;
    }

    if context.trigger.as_deref() != Some(" ") {
        return false;
    }

    let Some(line) = context.document.get_line(context.point.row) else {
        return false;
    };

    let prefix = line.chars().take(context.point.column).collect::<String>();
    prefix.ends_with("`r ")
}

pub(super) fn completion_request_from_explicit_pipe_root(
    context: &DocumentContext,
) -> anyhow::Result<Option<CompletionRequest>> {
    if !context.explicit_completion_request {
        return Ok(None);
    }

    if call_argument_value_completion_target(context) {
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

pub(super) fn argument_prefix(context: &DocumentContext) -> anyhow::Result<Option<String>> {
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

pub(super) fn next_enclosing_call<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
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

pub(super) fn data_context_call_node<'tree>(
    context: &'tree DocumentContext,
) -> Option<Node<'tree>> {
    node_find_containing_call(context.node)
        .or_else(|| node_find_containing_call(context.closest_node))
}

pub(super) fn incomplete_data_context_call(
    context: &DocumentContext,
) -> anyhow::Result<Option<IncompleteDataContextCall>> {
    let Some(line) = context.document.get_line(context.point.row) else {
        return Ok(None);
    };

    let prefix = line.chars().take(context.point.column).collect::<String>();
    let Some(nested_open) = last_unmatched_open_paren(prefix.as_str()) else {
        return Ok(None);
    };

    let nested_prefix = prefix[nested_open + 1..].trim();
    if !nested_prefix
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.'))
    {
        return Ok(None);
    }

    let Some(nested_callee_start) = callee_start_before_open(prefix.as_str(), nested_open) else {
        return Ok(None);
    };
    let Some(outer_open) = last_unmatched_open_paren(&prefix[..nested_callee_start]) else {
        return Ok(None);
    };
    let Some(outer_callee_start) = callee_start_before_open(prefix.as_str(), outer_open) else {
        return Ok(None);
    };

    let callee = prefix[outer_callee_start..outer_open].trim();
    if callee.is_empty() {
        return Ok(None);
    }

    let arguments = call_arguments_from_text(&prefix[outer_open + 1..nested_callee_start])?;
    Ok(Some(IncompleteDataContextCall {
        callee: String::from(callee),
        arguments,
    }))
}

pub(super) fn last_unmatched_open_paren(text: &str) -> Option<usize> {
    let mut stack = Vec::new();
    let mut quote = None;
    let mut escaped = false;

    for (index, ch) in text.char_indices() {
        if let Some(active_quote) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == active_quote {
                quote = None;
            }
            continue;
        }

        match ch {
            '"' | '\'' | '`' => quote = Some(ch),
            '(' => stack.push(index),
            ')' => {
                stack.pop();
            },
            _ => {},
        }
    }

    stack.pop()
}

pub(super) fn callee_start_before_open(text: &str, open_index: usize) -> Option<usize> {
    let before_open = text.get(..open_index)?;
    let end = before_open
        .char_indices()
        .rev()
        .find(|(_, ch)| !ch.is_whitespace())
        .map(|(index, ch)| index + ch.len_utf8())?;
    let start = before_open[..end]
        .char_indices()
        .rev()
        .find(|(_, ch)| !is_callee_char(*ch))
        .map(|(index, ch)| index + ch.len_utf8())
        .unwrap_or(0);

    if start == end {
        return None;
    }

    Some(start)
}

pub(super) fn is_callee_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | ':')
}

pub(super) fn call_arguments_from_text(arguments: &str) -> anyhow::Result<Vec<CallArgument>> {
    top_level_split(arguments, ',')
        .into_iter()
        .filter_map(|argument| {
            let argument = argument.trim();
            if argument.is_empty() {
                return None;
            }

            let (name, value_expr) = match top_level_assignment_index(argument) {
                Some(index) => {
                    let name = argument[..index].trim();
                    let value = argument[index + 1..].trim();
                    let name = if is_identifier_text(name) {
                        Some(String::from(name))
                    } else {
                        None
                    };
                    (name, value)
                },
                None => (None, argument),
            };

            if value_expr.is_empty() {
                return None;
            }

            Some(Ok(CallArgument {
                name,
                value_expr: String::from(value_expr),
            }))
        })
        .collect()
}

pub(super) fn top_level_split(text: &str, delimiter: char) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut paren_depth = 0usize;
    let mut bracket_depth = 0usize;
    let mut brace_depth = 0usize;
    let mut quote = None;
    let mut escaped = false;

    for (index, ch) in text.char_indices() {
        if let Some(active_quote) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == active_quote {
                quote = None;
            }
            continue;
        }

        match ch {
            '"' | '\'' | '`' => quote = Some(ch),
            '(' => paren_depth += 1,
            ')' => paren_depth = paren_depth.saturating_sub(1),
            '[' => bracket_depth += 1,
            ']' => bracket_depth = bracket_depth.saturating_sub(1),
            '{' => brace_depth += 1,
            '}' => brace_depth = brace_depth.saturating_sub(1),
            ch if ch == delimiter && paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 => {
                parts.push(&text[start..index]);
                start = index + ch.len_utf8();
            },
            _ => {},
        }
    }

    parts.push(&text[start..]);
    parts
}

pub(super) fn top_level_assignment_index(text: &str) -> Option<usize> {
    let mut paren_depth = 0usize;
    let mut bracket_depth = 0usize;
    let mut brace_depth = 0usize;
    let mut quote = None;
    let mut escaped = false;

    for (index, ch) in text.char_indices() {
        if let Some(active_quote) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == active_quote {
                quote = None;
            }
            continue;
        }

        match ch {
            '"' | '\'' | '`' => quote = Some(ch),
            '(' => paren_depth += 1,
            ')' => paren_depth = paren_depth.saturating_sub(1),
            '[' => bracket_depth += 1,
            ']' => bracket_depth = bracket_depth.saturating_sub(1),
            '{' => brace_depth += 1,
            '}' => brace_depth = brace_depth.saturating_sub(1),
            '=' if paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 => {
                let previous = text[..index].chars().next_back();
                let next = text[index + ch.len_utf8()..].chars().next();
                if previous != Some('=') && next != Some('=') {
                    return Some(index);
                }
            },
            _ => {},
        }
    }

    None
}

pub(super) fn is_identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphabetic() && first != '.' && first != '_' {
        return false;
    }

    chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.'))
}

pub(super) fn argument_name_prefix_from_text(text: &str) -> Option<Option<String>> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Some(None);
    }
    if top_level_assignment_index(trimmed).is_some() {
        return None;
    }
    if !is_identifier_text(trimmed) {
        return None;
    }

    Some(Some(String::from(trimmed)))
}

pub(super) fn call_arguments(
    contents: &str,
    call_node: &Node,
) -> anyhow::Result<Vec<CallArgument>> {
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

pub(super) fn call_argument_contains_point(call_node: &Node, point: Point) -> bool {
    let Some(arguments) = call_node.child_by_field_name("arguments") else {
        return false;
    };

    let mut cursor = arguments.walk();
    for argument in arguments.children_by_field_name("argument", &mut cursor) {
        let Some(value) = argument.child_by_field_name("value") else {
            continue;
        };

        let range = value.range();
        if point.is_after_or_equal(range.start_point) && point.is_before_or_equal(range.end_point) {
            return true;
        }
    }

    false
}

#[cfg(test)]
pub(super) fn resolve_active_formal_name(formals: &[String], call: &CallContext) -> Option<String> {
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

pub(super) fn resolve_bound_argument_expr(
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

pub(super) fn symbol_prefix(context: &DocumentContext) -> anyhow::Result<Option<String>> {
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

pub(super) fn string_prefix(
    string_node: &Node,
    context: &DocumentContext,
) -> anyhow::Result<Option<String>> {
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

pub(super) fn captured_quoted_prefix<'a>(captures: &'a regex::Captures<'a>) -> Option<&'a str> {
    captures
        .name("prefix_double")
        .or_else(|| captures.name("prefix_single"))
        .map(|capture| capture.as_str())
}

pub(super) fn comparison_string_target_read_expr(line_prefix: &str) -> Option<(String, String)> {
    static TARGET_READ_COMPARISON_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?:(?:[A-Za-z.][A-Za-z0-9._]*)(?:::|::))?tar_read\s*
            \(\s*(?:name\s*=\s*)?
            (?:
                "(?P<target_double>[^"]+)"
                |
                '(?P<target_single>[^']+)'
                |
                (?P<target_bare>[A-Za-z.][A-Za-z0-9._]*)
            )
            \s*\)
            \s*\$\s*(?P<column>[A-Za-z.][A-Za-z0-9._]*)\s*(?:==|!=)\s*
            (?:
                "(?P<prefix_double>[^"]*)
                |
                '(?P<prefix_single>[^']*)
            )$
            "#,
        )
        .unwrap()
    });

    let captures = TARGET_READ_COMPARISON_RE.captures(line_prefix)?;
    let target_name = captures
        .name("target_double")
        .or_else(|| captures.name("target_single"))
        .or_else(|| captures.name("target_bare"))?
        .as_str();
    let column = captures.name("column")?.as_str();
    let value_prefix = captured_quoted_prefix(&captures)?;
    let expr = format!(
        "({})[[\"{}\"]]",
        target_read_object_expr(target_name),
        escape_r_string(column)
    );

    Some((
        comparison_values_completion_expr(expr.as_str()),
        String::from(value_prefix),
    ))
}

pub(super) fn comparison_string_expr(line_prefix: &str) -> Option<(String, String)> {
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
            \s*(?:==|!=)\s*
            (?:
                "(?P<prefix_double>[^"]*)
                |
                '(?P<prefix_single>[^']*)
            )$
            "#,
        )
        .unwrap()
    });

    let captures = COMPARISON_STRING_RE.captures(line_prefix)?;
    let expr = captures.name("expr")?.as_str();
    let value_prefix = captured_quoted_prefix(&captures)?;

    Some((
        comparison_values_completion_expr(expr),
        String::from(value_prefix),
    ))
}

pub(super) fn comparison_string_data_table_expr(line_prefix: &str) -> Option<(String, String)> {
    static DATA_TABLE_COMPARISON_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r#"(?x)
            (?P<table>[A-Za-z.][A-Za-z0-9._]*)\s*
            \[
            \s*(?P<column>[A-Za-z.][A-Za-z0-9._]*)\s*(?:==|!=)\s*
            (?:
                "(?P<prefix_double>[^"]*)
                |
                '(?P<prefix_single>[^']*)
            )$
            "#,
        )
        .unwrap()
    });

    let captures = DATA_TABLE_COMPARISON_RE.captures(line_prefix)?;
    let table = captures.name("table")?.as_str();
    let column = captures.name("column")?.as_str();
    let value_prefix = captured_quoted_prefix(&captures)?;

    let expr = format!("({})[[\"{}\"]]", table, escape_r_string(column),);

    Some((
        comparison_values_completion_expr(expr.as_str()),
        String::from(value_prefix),
    ))
}

pub(super) fn find_string_subset_object<'tree>(
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

pub(super) fn find_subset_node<'tree>(
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

pub(super) fn node_is_c_call(node: &Node, contents: &str) -> bool {
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

pub(super) fn subset_contains_point(point: &Point, subset_node: &Node) -> bool {
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

pub(super) fn locate_bridge_hover_node<'tree>(
    context: &'tree DocumentContext,
) -> Option<Node<'tree>> {
    let root = context.document.ast.root_node();
    let mut node = root.find_closest_node_to_point(context.point)?;

    while !node.is_identifier() && !node.is_string() && !node.is_keyword() {
        if let Some(sibling) = node.prev_sibling() {
            node = sibling;
        } else {
            node = node.parent()?;
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

pub(super) fn extract_operator_node<'tree>(
    node: Node<'tree>,
    parent: Node<'tree>,
) -> Option<Node<'tree>> {
    if !matches!(parent.node_type(), NodeType::ExtractOperator(_)) {
        return None;
    }

    match node.node_type() {
        NodeType::Anonymous(operator) if matches!(operator.as_str(), "$" | "@") => Some(parent),
        NodeType::Identifier if parent.child_by_field_name("rhs") == Some(node) => Some(parent),
        _ => None,
    }
}

pub(super) fn namespace_operator_from_colons<'tree>(
    node: Node<'tree>,
    point: Point,
) -> Option<Node<'tree>> {
    if node.end_position() != point {
        return None;
    }

    let parent = node.parent()?;
    if !matches!(parent.node_type(), NodeType::NamespaceOperator(_)) {
        return None;
    }

    Some(parent)
}

pub(super) fn namespace_operator_from_identifier<'tree>(node: Node<'tree>) -> Option<Node<'tree>> {
    let parent = node.parent()?;
    if !parent.is_namespace_operator() {
        return None;
    }

    if parent.child_by_field_name("lhs") == Some(node) {
        return None;
    }

    Some(parent)
}

pub(super) fn namespace_completion_expr(package: &str, exports_only: bool) -> String {
    let package = package.replace('\\', "\\\\").replace('"', "\\\"");

    if exports_only {
        return format!(
            "local({{ .x <- getNamespaceExports(\"{package}\"); stats::setNames(vector(\"list\", length(.x)), .x) }})"
        );
    }

    format!("as.list(asNamespace(\"{package}\"), all.names = TRUE)")
}

pub(super) fn signature_parameter_label(member: &BridgeMember) -> String {
    if member.summary.is_empty() || member.summary == "<required>" {
        return member.name_display.clone();
    }

    format!("{} = {}", member.name_display, member.summary)
}

pub(super) fn browser_aware_symbol_lookup_envs_expr() -> &'static str {
    concat!(
        ".self <- environment(); ",
        ".ns <- tryCatch(asNamespace(\"arkbridge\"), error = function(e) NULL); ",
        ".frames <- sys.frames(); ",
        ".browser_envs <- list(); ",
        "for (.env in .frames) { ",
        "if (identical(.env, .self) || identical(.env, globalenv()) || ",
        "identical(.env, baseenv()) || identical(.env, emptyenv())) next; ",
        ".top <- topenv(.env); ",
        "if (!is.null(.ns) && identical(.top, .ns)) break; ",
        ".browser_envs[[length(.browser_envs) + 1L]] <- .env ",
        "}; ",
        "if (length(.browser_envs)) .browser_envs <- rev(.browser_envs); ",
        ".envs <- c(.browser_envs, lapply(search(), as.environment)); ",
    )
}

pub(super) fn search_path_completion_expr(prefix: Option<&str>) -> String {
    let mut expr = String::from("local({ ");
    expr.push_str(browser_aware_symbol_lookup_envs_expr());
    if let Some(prefix) = prefix.filter(|prefix| !prefix.is_empty()) {
        expr.push_str(".prefix <- tolower(\"");
        expr.push_str(escape_r_string(prefix).as_str());
        expr.push_str("\"); ");
        expr.push_str(concat!(
            ".names <- unique(unlist(lapply(.envs, function(.env) { ",
            ".x <- ls(envir = .env, all.names = TRUE); ",
            ".x[startsWith(tolower(.x), .prefix)] ",
            "}), use.names = FALSE)); ",
        ));
    } else {
        expr.push_str(
            ".names <- unique(unlist(lapply(.envs, ls, all.names = TRUE), use.names = FALSE)); ",
        );
    }
    expr.push_str(concat!(
        ".out <- stats::setNames(vector(\"list\", length(.names)), .names); ",
        "attr(.out, \"rscope_source_class\") <- \"symbol_lookup_envs\"; ",
        "attr(.out, \"rscope_lookup_envs\") <- .envs; ",
        ".out ",
        "})",
    ));
    expr
}

pub(super) fn prioritized_empty_search_path_completion_expr() -> String {
    let mut expr = String::from("local({ ");
    expr.push_str(browser_aware_symbol_lookup_envs_expr());
    expr.push_str(concat!(
        ".names <- unique(unlist(lapply(.envs, ls, all.names = TRUE), use.names = FALSE)); ",
        ".find_env <- function(.name) { ",
        "for (.env in .envs) { ",
        "if (exists(.name, envir = .env, inherits = FALSE)) return(.env) ",
        "}; ",
        "NULL ",
        "}; ",
        ".is_function <- vapply(.names, function(.name) { ",
        ".env <- .find_env(.name); ",
        "if (is.null(.env)) return(FALSE); ",
        ".value <- tryCatch(get(.name, envir = .env, inherits = FALSE), error = function(e) NULL); ",
        "is.function(.value) ",
        "}, logical(1)); ",
        ".is_hidden <- startsWith(.names, \".\") | grepl(\"rscope\", .names, fixed = TRUE); ",
        ".names <- c(.names[!.is_hidden & !.is_function], ",
        ".names[!.is_hidden & .is_function], ",
        ".names[.is_hidden & !.is_function], ",
        ".names[.is_hidden & .is_function]); ",
        ".out <- stats::setNames(vector(\"list\", length(.names)), .names); ",
        "attr(.out, \"rscope_source_class\") <- \"symbol_lookup_envs\"; ",
        "attr(.out, \"rscope_lookup_envs\") <- .envs; ",
        ".out ",
        "})",
    ));
    expr
}

pub(super) fn matrix_subset_completion_expr(expr: &str) -> String {
    let expr = expr.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "local({{ .x <- tryCatch(colnames(({expr})), error = function(e) NULL); if (is.null(.x)) .x <- character(); stats::setNames(vector(\"list\", length(.x)), .x) }})"
    )
}

pub(super) fn comparison_values_completion_expr(expr: &str) -> String {
    format!(
        "local({{ .x <- tryCatch(({expr}), error = function(e) NULL); if (is.null(.x)) {{ stats::setNames(list(), character()) }} else {{ .vals <- if (is.factor(.x)) {{ levels(.x) }} else if (is.character(.x)) {{ unique(.x) }} else {{ character() }}; .vals <- .vals[!is.na(.vals)]; .vals <- unique(as.character(.vals)); .vals <- utils::head(.vals, 200L); stats::setNames(vector(\"list\", length(.vals)), .vals) }} }})"
    )
}

pub(super) fn installed_packages_completion_expr() -> String {
    String::from(
        "local({ .x <- base::.packages(all.available = TRUE); stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

pub(super) fn option_names_completion_expr() -> String {
    String::from(
        "local({ .x <- names(options()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

pub(super) fn env_names_completion_expr() -> String {
    String::from(
        "local({ .x <- names(Sys.getenv()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) })",
    )
}

pub(super) fn target_names_completion_expr(project: Option<&TargetCompletionProject>) -> String {
    let Some(project) = project else {
        return String::from(
            "local({ if (!requireNamespace(\"targets\", quietly = TRUE)) { stats::setNames(list(), character()) } else { .x <- tryCatch(targets::tar_manifest(), error = function(e) NULL); .names <- if (is.null(.x) || is.null(.x$name)) character() else as.character(.x$name); .names <- .names[!is.na(.names)]; stats::setNames(vector(\"list\", length(.names)), .names) } })",
        );
    };

    format!(
        "local({{ if (!requireNamespace(\"targets\", quietly = TRUE)) {{ stats::setNames(list(), character()) }} else {{ .old <- getwd(); on.exit(setwd(.old), add = TRUE); if (dir.exists(\"{}\")) setwd(\"{}\"); .x <- tryCatch(targets::tar_manifest(script = \"{}\"), error = function(e) NULL); .names <- if (is.null(.x) || is.null(.x$name)) character() else as.character(.x$name); .names <- .names[!is.na(.names)]; stats::setNames(vector(\"list\", length(.names)), .names) }} }})",
        escape_r_string(project.root.as_str()),
        escape_r_string(project.root.as_str()),
        escape_r_string(project.script.as_str())
    )
}

pub(super) fn call_formals_completion_expr(callee: &str) -> String {
    format!(
        "local({{ .x <- tryCatch(names(formals({callee})), error = function(e) character()); .x <- .x[!is.na(.x)]; stats::setNames(vector(\"list\", length(.x)), .x) }})"
    )
}

pub(super) fn literal_character_choices_completion_expr(callee: &str, formal_name: &str) -> String {
    let formal_name = escape_r_string(formal_name);

    format!(
        "local({{ .f <- tryCatch(formals({callee}), error = function(e) NULL); if (is.null(.f)) {{ stats::setNames(list(), character()) }} else {{ .arg <- .f[[\"{formal_name}\"]]; .vals <- character(); if (is.character(.arg)) {{ .vals <- .arg }} else if (is.call(.arg) && length(.arg) >= 2L && identical(.arg[[1]], as.name(\"c\"))) {{ .elts <- as.list(.arg)[-1]; if (length(.elts) && all(vapply(.elts, function(x) is.character(x) && length(x) == 1L, logical(1)))) {{ .vals <- unlist(.elts, use.names = FALSE) }} }}; .vals <- .vals[!is.na(.vals)]; .vals <- unique(as.character(.vals)); stats::setNames(vector(\"list\", length(.vals)), .vals) }} }})"
    )
}

pub(super) fn browser_locals_completion_expr(prefix: &str) -> String {
    let prefix = escape_r_string(prefix);

    format!(
        "local({{ .prefix <- \"{prefix}\"; .frames <- sys.frames(); .target <- NULL; for (.env in .frames) {{ .names <- tryCatch(ls(envir = .env, all.names = TRUE), error = function(e) character()); if (length(.names) && any(startsWith(tolower(.names), tolower(.prefix)))) {{ .target <- .env; break }} }}; if (is.null(.target)) {{ stats::setNames(list(), character()) }} else {{ .names <- ls(envir = .target, all.names = TRUE); .out <- stats::setNames(vector(\"list\", length(.names)), .names); attr(.out, \"rscope_source_class\") <- \"symbol_lookup_envs\"; attr(.out, \"rscope_lookup_envs\") <- list(.target); .out }} }})"
    )
}

pub(super) fn browser_context_completion_expr() -> &'static str {
    // IPC requests at a normal prompt start in arkbridge frames. A browser
    // prompt additionally preserves the frame being debugged before the
    // arkbridge request handler appears on the stack.
    concat!(
        "local({ ",
        ".self <- environment(); ",
        ".ns <- tryCatch(asNamespace(\"arkbridge\"), error = function(e) NULL); ",
        ".frames <- sys.frames(); ",
        ".active <- FALSE; ",
        "for (.env in .frames) { ",
        "if (identical(.env, .self) || identical(.env, globalenv()) || ",
        "identical(.env, baseenv()) || identical(.env, emptyenv())) next; ",
        ".top <- topenv(.env); ",
        "if (!is.null(.ns) && identical(.top, .ns)) break; ",
        ".active <- TRUE; ",
        "break ",
        "}; ",
        "if (.active) stats::setNames(list(TRUE), \".ark_browser_context\") ",
        "else stats::setNames(list(), character()) ",
        "})",
    )
}

pub(super) fn pipe_root_text_expr(context: &DocumentContext) -> Option<String> {
    static PIPE_ROOT_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(?x)^\s*(?P<expr>[A-Za-z.][A-Za-z0-9._]*)\s*(?:\|>|%>%)"#).unwrap()
    });

    let line = context.document.get_line(context.point.row)?;
    let prefix = line.chars().take(context.point.column).collect::<String>();
    let captures = PIPE_ROOT_RE.captures(prefix.as_str())?;

    Some(captures.name("expr")?.as_str().to_string())
}

pub(super) fn escape_r_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(super) fn escape_r_double_quoted(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(super) fn subset_insert_text(
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

pub(super) fn is_data_table_like(classes: Option<&[String]>) -> bool {
    classes
        .into_iter()
        .flatten()
        .any(|class| class == "data.table")
}

pub(super) fn is_matrix_like(object_meta: Option<&ObjectMeta>) -> bool {
    let Some(object_meta) = object_meta else {
        return false;
    };

    object_meta
        .class
        .iter()
        .any(|class| matches!(class.as_str(), "matrix" | "array"))
}

pub(super) fn is_internal_browser_name(name: &str) -> bool {
    name.starts_with('.') || name.contains("rscope")
}
