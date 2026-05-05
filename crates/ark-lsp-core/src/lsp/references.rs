//
// references.rs
//
// Copyright (C) 2022-2026 Posit Software, PBC. All rights reserved.
//
//

use std::path::Path;

use anyhow::anyhow;
use stdext::result::ResultExt;
use stdext::unwrap::IntoResult;
use stdext::*;
use tower_lsp::lsp_types::Location;
use tower_lsp::lsp_types::Position;
use tower_lsp::lsp_types::Range;
use tower_lsp::lsp_types::ReferenceParams;
use tower_lsp::lsp_types::Url;
use tree_sitter::Node;
use tree_sitter::Point;
use walkdir::WalkDir;

use crate::lsp;
use crate::lsp::document::Document;
use crate::lsp::indexer;
use crate::lsp::indexer::filter_entry;
use crate::lsp::state::with_document;
use crate::lsp::state::WorldState;
use crate::lsp::traits::cursor::TreeCursorExt;
use crate::lsp::traits::node::NodeExt;
use crate::lsp::traits::url::UrlExt;
use crate::treesitter::ExtractOperatorType;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;

#[derive(Debug, PartialEq)]
enum ReferenceKind {
    Symbol, // a regular R symbol
    Dollar, // a dollar name, following '$'
    At,     // a slot name, following '@'
}

// Assuming `x` is an `identifier`, is it the RHS of a `$` or `@`?
fn node_reference_kind(x: &Node) -> ReferenceKind {
    let Some(parent) = x.parent() else {
        // No `parent`, must be a regular symbol
        return ReferenceKind::Symbol;
    };

    let parent_type = parent.node_type();

    if !matches!(parent_type, NodeType::ExtractOperator(_)) {
        // Parent not `$` or `@`
        return ReferenceKind::Symbol;
    }

    // Need to check that we actually came from the RHS
    let Some(rhs) = parent.child_by_field_name("rhs") else {
        return ReferenceKind::Symbol;
    };
    if &rhs != x {
        return ReferenceKind::Symbol;
    };

    match parent_type {
        NodeType::ExtractOperator(ExtractOperatorType::Dollar) => ReferenceKind::Dollar,
        NodeType::ExtractOperator(ExtractOperatorType::At) => ReferenceKind::At,
        _ => std::unreachable!(),
    }
}

struct Context {
    kind: ReferenceKind,
    symbol: String,
    target: bool,
}

fn add_reference(
    node: &Node,
    document: &Document,
    path: &Path,
    locations: &mut Vec<Location>,
) -> anyhow::Result<()> {
    let start = document.lsp_position_from_tree_sitter_point(node.start_position())?;
    let end = document.lsp_position_from_tree_sitter_point(node.end_position())?;

    let location = Location::new(
        Url::from_file_path(path).expect("valid path"),
        Range::new(start, end),
    );
    locations.push(location);
    Ok(())
}

fn found_match(node: &Node, contents: &str, context: &Context) -> bool {
    let symbol = if node.is_identifier() {
        node.node_to_string(contents).unwrap()
    } else if context.target && node.is_string() {
        node.get_identifier_or_string_text(contents)
            .unwrap()
            .to_string()
    } else {
        return false;
    };
    if symbol != context.symbol {
        return false;
    }

    if node.is_string() {
        return context.kind == ReferenceKind::Symbol;
    }

    context.kind == node_reference_kind(node)
}

fn build_context(uri: &Url, position: Position, state: &WorldState) -> anyhow::Result<Context> {
    // Unwrap the URL.
    let path = uri.file_path()?;

    // Figure out the identifier we're looking for.
    let context = with_document(path.as_path(), state, |document| {
        let ast = &document.ast;
        let contents = document.contents.as_str();
        let point = document.tree_sitter_point_from_lsp_position(position)?;

        let mut node = ast
            .root_node()
            .descendant_for_point_range(point, point)
            .into_result()?;

        // Check and see if we got an identifier. If we didn't, we might need to use
        // some heuristics to look around. Unfortunately, it seems like if you double-click
        // to select an identifier, and then use Right Click -> Find All References, the
        // position received by the LSP maps to the _end_ of the selected range, which
        // is technically not part of the associated identifier's range. In addition, we
        // can't just subtract 1 from the position column since that would then fail to
        // resolve the correct identifier when the cursor is located at the start of the
        // identifier.
        if !node.is_identifier_or_string() && point.column > 0 {
            let point = Point::new(point.row, point.column - 1);
            node = ast
                .root_node()
                .descendant_for_point_range(point, point)
                .into_result()?;
        }

        // double check that we found an identifier or string
        if !node.is_identifier_or_string() {
            return Err(anyhow!(
                "couldn't find an identifier or string associated with point {point:?}",
            ));
        }

        let kind = if node.is_identifier() {
            node_reference_kind(&node)
        } else {
            ReferenceKind::Symbol
        };

        // return identifier text contents
        let symbol = node.get_identifier_or_string_text(contents)?.to_string();
        let target = is_static_target(&symbol, uri, document, state);

        Ok(Context {
            kind,
            symbol,
            target,
        })
    });

    context
}

