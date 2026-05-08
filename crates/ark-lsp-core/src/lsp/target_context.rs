use crate::lsp::traits::node::NodeExt;
use crate::treesitter::NodeTypeExt;

pub(crate) fn target_reference_context(node: &tree_sitter::Node, contents: &str) -> bool {
    for ancestor in node.ancestors() {
        if !target_reference_call(&ancestor, contents) {
            continue;
        }

        let Some(function) = ancestor.child_by_field_name("function") else {
            return true;
        };
        return !node_is_inside(&function, node);
    }

    false
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

fn node_is_inside(container: &tree_sitter::Node, node: &tree_sitter::Node) -> bool {
    container.start_byte() <= node.start_byte() && node.end_byte() <= container.end_byte()
}
