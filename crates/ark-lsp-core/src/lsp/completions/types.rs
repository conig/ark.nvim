//
// types.rs
//
// Copyright (C) 2023 Posit Software, PBC. All rights reserved.
//
//

use std::path::PathBuf;

use serde::Deserialize;
use serde::Serialize;

#[derive(Serialize, Deserialize, Debug)]
pub(super) enum CompletionData {
    DataVariable {
        name: String,
        owner: String,
    },
    Directory {
        path: PathBuf,
    },
    File {
        path: PathBuf,
    },
    Function {
        name: String,
        package: Option<String>,
    },
    Object {
        name: String,
    },
    Keyword {
        name: String,
    },
    Package {
        name: String,
    },
    Parameter {
        name: String,
        function: String,
    },
    RoxygenTag {
        tag: String,
    },
    ScopeParameter {
        name: String,
    },
    ScopeVariable {
        name: String,
    },
    /// Budgeted candidates need a fresh request as the client narrows the prefix.
    /// Like Unknown, this carries no completion-resolution work or private paths.
    Incomplete,
    Unknown,
}

#[derive(Copy, Clone, Debug, PartialEq)]
pub(crate) enum PromiseStrategy {
    Simple,
    Force,
}

/// Keep truncation metadata in the standard LSP CompletionList, rather than
/// asking clients to know individual source budgets or forcing all lists to requery.
pub(crate) fn completion_items_require_requery(
    items: &[tower_lsp::lsp_types::CompletionItem],
) -> bool {
    let Ok(marker) = serde_json::to_value(CompletionData::Incomplete) else {
        return false;
    };
    items.iter().any(|item| item.data.as_ref() == Some(&marker))
}
