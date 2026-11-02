use anyhow::anyhow;
use tower_lsp::lsp_types::TextEdit;

use crate::lsp::backend::LspError;
use crate::lsp::backend::LspResult;
use crate::lsp::config::IndentStyle;
use crate::lsp::config::IndentationConfig;
use crate::lsp::document::Document;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;

/// Provide indentation corrections
///
/// Hooked up to format-on-type for newline characters.
///
/// This is not a full indenter yet. We only provide corrections for the
/// Positron frontend when the VS Code regexp-based indenting rules are not able
/// to indent as expected. For instance we reindent pipeline components to
/// ensure alignment and avoid a staircase effect.
///
/// Once we implement a full formatter, indentation will be provided for any
/// constructs based on the formatter and will be fully consistent with it.
pub(crate) fn indent_edit(doc: &Document, line: usize) -> LspResult<Option<Vec<TextEdit>>> {
    let text = &doc.contents;
    let ast = &doc.ast;
    let config = &doc.config.indent;

    let line_count = if text.is_empty() {
        1
    } else {
        // Note that `lines().count()` doesn't count trailing newlines
        text.chars().filter(|c| *c == '\n').count() + 1
    };
    if line >= line_count {
        return Err(LspError::Anyhow(anyhow!("`line` is OOB")));
    }

    let indent_pos = tree_sitter::Point {
        row: line,
        column: 0,
    };

    let node = ast.root_node().find_smallest_spanning_node(indent_pos);

    // FIXME: Remove this as soon as https://github.com/r-lib/tree-sitter-r/pull/126
    // is merged and we have synced with upstream tree-sitter-r.
    // Due to a tree-sitter-r bug, if there are leading newlines in a document, they are
    // consumed before the `program` node is created, meaning that rows at the beginning
    // of a document before the first token can look OOB and won't be contained by any
    // node. There should be no indent adjustment required in these cases.
    if node.is_none() {
        return Ok(None);
    }

    let node = node.unwrap(); // Can only happen if `line` is OOB, which it isn't

    // Get the parent node of the beginning of line
    let mut bol_parent = node;
    while bol_parent.start_position().row == line {
        if let Some(parent) = bol_parent.parent() {
            bol_parent = parent;
        } else {
            break;
        }
    }

    // log::trace!("node: {node:?}");
    // log::trace!("bol_parent: {bol_parent:?}");

    // Iterator over characters following `line`'s indent
    let text_at_indent = || {
        text.lines()
            .nth(line)
            .map(|line_text| line_text.chars().skip_while(|c| *c == ' ' || *c == '\t'))
            .into_iter()
            .flatten()
    };

    // The indentation of the line the node starts on
    let node_line_indent = |point: tree_sitter::Node| -> usize {
        line_indent(text, point.start_position().row, config).0
    };
    let brace_parent_indent =
        |node: tree_sitter::Node| -> usize { node_line_indent(brace_parent(node)) };

    let brace_indent = |parent: tree_sitter::Node| -> (usize, usize) {
        // If we're looking at a closing delimiter, indent at the parent's
        // beginning of line
        if let Some(c) = text_at_indent().next() {
            if c == '}' {
                return (brace_parent_indent(parent), 0);
            }
            // else fallthrough
        };

        (brace_parent_indent(parent), config.indent_size)
    };

    let (old_indent, old_indent_byte) = line_indent(text, line, config);

    // Whether the first non-blank character of `row` is inside a string that
    // starts on an earlier row. Its indentation is string content, not code
    // indentation.
    let starts_in_string = |within: tree_sitter::Node, row: usize| -> bool {
        let point = tree_sitter::Point {
            row,
            column: line_indent(text, row, config).1,
        };
        let Some(node) = within.descendant_for_point_range(point, point) else {
            return false;
        };
        let in_string = node
            .ancestors()
            .any(|node| node.is_string() && node.start_position().row < row);
        in_string
    };

    // Indentation of a line where an argument or parameter goes. Starts one
    // level past the line of the opening delimiter, but doesn't add back
    // indentation removed on a line where the previous argument starts or
    // ends, as in:
    //
    // ```r
    // fun_call(parameter = (
    //   stuff
    // ),
    // argument)
    // ```
    //
    // The line of the opening delimiter is excluded because it sets the
    // anchor rather than the indentation of arguments.
    let argument_line_indent = |parent: tree_sitter::Node, anchor: usize| -> (usize, usize) {
        let open_row = parent.start_position().row;

        let prev = parent
            .children(&mut parent.walk())
            .filter(|child| {
                (child.is_argument() || child.node_type() == NodeType::Parameter) &&
                    child.end_position().row < line
            })
            .last();

        let prev_indent = prev
            .into_iter()
            .flat_map(|prev| {
                [prev.start_position().row, prev.end_position().row]
                    .into_iter()
                    .filter(|row| *row > open_row)
                    .filter(move |row| !starts_in_string(prev, *row))
            })
            .map(|row| line_indent(text, row, config).0)
            .min();

        let Some(prev_indent) = prev_indent.filter(|indent| *indent < anchor + config.indent_size)
        else {
            return (anchor, config.indent_size);
        };

        (prev_indent, 0)
    };

    let arguments_indent = |parent: tree_sitter::Node| -> (usize, usize) {
        let anchor = node_line_indent(parent);

        let line_start = tree_sitter::Point {
            row: line,
            column: old_indent_byte,
        };
        let Some(close) = parent
            .child_by_field_name("close")
            .filter(|close| !close.is_missing() && close.start_position() == line_start)
        else {
            return argument_line_indent(parent, anchor);
        };

        // A closing delimiter preceded by a trailing comma is where the next
        // argument goes: hitting Enter in `f(x,|)`, with `)` auto-closed by
        // the frontend, leaves the cursor in front of `)`.
        let mut prev = close.prev_sibling();
        while let Some(node) = prev.filter(|node| node.is_comment()) {
            prev = node.prev_sibling();
        }
        if prev.is_some_and(|node| node.node_type() == NodeType::Comma) {
            return argument_line_indent(parent, anchor);
        }

        (anchor, 0)
    };

    // Structured in two stages as in Emacs TS rules: first match, then
    // return anchor and indent size. We can add more rules here as needed.
    let (anchor, indent) = match bol_parent {
        // Indentation of top-level expressions. Fixes some problematic
        // outdents:
        // https://github.com/posit-dev/positron/issues/1880
        // https://github.com/posit-dev/positron/issues/2764
        parent if parent.is_program() => (parent.start_position().column, 0),
        parent if parent.is_braced_expression() => brace_indent(parent),

        // Indentation of chained operators (aka pipelines):
        // https://github.com/posit-dev/positron/issues/2707
        parent if parent.is_binary_operator() => {
            let anchor = node
                .ancestors()
                .find(|n| n.parent().is_none_or(|p| !p.is_binary_operator()))
                .unwrap_or(parent); // Should not happen

            (node_line_indent(anchor), config.indent_size)
        },

        // Indentation of arguments in calls and subsets, and of parameters in
        // function definitions, relative to the line of the opening delimiter:
        // https://github.com/posit-dev/positron/issues/5754
        //
        // Hitting Enter in `function(a,|)` is not covered: R doesn't allow a
        // trailing comma in parameters, so tree-sitter parses the `)` as an
        // `ERROR` and there is no `parameters` node to match.
        parent if parent.is_arguments() || parent.node_type() == NodeType::Parameters => {
            arguments_indent(parent)
        },

        _ => {
            // Find nearest containing braced expression or top-level node. We'll use
            // that to prevent ever indenting past these in unhandled cases for which we
            // don't have rules yet: https://github.com/posit-dev/positron/issues/1683

            // First climb one level if cursor is in front of a `{` character.
            // In that case `node` is the `{` token which is an immediate child
            // of the containing `{` expression. We want to indent that braced
            // expression relative to the next enclosing `{` expression.
            let mut node = node;
            if let Some(c) = text_at_indent().next() {
                if c == '{' {
                    if let Some(parent) = node.parent() {
                        node = parent;
                    }
                }
            }

            // Find nearest enclosing brace. If there is none, just use current indentation.
            let Some(enclosing_brace) = find_enclosing_brace(node) else {
                return Ok(None);
            };
            let (anchor, indent) = brace_indent(enclosing_brace);

            // Only correct if we're too far on the left, past the indentation
            // implied by the enclosing brace
            let min_indent = anchor + indent;
            if old_indent >= min_indent {
                return Ok(None);
            }

            (anchor, indent)
        },
    };

    let new_indent = anchor + indent;

    if old_indent == new_indent {
        return Ok(None);
    }

    let new_text = new_line_indent(config, new_indent);

    let range = tree_sitter::Range {
        start_byte: 0, // Not used by lsp_range_from_tree_sitter_range
        end_byte: 0,   // Not used by lsp_range_from_tree_sitter_range
        start_point: tree_sitter::Point {
            row: line,
            column: 0,
        },
        end_point: tree_sitter::Point {
            row: line,
            column: old_indent_byte,
        },
    };

    let edit = TextEdit {
        range: doc.lsp_range_from_tree_sitter_range(range)?,
        new_text,
    };

    let mut edits = vec![edit];

    // Indent closing delimiter to mitigate VS Code's indent-outdent behaviour
    // https://github.com/posit-dev/positron/issues/3484
    if bol_parent.is_braced_expression() {
        // FIXME: Use named delim node once available
        let n = bol_parent.child_count();
        if n > 1 {
            let close = bol_parent.child(n - 1).unwrap();
            let close_line = close.start_position().row;

            if close.node_type() == NodeType::Anonymous("}".into()) && close_line > line {
                if let Some(ref mut close_edits) = indent_edit(doc, close_line)? {
                    edits.append(close_edits);
                }
            }
        }
    }

    Ok(Some(edits))
}

