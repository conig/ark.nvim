//
// help_topic.rs
//
// Copyright (C) 2023 Posit Software, PBC. All rights reserved.
//
//

use serde::Deserialize;
use serde::Serialize;
use tower_lsp::lsp_types::Position;
use tower_lsp::lsp_types::TextDocumentIdentifier;
use tree_sitter::Node;
use tree_sitter::Point;
use tree_sitter::Tree;

use crate::lsp;
use crate::lsp::backend::LspResult;
use crate::lsp::document::Document;
use crate::lsp::frontmatter::frontmatter_output_help_topic;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::BinaryOperatorType;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;
use crate::treesitter::UnaryOperatorType;

pub static ARK_HELP_TOPIC_REQUEST: &str = "ark/textDocument/helpTopic";

#[derive(Debug, Eq, PartialEq, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelpTopicParams {
    /// The document to provide a help topic for.
    pub text_document: TextDocumentIdentifier,
    /// The location of the cursor.
    pub position: Position,
}

#[derive(Debug, Eq, PartialEq, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelpTopicResponse {
    /// The help topic appropriate for the cursor position.
    pub topic: String,
}

pub(crate) fn help_topic(
    point: Point,
    document: &Document,
) -> LspResult<Option<HelpTopicResponse>> {
    let tree = &document.ast;

    if let Some(topic) = frontmatter_output_help_topic(document, point) {
        let response = HelpTopicResponse { topic };

        lsp::log_info!(
            "help_topic(): Using frontmatter output help topic '{}' at position {}",
            response.topic,
            point
        );

        return Ok(Some(response));
    }

    let Some(node) = locate_help_node(tree, point) else {
        lsp::log_warn!("help_topic(): No help node at position {point}");
        return Ok(None);
    };

    let text = help_topic_text(node, &document.contents)?;
    let response = HelpTopicResponse { topic: text };

    lsp::log_info!(
        "help_topic(): Using help topic '{}' at position {}",
        response.topic,
        point
    );

    Ok(Some(response))
}

fn locate_help_node(tree: &Tree, point: Point) -> Option<Node<'_>> {
    let root = tree.root_node();

    let mut node = root
        .find_smallest_spanning_node(point)
        .or_else(|| root.find_closest_node_to_point(point))?;

    if let Some(operator) = enclosing_help_operator(node) {
        return Some(operator);
    }

    // Find the nearest node that is an identifier.
    while !node.is_identifier() {
        if let Some(sibling) = node.prev_sibling() {
            // Move to an adjacent sibling if we can.
            node = sibling;
        } else {
            // If no sibling, check the parent.
            node = node.parent()?;
        }

        if let Some(operator) = enclosing_help_operator(node) {
            return Some(operator);
        }
    }

    if let Some(operator) = enclosing_help_operator(node) {
        return Some(operator);
    }

    // Check if this identifier is part of a namespace operator. If it is, we send
    // back the whole `pkg::fun` text, regardless of which side the user was on.
    // Even if they are at `p<>kg::fun`, we assume they really want docs for `fun`.
    let node = match node.parent() {
        Some(parent) if matches!(parent.node_type(), NodeType::NamespaceOperator(_)) => parent,
        Some(parent) if matches!(parent.node_type(), NodeType::ExtractOperator(_)) => parent,
        Some(_) => node,
        None => node,
    };

    Some(node)
}

