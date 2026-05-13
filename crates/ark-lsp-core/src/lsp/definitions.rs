//
// definitions.rs
//
// Copyright (C) 2022 Posit Software, PBC. All rights reserved.
//
//

use anyhow::Result;
use tower_lsp::lsp_types::GotoDefinitionParams;
use tower_lsp::lsp_types::GotoDefinitionResponse;
use tower_lsp::lsp_types::LocationLink;
use tower_lsp::lsp_types::Range;

use crate::lsp::document::Document;
use crate::lsp::indexer;
use crate::lsp::state::WorldState;
use crate::lsp::target_context::target_reference_context;
use crate::lsp::traits::node::NodeExt;
use crate::lsp::traits::point::PointExt;
use crate::treesitter::NodeTypeExt;

pub(crate) fn goto_definition(
    document: &Document,
    params: GotoDefinitionParams,
    state: &WorldState,
) -> Result<Option<GotoDefinitionResponse>> {
    // get reference to AST
    let ast = &document.ast;

    // try to find node at position
    let position = params.text_document_position_params.position;
    let point = document.tree_sitter_point_from_lsp_position(position)?;

    let Some(node) = definition_node_at_point(ast.root_node(), point) else {
        log::warn!("Failed to find the closest node to point {point}.");
        return Ok(None);
    };

    let start = document.lsp_position_from_tree_sitter_point(node.start_position())?;
    let end = document.lsp_position_from_tree_sitter_point(node.end_position())?;
    let range = Range { start, end };

    // Search for a reference in the document index
    if node.is_identifier_or_string() {
        let symbol = node.get_identifier_or_string_text(&document.contents)?;

        let uri = &params.text_document_position_params.text_document.uri;
        let info = if node.is_string() || target_reference_context(&node, &document.contents) {
            find_target_definition(symbol, uri, document, state)
        } else {
            find_symbol_definition(symbol, uri, document, state)
        };

        if let Some((file_id, entry)) = info {
            let target_uri = file_id.as_uri().clone();
            let link = LocationLink {
                origin_selection_range: None,
                target_uri,
                target_range: entry.range,
                target_selection_range: entry.range,
            };
            let response = GotoDefinitionResponse::Link(vec![link]);
            return Ok(Some(response));
        }
    }

    // TODO: We should see if we can find the referenced item in:
    //
    // 1. The document's current AST,
    // 2. The public functions from other documents in the project,
    // 3. A definition in the R session (which we could open in a virtual document)
    //
    // If we can't find a definition, then we can return the referenced item itself,
    // which will tell Positron to instead try to look for references for that symbol.
    let link = LocationLink {
        origin_selection_range: Some(range),
        target_uri: params.text_document_position_params.text_document.uri,
        target_range: range,
        target_selection_range: range,
    };

    let response = GotoDefinitionResponse::Link(vec![link]);
    Ok(Some(response))
}

fn definition_node_at_point<'tree>(
    root: tree_sitter::Node<'tree>,
    point: tree_sitter::Point,
) -> Option<tree_sitter::Node<'tree>> {
    let node = root.find_closest_node_to_point(point)?;

    if let Some(node) = node
        .ancestors()
        .find(|node| node.is_identifier_or_string() && node_contains_point(node, point))
    {
        return Some(node);
    }

    let Some(next) = node.next_leaf() else {
        return Some(node);
    };

    if point.is_after_or_equal(node.end_position()) &&
        next.start_position().row == point.row &&
        point.is_before_or_equal(next.start_position())
    {
        return next
            .ancestors()
            .find(|node| node.is_identifier_or_string())
            .or(Some(next));
    }

    if let Some(node) = node.ancestors().find(|node| node.is_identifier_or_string()) {
        return Some(node);
    }

    if next.start_position() != point {
        return Some(node);
    }

    let node = next
        .ancestors()
        .find(|node| node.is_identifier_or_string())
        .or(Some(next));
    node
}

fn node_contains_point(node: &tree_sitter::Node, point: tree_sitter::Point) -> bool {
    node.start_position().is_before_or_equal(point) && node.end_position().is_after_or_equal(point)
}