fn brace_parent(node: tree_sitter::Node) -> tree_sitter::Node {
    let Some(parent) = node.parent() else {
        return node;
    };

    match parent.node_type() {
        NodeType::FunctionDefinition => parent,
        NodeType::IfStatement => parent,
        NodeType::ForStatement => parent,
        NodeType::WhileStatement => parent,
        NodeType::RepeatStatement => parent,
        _ => node,
    }
}

/// Returns indent as a pair of space size and byte size
pub fn line_indent(text: &str, line: usize, config: &IndentationConfig) -> (usize, usize) {
    let mut byte_indent = 0;
    let mut indent = 0;

    let Some(line_text) = text.lines().nth(line) else {
        return (0, 0);
    };

    for next_char in line_text.chars() {
        if next_char == ' ' {
            indent += 1;
            byte_indent += 1;
            continue;
        } else if next_char == '\t' {
            indent += config.tab_width;
            byte_indent += 1;
            continue;
        }
        break;
    }

    (indent, byte_indent)
}

pub fn new_line_indent(config: &IndentationConfig, indent: usize) -> String {
    match config.indent_style {
        IndentStyle::Space => String::from(' ').repeat(indent),
        IndentStyle::Tab => {
            let n_tabs = indent / config.tab_width;
            let n_spaces = indent % config.tab_width;
            String::from('\t').repeat(n_tabs) + &String::from(' ').repeat(n_spaces)
        },
    }
}