fn is_static_target(symbol: &str, uri: &Url, document: &Document, state: &WorldState) -> bool {
    if indexer::find_in_document(symbol, uri, document)
        .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
    {
        return true;
    }

    for (open_uri, open_document) in &state.documents {
        if indexer::find_in_document(symbol, open_uri, open_document)
            .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
        {
            return true;
        }
    }

    indexer::find(symbol)
        .is_some_and(|(_, entry)| matches!(entry.data, indexer::IndexEntryData::Target { .. }))
}

fn find_references_in_folder(
    context: &Context,
    path: &Path,
    locations: &mut Vec<Location>,
    state: &WorldState,
) {
    let walker = WalkDir::new(path);
    for entry in walker.into_iter().filter_entry(filter_entry) {
        let entry = unwrap!(entry, Err(_) => { continue; });
        let path = entry.path();
        if !is_reference_search_file(path) {
            continue;
        }

        lsp::log_info!("found R file {}", path.display());
        let result = with_document(path, state, |document| {
            find_references_in_document(context, path, document, locations)
        });

        match result {
            Ok(result) => result,
            Err(_error) => {
                lsp::log_warn!("error retrieving document for path {}", path.display());
                continue;
            },
        }
    }
}

fn is_reference_search_file(path: &Path) -> bool {
    let Some(extension) = path.extension().and_then(|extension| extension.to_str()) else {
        return false;
    };

    matches!(
        extension.to_ascii_lowercase().as_str(),
        "r" | "rmd" | "qmd" | "quarto"
    )
}

fn find_references_in_document(
    context: &Context,
    path: &Path,
    document: &Document,
    locations: &mut Vec<Location>,
) -> anyhow::Result<()> {
    let ast = &document.ast;
    let contents = document.contents.as_str();

    let mut cursor = ast.walk();
    cursor.recurse(|node| {
        if found_match(&node, contents, context) {
            add_reference(&node, document, path, locations).log_err();
        }

        true
    });
    Ok(())
}

pub(crate) fn find_references(
    params: ReferenceParams,
    state: &WorldState,
) -> anyhow::Result<Vec<Location>> {
    // Create our locations vector.
    let mut locations: Vec<Location> = Vec::new();

    // Extract relevant parameters.
    let uri = params.text_document_position.text_document.uri;
    let position = params.text_document_position.position;

    // Figure out what we're looking for.
    let context = unwrap!(build_context(&uri, position, state), Err(err) => {
        return Err(anyhow!("Failed to find build context at position {position:?}: {err:?}"));
    });

    // Now, start searching through workspace folders for references to that identifier.
    for folder in state.workspace.folders.iter() {
        if let Ok(path) = folder.to_file_path() {
            lsp::log_info!("searching references in folder {}", path.display());
            find_references_in_folder(&context, &path, &mut locations, state);
        }
    }

    Ok(locations)
}

#[cfg(test)]
mod tests {
    use tower_lsp::lsp_types::ReferenceContext;
    use tower_lsp::lsp_types::TextDocumentIdentifier;
    use tower_lsp::lsp_types::TextDocumentPositionParams;
    use tower_lsp::lsp_types::WorkDoneProgressParams;

    use super::*;
    use crate::lsp::indexer::indexer_test_lock;
    use crate::lsp::indexer::ResetIndexerGuard;
    use crate::lsp::state::Workspace;

    #[test]
    fn test_target_references_include_string_and_bare_usages() {
        let _lock = indexer_test_lock();
        let _guard = ResetIndexerGuard;
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let targets_path = tempdir.path().join("_targets.R");
        let analysis_path = tempdir.path().join("analysis.R");
        let report_path = tempdir.path().join("report.Rmd");

        std::fs::write(&targets_path, "list(tar_target(clean_data, 1))\n")
            .expect("expected targets file");
        std::fs::write(
            &analysis_path,
            "x <- targets::tar_read(\"clean_data\")\ny <- clean_data\n",
        )
        .expect("expected analysis file");
        std::fs::write(
            &report_path,
            "Report `r clean_data`.\n\n```{r}\ntargets::tar_read(\"clean_data\")\n```\n",
        )
        .expect("expected report file");

        let targets_uri = Url::from_file_path(&targets_path).expect("expected targets uri");
        let analysis_uri = Url::from_file_path(&analysis_path).expect("expected analysis uri");
        indexer::create(&targets_uri).expect("expected targets indexing");

        let state = WorldState {
            workspace: Workspace {
                folders: vec![
                    Url::from_directory_path(tempdir.path()).expect("expected workspace uri")
                ],
            },
            ..Default::default()
        };

        let locations = find_references(
            ReferenceParams {
                text_document_position: TextDocumentPositionParams {
                    text_document: TextDocumentIdentifier { uri: analysis_uri },
                    position: Position::new(1, 5),
                },
                work_done_progress_params: WorkDoneProgressParams::default(),
                partial_result_params: Default::default(),
                context: ReferenceContext {
                    include_declaration: true,
                },
            },
            &state,
        )
        .expect("expected target references");

        assert!(
            locations.iter().any(|location| location.uri == targets_uri),
            "expected target declaration reference: {locations:?}"
        );
        assert!(
            locations
                .iter()
                .filter(|location| location.uri.as_str().ends_with("analysis.R"))
                .count() >=
                2,
            "expected string and bare target references in analysis file: {locations:?}"
        );
        assert!(
            locations
                .iter()
                .filter(|location| location.uri.as_str().ends_with("report.Rmd"))
                .count() >=
                2,
            "expected inline and fenced target references in report file: {locations:?}"
        );
    }
}