fn enclosing_help_operator(node: Node<'_>) -> Option<Node<'_>> {
    node.ancestors().find(|node| is_help_operator(*node))
}

fn is_help_operator(node: Node<'_>) -> bool {
    matches!(
        node.node_type(),
        NodeType::UnaryOperator(UnaryOperatorType::Help) |
            NodeType::BinaryOperator(BinaryOperatorType::Help)
    )
}

fn help_topic_text(node: Node<'_>, contents: &str) -> LspResult<String> {
    match node.node_type() {
        NodeType::UnaryOperator(UnaryOperatorType::Help) => {
            let Some(rhs) = node.child_by_field_name("rhs") else {
                return Ok(node.node_to_string(contents)?);
            };

            help_operand_text(rhs, contents)
        },
        NodeType::BinaryOperator(BinaryOperatorType::Help) => {
            let Some(rhs) = node.child_by_field_name("rhs") else {
                return Ok(node.node_to_string(contents)?);
            };

            let topic = help_operand_text(rhs, contents)?;

            let Some(lhs) = node.child_by_field_name("lhs") else {
                return Ok(topic);
            };

            let package = help_operand_text(lhs, contents)?;
            if package.is_empty() {
                return Ok(topic);
            }

            Ok(format!("{package}::{topic}"))
        },
        _ => Ok(node.node_to_string(contents)?),
    }
}

fn help_operand_text(node: Node<'_>, contents: &str) -> LspResult<String> {
    if node.is_identifier_or_string() {
        return Ok(node.get_identifier_or_string_text(contents)?.to_string());
    }

    Ok(node.node_to_string(contents)?)
}

#[cfg(test)]
mod tests {
    use tower_lsp::lsp_types::Position;
    use tree_sitter::Parser;

    use crate::fixtures::point_from_cursor;
    use crate::lsp::document::Document;
    use crate::lsp::document::DocumentKind;
    use crate::lsp::help_topic::help_topic;
    use crate::lsp::help_topic::locate_help_node;
    use crate::lsp::traits::node::NodeExt;

    #[test]
    fn test_locate_help_node() {
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_r::LANGUAGE.into())
            .expect("failed to create parser");

        // (text cursor, expected help topic)
        let cases = vec![
            // On the RHS
            ("dplyr::ac@ross(x:y, sum)", "dplyr::across"),
            // On the LHS (Returns function help for `across()`, not package help for `dplyr`,
            // as we assume that is more useful for the user).
            ("dpl@yr::across(x:y, sum)", "dplyr::across"),
            // In the operator
            ("dplyr:@:across(x:y, sum)", "dplyr::across"),
            // Internal `:::`
            ("dplyr:::ac@ross(x:y, sum)", "dplyr:::across"),
            // R6 methods, or reticulate accessors
            ("tf$a@bs(x)", "tf$abs"),
            ("t@f$abs(x)", "tf$abs"),
            // With the package namespace
            ("tensorflow::tf$ab@s(x)", "tensorflow::tf$abs"),
            // Snake case function names should work across the identifier.
            ("@geom_point()", "geom_point"),
            ("ge@om_point()", "geom_point"),
            ("geom@_point()", "geom_point"),
            ("geom_@point()", "geom_point"),
            ("geom_point@()", "geom_point"),
        ];

        for (code, expected) in cases {
            let (text, point) = point_from_cursor(code);
            let tree = parser.parse(text.as_str(), None).unwrap();
            let node = locate_help_node(&tree, point).unwrap();
            let text = node.node_as_str(&text).unwrap();
            assert_eq!(text, expected);
        }
    }

    #[test]
    fn test_help_topic_supports_boundary_positions() {
        let document = Document::new("geom_point()", None);
        let cases = [
            Position::new(0, 0),
            Position::new(0, 4),
            Position::new(0, 5),
            Position::new(0, 10),
        ];

        for position in cases {
            let point = document
                .tree_sitter_point_from_lsp_position(position)
                .unwrap();
            let response = help_topic(point, &document)
                .unwrap()
                .expect("expected help topic response");
            assert_eq!(response.topic, "geom_point");
        }
    }

    #[test]
    fn test_help_topic_supports_unary_help_operator() {
        let cases = [
            ("@?geom_point", "geom_point"),
            ("?@geom_point", "geom_point"),
            ("?geom@_point", "geom_point"),
            ("?geom_point@", "geom_point"),
        ];

        for (code, expected) in cases {
            let (text, point) = point_from_cursor(code);
            let document = Document::new(&text, None);
            let position = document.lsp_position_from_tree_sitter_point(point).unwrap();

            let response = help_topic(point, &document)
                .unwrap()
                .unwrap_or_else(|| panic!("expected help topic response at {position:?}"));

            assert_eq!(response.topic, expected);
        }
    }

    #[test]
    fn test_help_topic_supports_binary_help_operator() {
        let cases = [
            ("@utils?help", "utils::help"),
            ("utils@?help", "utils::help"),
            ("utils?@help", "utils::help"),
            ("utils?help@", "utils::help"),
        ];

        for (code, expected) in cases {
            let (text, point) = point_from_cursor(code);
            let document = Document::new(&text, None);
            let position = document.lsp_position_from_tree_sitter_point(point).unwrap();

            let response = help_topic(point, &document)
                .unwrap()
                .unwrap_or_else(|| panic!("expected help topic response at {position:?}"));

            assert_eq!(response.topic, expected);
        }
    }

    #[test]
    fn test_help_topic_supports_frontmatter_output_renderer() {
        let (text, point) =
            point_from_cursor("---\ntitle: \"Report\"\noutput: revise::revise_letter_@pdf\n---\n");
        let document = Document::new_with_kind(&text, None, DocumentKind::LiterateR);

        let response = help_topic(point, &document)
            .unwrap()
            .expect("expected frontmatter output help topic response");

        assert_eq!(response.topic, "revise::revise_letter_pdf");
    }
}