fn find_symbol_definition(
    symbol: &str,
    uri: &tower_lsp::lsp_types::Url,
    document: &Document,
    state: &WorldState,
) -> Option<(indexer::FileId, indexer::IndexEntry)> {
    // Prefer live buffers over the eventually consistent global index so `gd`
    // works against newly opened or unsaved files.
    if let Some(info) = indexer::find_in_document(symbol, uri, document) {
        return Some(info);
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
        if let Some(info) = indexer::find_in_document(symbol, open_uri, open_document) {
            return Some(info);
        }
    }

    indexer::find_in_file(symbol, uri).or_else(|| indexer::find(symbol))
}

pub(crate) fn find_target_definition(
    symbol: &str,
    uri: &tower_lsp::lsp_types::Url,
    document: &Document,
    state: &WorldState,
) -> Option<(indexer::FileId, indexer::IndexEntry)> {
    if let Some(info) = indexer::find_in_document(symbol, uri, document) {
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
        let Some(info) = indexer::find_in_document(symbol, open_uri, open_document) else {
            continue;
        };
        if matches!(info.1.data, indexer::IndexEntryData::Target { .. }) {
            return Some(info);
        }
    }

    indexer::find_in_file(symbol, uri)
        .or_else(|| indexer::find(symbol))
        .filter(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
}

#[cfg(test)]
mod tests {
    use assert_matches::assert_matches;
    use tower_lsp::lsp_types;

    use super::*;
    use crate::fixtures::point_and_offset_from_cursor;
    use crate::lsp::document::Document;
    use crate::lsp::state::WorldState;
    use crate::lsp::util::test_path;

    fn state_with_documents(documents: Vec<(lsp_types::Url, Document)>) -> WorldState {
        let mut state = WorldState::default();
        for (uri, document) in documents {
            state.documents.insert(uri, document);
        }
        state
    }

    fn params_from_cursor(text: &str, uri: lsp_types::Url) -> (String, GotoDefinitionParams) {
        let (text, point, _) = point_and_offset_from_cursor(text, b'@');
        let doc = Document::new(&text, None);
        let position = doc.lsp_position_from_tree_sitter_point(point).unwrap();
        let params = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri },
                position,
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };
        (text, params)
    }

    #[test]
    fn test_goto_definition() {
        let code = r#"
foo <- 42
print(foo)
"#;
        let doc = Document::new(code, None);
        let uri = test_path("test.R");
        let state = state_with_documents(vec![(uri.clone(), doc.clone())]);

        let params = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri },
                position: lsp_types::Position::new(2, 7),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        assert_matches!(
            goto_definition(&doc, params, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(1, 0),
                        end: lsp_types::Position::new(1, 3),
                    }
                );
            }
        );
    }

    #[test]
    fn test_goto_definition_comment_section() {
        let code = r#"
# foo ----
foo <- 1
print(foo)
"#;
        let doc = Document::new(code, None);
        let uri = test_path("test.R");
        let state = state_with_documents(vec![(uri.clone(), doc.clone())]);

        let params = lsp_types::GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri },
                position: lsp_types::Position::new(3, 7),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        assert_matches!(
            goto_definition(&doc, params, &state).unwrap(),
            Some(lsp_types::GotoDefinitionResponse::Link(ref links)) => {
                // The section should is not the target, the variable has priority
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(2, 0),
                        end: lsp_types::Position::new(2, 3),
                    }
                );
            }
        );
    }

    #[test]
    fn test_goto_definition_prefers_local_symbol() {
        // Both files define the same symbol
        let code1 = r#"
foo <- 1
foo
"#;
        let code2 = r#"
foo <- 2
foo
"#;

        let doc1 = Document::new(code1, None);
        let doc2 = Document::new(code2, None);

        let uri1 = test_path("file1.R");
        let uri2 = test_path("file2.R");
        let state = state_with_documents(vec![
            (uri1.clone(), doc1.clone()),
            (uri2.clone(), doc2.clone()),
        ]);

        // Go to definition for foo in file1
        let params1 = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: uri1.clone() },
                position: lsp_types::Position::new(2, 0),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };
        assert_matches!(
            goto_definition(&doc1, params1, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                // Should jump to foo in file1
                assert_eq!(links[0].target_uri, uri1);
            }
        );

        // Go to definition for foo in file2
        let params2 = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: uri2.clone() },
                position: lsp_types::Position::new(2, 0),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };
        assert_matches!(
            goto_definition(&doc2, params2, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                // Should jump to foo in file2
                assert_eq!(links[0].target_uri, uri2);
            }
        );
    }

    #[test]
    fn test_goto_definition_falls_back_to_other_file() {
        // file1 defines foo, file2 does not
        let code1 = r#"
foo <- 1
"#;
        let code2 = r#"
foo
"#;

        let doc1 = Document::new(code1, None);
        let doc2 = Document::new(code2, None);

        // Use test_path for cross-platform compatibility
        let uri1 = test_path("file1.R");
        let uri2 = test_path("file2.R");
        let state = state_with_documents(vec![
            (uri1.clone(), doc1.clone()),
            (uri2.clone(), doc2.clone()),
        ]);

        // Go to definition for foo in file2 (should jump to file1)
        let params2 = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: uri2.clone() },
                position: lsp_types::Position::new(1, 0),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };
        let result2 = goto_definition(&doc2, params2, &state).unwrap();
        assert_matches!(
            result2,
            Some(GotoDefinitionResponse::Link(ref links)) => {
                // Should jump to foo in file1
                assert_eq!(links[0].target_uri, uri1);
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(1, 0),
                        end: lsp_types::Position::new(1, 3),
                    }
                );
            }
        );
    }

    #[test]
    fn test_goto_definition_target_string_reference() {
        let uri = test_path("_targets.R");
        let (code, params) = params_from_cursor(
            r#"
list(
  tar_target(clean_data, raw_data + 1),
  tar_target(report, tar_read("clean_@data"))
)
"#,
            uri.clone(),
        );
        let doc = Document::new(&code, None);
        let state = state_with_documents(vec![(uri.clone(), doc.clone())]);

        assert_matches!(
            goto_definition(&doc, params, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                assert_eq!(links[0].target_uri, uri);
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(2, 13),
                        end: lsp_types::Position::new(2, 23),
                    }
                );
            }
        );
    }

    #[test]
    fn test_goto_definition_target_bare_reference_beats_local_assignment() {
        let targets_uri = test_path("_targets.R");
        let analysis_uri = test_path("analysis.R");
        let (code, params) = params_from_cursor(
            r#"
brief_intervention_summary <- tar_read(@brief_intervention_summary)
brief_intervention_summary
"#,
            analysis_uri.clone(),
        );
        let analysis_doc = Document::new(&code, None);
        let targets_doc = Document::new(
            r#"
list(
  tar_target(brief_intervention_summary, raw_data + 1)
)
"#,
            None,
        );
        let state = state_with_documents(vec![
            (targets_uri.clone(), targets_doc),
            (analysis_uri, analysis_doc.clone()),
        ]);

        assert_matches!(
            goto_definition(&analysis_doc, params, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                assert_eq!(links[0].target_uri, targets_uri);
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(2, 13),
                        end: lsp_types::Position::new(2, 39),
                    }
                );
            }
        );
    }

    #[test]
    fn test_goto_definition_tar_target_function_line_leading_whitespace_prefers_call_head() {
        let targets_uri = test_path("_targets.R");
        let helper_uri = test_path("helpers.R");
        let targets_code = r#"
list(
  tar_target(
    baseline_survey_fig,
    make_baseline_survey_fig(baseline_survey_results)
  )
)
"#;
        let targets_doc = Document::new(targets_code, None);
        let helper_doc = Document::new(
            r#"
make_baseline_survey_fig <- function(results) {
  results
}
"#,
            None,
        );
        let state = state_with_documents(vec![
            (targets_uri.clone(), targets_doc.clone()),
            (helper_uri.clone(), helper_doc),
        ]);

        // Match a normal-mode `gd` request from the leading indentation on the
        // function-call line. This should resolve the call head on that line,
        // not the target name on the previous argument line.
        let params = GotoDefinitionParams {
            text_document_position_params: lsp_types::TextDocumentPositionParams {
                text_document: lsp_types::TextDocumentIdentifier { uri: targets_uri },
                position: lsp_types::Position::new(4, 0),
            },
            work_done_progress_params: Default::default(),
            partial_result_params: Default::default(),
        };

        assert_matches!(
            goto_definition(&targets_doc, params, &state).unwrap(),
            Some(GotoDefinitionResponse::Link(ref links)) => {
                assert_eq!(links[0].target_uri, helper_uri);
                assert_eq!(
                    links[0].target_range,
                    lsp_types::Range {
                        start: lsp_types::Position::new(1, 0),
                        end: lsp_types::Position::new(1, 24),
                    }
                );
            }
        );
    }
}
