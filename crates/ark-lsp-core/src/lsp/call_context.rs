use tree_sitter::Node;
use tree_sitter::Point;

use crate::lsp::document_context::DocumentContext;
use crate::lsp::traits::node::NodeExt;
use crate::lsp::traits::point::PointExt;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;

#[derive(Clone, Debug)]
pub(crate) struct CallContext {
    pub(crate) active_argument: Option<String>,
    pub(crate) explicit_parameters: Vec<String>,
    pub(crate) num_unnamed_arguments: usize,
    pub(crate) callee: String,
}

#[derive(Clone, Copy)]
pub(crate) enum PackageCompletionMode {
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

pub(crate) fn analyze_call_context(
    context: &DocumentContext,
) -> anyhow::Result<Option<CallContext>> {
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

pub(crate) fn document_context_matches_package_argument(
    context: &DocumentContext,
    mode: PackageCompletionMode,
) -> anyhow::Result<bool> {
    let Some(call) = analyze_call_context(context)? else {
        return Ok(false);
    };

    Ok(call_matches_package_argument(&call, mode))
}

pub(crate) fn call_matches_package_argument(
    call: &CallContext,
    mode: PackageCompletionMode,
) -> bool {
    let Some(spec) = package_argument_spec(call.callee.as_str(), mode) else {
        return false;
    };

    match call.active_argument.as_deref() {
        Some(active_argument) => active_argument == spec.named_argument,
        None => call.num_unnamed_arguments == 0,
    }
}

pub(crate) fn text_matches_package_argument(
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
        spec.callee == callee &&
            match mode {
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