/// Find the nearest node that is a braced expression
pub fn find_enclosing_brace(node: tree_sitter::Node) -> Option<tree_sitter::Node> {
    if let Some(parent) = node.parent() {
        parent.ancestors().find(|n| n.is_braced_expression())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use aether_lsp_utils::proto::from_proto;
    use stdext::assert_match;
    use tower_lsp::lsp_types::TextEdit;

    use crate::lsp::config::IndentStyle;
    use crate::lsp::config::IndentationConfig;
    use crate::lsp::document::Document;
    use crate::lsp::indent::indent_edit;
    use crate::lsp::indent::new_line_indent;

    fn apply_text_edits(edits: Vec<TextEdit>, doc: &mut Document) {
        from_proto::apply_text_edits(
            &mut doc.contents,
            edits,
            &mut doc.line_index,
            doc.position_encoding,
        );
        *doc = test_doc(&doc.contents);
    }

    // NOTE: If we keep adding tests we might want to switch to snapshot tests

    const SPACE_CFG: IndentationConfig = IndentationConfig {
        indent_style: IndentStyle::Space,
        indent_size: 2,
        tab_width: 2,
    };

    fn test_doc(text: &str) -> Document {
        let mut doc = Document::new(text, None);
        doc.config.indent = SPACE_CFG;
        doc
    }

    #[test]
    fn test_line_indent_oob() {
        let doc = test_doc("");
        assert_match!(indent_edit(&doc, 1), Err(_));

        let doc = test_doc("\n");
        assert_match!(indent_edit(&doc, 2), Err(_));
    }

    #[test]
    fn test_line_indent_leading_whitespace() {
        // Indent should be unchanged regardless of how much leading whitespace
        // there is before the first newline
        // https://github.com/posit-dev/positron/issues/5258
        let text = String::from("  \nx");
        let doc = test_doc(&text);
        let edit = indent_edit(&doc, 1).unwrap();
        assert!(edit.is_none());

        let text = String::from("\r\nx");
        let doc = test_doc(&text);
        let edit = indent_edit(&doc, 1).unwrap();
        assert!(edit.is_none());
    }

    #[test]
    fn test_line_indent_chains() {
        let mut doc = test_doc("foo +\n  bar +\n    baz + qux |>\nfoofy()");

        // Indenting the first two lines doesn't change the text
        assert_match!(indent_edit(&doc, 0), Ok(None));
        assert_match!(indent_edit(&doc, 1), Ok(None));

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo +\n  bar +\n  baz + qux |>\nfoofy()");

        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo +\n  bar +\n  baz + qux |>\n  foofy()");
    }

    #[test]
    fn test_line_indent_chains_trailing_space() {
        let mut doc = test_doc("foo +\n  bar(\n    x\n  ) +\n    baz\n  ");

        let edit = indent_edit(&doc, 4).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo +\n  bar(\n    x\n  ) +\n  baz\n  ");
    }

    #[test]
    fn test_line_indent_chains_outdent() {
        let text = String::from("1 +\n  2\n");
        let doc = test_doc(&text);

        assert_match!(indent_edit(&doc, 2), Ok(None));
    }

    #[test]
    fn test_line_indent_chains_deep() {
        let mut doc = test_doc("deep()()[] +\n    deep()()[]");

        let edit = indent_edit(&doc, 0).unwrap();
        assert!(edit.is_none());

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "deep()()[] +\n  deep()()[]");
    }

    #[test]
    fn test_line_indent_chains_deep_newlines() {
        // With newlines in the way
        let mut doc = test_doc("deep(\n)()[] +\ndeep(\n)()[]");

        let edit = indent_edit(&doc, 0).unwrap();
        assert!(edit.is_none());

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "deep(\n)()[] +\n  deep(\n)()[]");
    }

    #[test]
    fn test_line_indent_chains_calls() {
        let mut doc = test_doc("foo() +\n  bar() +\nbaz()");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo() +\n  bar() +\n  baz()");

        // Indenting the first two lines doesn't change the text
        let edit = indent_edit(&doc, 0).unwrap();
        assert!(edit.is_none());

        let edit = indent_edit(&doc, 1).unwrap();
        assert!(edit.is_none());

        let doc = test_doc("foo(\n) +\n  bar");
        let edit = indent_edit(&doc, 0).unwrap();
        assert!(edit.is_none());
    }

    #[test]
    fn test_line_indent_braced_expression() {
        let mut doc = test_doc("{\nbar\n}");

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "{\n  bar\n}");

        let mut doc = test_doc("function() {\nbar\n}");

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function() {\n  bar\n}");
    }

    #[test]
    fn test_line_indent_braced_expression_closing() {
        let mut doc = test_doc("{\n  }");

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "{\n}");
    }

    #[test]
    fn test_line_indent_braced_expression_closing_multiline() {
        // https://github.com/posit-dev/positron/issues/3484
        let mut doc = test_doc("{\n\n    }");

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "{\n  \n}");
    }

    #[test]
    fn test_line_indent_braced_expression_multiline() {
        let mut doc = test_doc("function(\n        ) {\nfoo\n}");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function(\n        ) {\n  foo\n}");
    }

    #[test]
    fn test_line_indent_braced_expression_multiline_empty() {
        let mut doc = test_doc("function(\n        ) {\n\n}");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function(\n        ) {\n  \n}");
    }

    #[test]
    fn test_line_indent_minimum() {
        // https://github.com/posit-dev/positron/issues/1683
        let mut doc = test_doc("function() {\n  ({\n  }\n)\n}");

        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function() {\n  ({\n  }\n  )\n}");
    }

    #[test]
    fn test_line_indent_minimum_nested() {
        // Nested R function test with multiple levels of nesting
        let mut doc = test_doc("{\n  {\n    ({\n    }\n  )\n  }\n}");

        let edit = indent_edit(&doc, 4).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "{\n  {\n    ({\n    }\n    )\n  }\n}");
    }

    #[test]
    fn test_line_indent_function_opening_brace_own_line() {
        let text = String::from("object <- function()\n{\n  body\n}");
        let doc = test_doc(&text);

        assert_match!(indent_edit(&doc, 1).unwrap(), None);
    }

    #[test]
    fn test_line_indent_arguments() {
        // https://github.com/posit-dev/positron/issues/5754
        let mut doc = test_doc("mtcars |>\n  ggplot(aes(x = qsec,\n  y = hp))");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(
            doc.contents,
            "mtcars |>\n  ggplot(aes(x = qsec,\n    y = hp))"
        );
    }

    #[test]
    fn test_line_indent_arguments_closing_after_comma() {
        // Enter after `x = qsec,` with auto-closed delimiters
        let mut doc = test_doc("mtcars |>\n  ggplot(aes(x = qsec,\n  ))");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "mtcars |>\n  ggplot(aes(x = qsec,\n    ))");

        // Also with a comment in between
        let mut doc = test_doc("foo(x, # comment\n)");

        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(x, # comment\n  )");
    }

    #[test]
    fn test_line_indent_arguments_after_outdent() {
        let text = String::from("fun_call(parameter = (\n  stuff\n),\nargument)");
        let doc = test_doc(&text);
        assert_match!(indent_edit(&doc, 3), Ok(None));

        let mut doc = test_doc("fun_call(function() {\n  body\n},\n    argument)");
        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "fun_call(function() {\n  body\n},\nargument)");

        // A previous argument at the regular indentation doesn't lower it
        let mut doc = test_doc("foo(\n  bar(\n    x\n  ),\nbaz)");
        let edit = indent_edit(&doc, 4).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\n  bar(\n    x\n  ),\n  baz)");

        // The previous argument starts on an outdented line but ends on a
        // line at the regular indentation
        let mut doc = test_doc("foo(\na = bar(\n  x\n  ),\n    b)");
        let edit = indent_edit(&doc, 4).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\na = bar(\n  x\n  ),\nb)");
    }

    #[test]
    fn test_line_indent_arguments_after_multiline_string() {
        // The string's last line is content, not an outdent
        let mut doc = test_doc("foo(\n  \"abc\ndef\",\nx)");
        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\n  \"abc\ndef\",\n  x)");

        // Raw string
        let mut doc = test_doc("foo(\n  r\"(abc\ndef)\",\nx)");
        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\n  r\"(abc\ndef)\",\n  x)");

        // The string starts on an outdented line, which still counts
        let mut doc = test_doc("foo(\na = \"abc\ndef\",\n  x)");
        let edit = indent_edit(&doc, 3).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\na = \"abc\ndef\",\nx)");

        // The string starts on the line of the opening delimiter
        let mut doc = test_doc("foo(\"abc\ndef\",\nx)");
        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "foo(\"abc\ndef\",\n  x)");
    }

    #[test]
    fn test_line_indent_parameters_after_outdent() {
        let mut doc = test_doc("function(\na = c(\n  1\n  ),\n    b) NULL");
        let edit = indent_edit(&doc, 4).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function(\na = c(\n  1\n  ),\nb) NULL");
    }

    #[test]
    fn test_line_indent_arguments_tabs() {
        // The closing delimiter is found by byte column while the anchor is
        // measured in display width
        let tab_cfg = IndentationConfig {
            indent_style: IndentStyle::Tab,
            indent_size: 2,
            tab_width: 4,
        };
        let mut doc = test_doc("mtcars |>\n\tggplot(aes(x = qsec,\n\t))");
        doc.config.indent = tab_cfg;
        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "mtcars |>\n\tggplot(aes(x = qsec,\n\t  ))");
    }

    #[test]
    fn test_line_indent_subset2() {
        let mut doc = test_doc("  x[[1,\n  ]]");
        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "  x[[1,\n    ]]");

        let mut doc = test_doc("  x[[1\n    ]]");
        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "  x[[1\n  ]]");
    }

    #[test]
    fn test_line_indent_arguments_omitted() {
        // No argument node precedes the closing delimiter, only a comma
        let mut doc = test_doc("x[,\n]");
        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "x[,\n  ]");
    }

    #[test]
    fn test_line_indent_parameters() {
        let mut doc = test_doc("  f <- function(a,\nb) {\n  }");
        let edit = indent_edit(&doc, 1).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "  f <- function(a,\n    b) {\n  }");

        let mut doc = test_doc("function(\n  a\n    ) {\n}");
        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "function(\n  a\n) {\n}");
    }

    #[test]
    fn test_line_indent_arguments_closing() {
        let mut doc = test_doc("  foo(\n    x\n    )");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "  foo(\n    x\n  )");

        let mut doc = test_doc("x[\n  1\n  ]");

        let edit = indent_edit(&doc, 2).unwrap().unwrap();
        apply_text_edits(edit, &mut doc);
        assert_eq!(doc.contents, "x[\n  1\n]");
    }

    #[test]
    fn test_new_line_indent() {
        let tab_cfg = IndentationConfig {
            indent_style: IndentStyle::Tab,
            indent_size: 4,
            tab_width: 4,
        };
        let large_tab_cfg = IndentationConfig {
            indent_style: IndentStyle::Tab,
            indent_size: 4,
            tab_width: 8,
        };

        assert_eq!(
            new_line_indent(&SPACE_CFG, 12),
            String::from(' ').repeat(12)
        );

        assert_eq!(new_line_indent(&tab_cfg, 7), String::from("\t   "));
        assert_eq!(new_line_indent(&tab_cfg, 8), String::from("\t\t"));
        assert_eq!(new_line_indent(&tab_cfg, 9), String::from("\t\t "));

        assert_eq!(
            new_line_indent(&large_tab_cfg, 7),
            String::from(' ').repeat(7)
        );
        assert_eq!(new_line_indent(&large_tab_cfg, 8), String::from("\t"));
        assert_eq!(new_line_indent(&large_tab_cfg, 12), String::from("\t    "));
    }

    #[test]
    fn test_indent_snapshot() {
        let orig = include_str!("snapshots/indent.R").to_string();

        let mut doc = test_doc(&orig);

        let n_lines = doc.contents.matches('\n').count();

        for i in 0..n_lines {
            if let Some(edit) = indent_edit(&doc, i).unwrap() {
                apply_text_edits(edit, &mut doc);
            }
        }

        if orig != doc.contents {
            panic!("Indentation snapshots have changed.\nPlease see git diff.");
        }
    }
}
