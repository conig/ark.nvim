//
// indexer.rs
//
// Copyright (C) 2022 Posit Software, PBC. All rights reserved.
//
//

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;
use std::result::Result::Ok;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::Mutex;

use regex::Regex;
use stdext::unwrap;
use stdext::unwrap::IntoResult;
use tower_lsp::lsp_types::Range;
use tree_sitter::Node;
use tree_sitter::Query;
use url::Url;
use walkdir::DirEntry;
use walkdir::WalkDir;

use crate::lsp;
use crate::lsp::document::Document;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::BinaryOperatorType;
use crate::treesitter::NodeType;
use crate::treesitter::NodeTypeExt;
use crate::treesitter::TsQuery;
use crate::url::ExtUrl;

/// FileId represents a unique identifier for a file in the workspace index
#[derive(Clone, Eq, PartialEq, Hash, Debug)]
pub struct FileId {
    /// The URL representing the file
    uri: Url,
}

impl FileId {
    pub fn from_uri(uri: Url) -> Self {
        Self { uri }
    }

    pub fn as_str(&self) -> &str {
        self.uri.as_str()
    }

    pub fn as_uri(&self) -> &Url {
        &self.uri
    }
}

#[derive(Clone, Debug)]
pub enum IndexEntryData {
    Variable {
        name: String,
    },
    Target {
        name: String,
    },
    Function {
        name: String,
        arguments: Vec<String>,
    },
    // Like Function but not used for completions yet
    Method {
        name: String,
    },
    Section {
        level: usize,
        title: String,
    },
    PackageImport {
        package: String,
    },
}

#[derive(Clone, Debug)]
pub struct IndexEntry {
    pub key: String,
    pub range: Range,
    pub data: IndexEntryData,
}

type DocumentSymbol = String;
type DocumentSymbolIndex = HashMap<DocumentSymbol, IndexEntry>;
type WorkspaceIndex = Arc<Mutex<HashMap<FileId, DocumentSymbolIndex>>>;

static WORKSPACE_INDEX: LazyLock<WorkspaceIndex> = LazyLock::new(Default::default);
static SOURCED_TARGET_PIPELINE_URIS: LazyLock<Mutex<HashSet<Url>>> =
    LazyLock::new(Default::default);
#[cfg(test)]
pub(crate) static INDEXER_TEST_MUTEX: LazyLock<Mutex<()>> = LazyLock::new(Default::default);
pub static RE_COMMENT_SECTION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(#+)\s*(.*?)\s*[#=-]{4,}\s*$").unwrap());

#[tracing::instrument(level = "info", skip_all)]
pub fn start(folders: Vec<String>) {
    let now = std::time::Instant::now();
    lsp::log_info!("Initial indexing started");

    for folder in folders {
        let walker = WalkDir::new(folder);
        for entry in walker.into_iter().filter_entry(filter_entry) {
            let Ok(entry) = entry else {
                continue;
            };
            if !entry.file_type().is_file() {
                continue;
            }
            let Ok(uri) = Url::from_file_path(entry.path()) else {
                lsp::log_warn!("Can't convert file path to URI {:?}", entry.path());
                continue;
            };
            if let Err(err) = create(&uri) {
                lsp::log_error!("Can't index file {:?}: {err:?}", entry.path());
            }
        }
    }

    lsp::log_info!(
        "Initial indexing finished after {}ms",
        now.elapsed().as_millis()
    );
}

/// Search the workspace files and return the first symbol match
pub fn find(symbol: &str) -> Option<(FileId, IndexEntry)> {
    let index = WORKSPACE_INDEX.lock().unwrap();

    for (file_id, index) in index.iter() {
        if let Some(entry) = index.get(symbol) {
            return Some((file_id.clone(), entry.clone()));
        }
    }

    None
}

/// Search a specific workspace file for a symbol
pub fn find_in_file(symbol: &str, uri: &Url) -> Option<(FileId, IndexEntry)> {
    let index = WORKSPACE_INDEX.lock().unwrap();

    let file_id = FileId::from_uri(uri.clone());

    if let Some(symbol_index) = index.get(&file_id) {
        if let Some(entry) = symbol_index.get(symbol) {
            return Some((file_id, entry.clone()));
        }
    }

    None
}

pub fn map(mut callback: impl FnMut(&Url, &String, &IndexEntry)) {
    let index = WORKSPACE_INDEX.lock().unwrap();

    for (file_id, symbol_index) in index.iter() {
        let uri = file_id.as_uri();
        for (symbol, entry) in symbol_index.iter() {
            callback(uri, symbol, entry);
        }
    }
}

#[tracing::instrument(level = "trace", skip_all, fields(uri = %uri))]
pub fn update(document: &Document, uri: &Url) -> anyhow::Result<()> {
    // Defensive, callers are expected to filter virtual doc URIs before queuing
    if !ExtUrl::is_indexable(uri) {
        return Ok(());
    }
    delete(uri)?;
    index_document(document, uri);
    index_targets_sourced_pipeline_files(document, uri);
    Ok(())
}

fn insert(uri: &Url, entry: IndexEntry) -> anyhow::Result<()> {
    let mut index = WORKSPACE_INDEX.lock().unwrap();
    let file_id = FileId::from_uri(uri.clone());

    let file_index = index.entry(file_id).or_default();
    index_insert(file_index, entry);

    Ok(())
}

fn index_insert(index: &mut HashMap<String, IndexEntry>, entry: IndexEntry) {
    // We generally retain only the first occurrence in the index. In the
    // future we'll track every occurrences and their scopes but for now we
    // only track the first definition of an object (in a way, its
    // declaration).
    if let Some(existing_entry) = index.get(&entry.key) {
        // Give priority to non-section entries.
        if matches!(existing_entry.data, IndexEntryData::Section { .. }) {
            index.insert(entry.key.clone(), entry);
        }
        // Else, ignore.
    } else {
        index.insert(entry.key.clone(), entry);
    }
}

#[tracing::instrument(level = "trace")]
pub(crate) fn delete(uri: &Url) -> anyhow::Result<()> {
    let file_id = FileId::from_uri(uri.clone());
    let mut index = WORKSPACE_INDEX.lock().unwrap();

    // Only clears if the key exists
    index.entry(file_id).and_modify(|index| {
        index.clear();
    });
    SOURCED_TARGET_PIPELINE_URIS.lock().unwrap().remove(uri);

    Ok(())
}

#[tracing::instrument(level = "trace")]
pub(crate) fn rename(old_uri: &Url, new_uri: &Url) -> anyhow::Result<()> {
    let mut index = WORKSPACE_INDEX.lock().unwrap();

    let old_file_id = FileId::from_uri(old_uri.clone());
    let new_file_id = FileId::from_uri(new_uri.clone());

    if let Some(entries) = index.remove(&old_file_id) {
        index.insert(new_file_id, entries);
    }

    Ok(())
}

#[cfg(test)]
pub(crate) fn indexer_clear() {
    let mut index = WORKSPACE_INDEX.lock().unwrap();
    index.clear();
    SOURCED_TARGET_PIPELINE_URIS.lock().unwrap().clear();
}

#[cfg(test)]
pub(crate) fn indexer_test_lock() -> std::sync::MutexGuard<'static, ()> {
    INDEXER_TEST_MUTEX.lock().unwrap()
}

/// RAII guard that clears `WORKSPACE_INDEX` when dropped.
/// Useful for ensuring a clean index state in tests.
#[cfg(test)]
pub(crate) struct ResetIndexerGuard;

#[cfg(test)]
impl Drop for ResetIndexerGuard {
    fn drop(&mut self) {
        indexer_clear();
    }
}

// TODO: Should we consult the project .gitignore for ignored files?
// TODO: What about front-end ignores?
// TODO: What about other kinds of ignores (e.g. revdepcheck)?
pub fn filter_entry(entry: &DirEntry) -> bool {
    let name = entry.file_name();

    // skip common ignores
    for ignore in [".git", ".Rproj.user", "node_modules", "revdep"] {
        if name == ignore {
            return false;
        }
    }

    // skip project 'renv' folder
    if name == "renv" {
        let companion = entry.path().join("activate.R");
        if companion.exists() {
            return false;
        }
    }

    true
}

// Only called for actual files during workspace walking. Documents managed by
// the LSP go through `update()` instead.
pub(crate) fn create(uri: &Url) -> anyhow::Result<()> {
    if uri.scheme() != "file" {
        return Ok(());
    }
    let Ok(path) = uri.to_file_path() else {
        return Ok(());
    };

    let ext = path.extension().unwrap_or_default();
    if ext != "r" && ext != "R" {
        return Ok(());
    }

    // TODO: Handle document encodings here.
    // TODO: Check if there's an up-to-date buffer to be used.
    let contents = std::fs::read(path)?;
    let contents = String::from_utf8(contents)?;
    let document = Document::new(contents.as_str(), None);

    index_document(&document, uri);
    index_targets_sourced_pipeline_files(&document, uri);

    Ok(())
}

fn index_document(doc: &Document, uri: &Url) {
    for entry in index_document_entries_for_uri(doc, uri) {
        if let Err(err) = insert(uri, entry) {
            lsp::log_error!("Can't insert index entry: {err:?}");
        }
    }
}

#[cfg(test)]
fn index_document_entries(doc: &Document) -> Vec<IndexEntry> {
    index_document_entries_impl(doc, false)
}

fn index_document_entries_for_uri(doc: &Document, uri: &Url) -> Vec<IndexEntry> {
    index_document_entries_impl(doc, is_targets_pipeline_uri(uri))
}

fn index_document_entries_impl(doc: &Document, index_targets_options: bool) -> Vec<IndexEntry> {
    let ast = &doc.ast;
    let root = ast.root_node();
    let mut cursor = root.walk();
    let mut entries = Vec::new();

    for node in root.children(&mut cursor) {
        if let Err(err) = index_node(doc, &node, &mut entries) {
            lsp::log_error!("Can't index document: {err:?}");
        }
        if index_targets_options {
            if let Err(err) = index_targets_option_set(doc, &node, &mut entries) {
                lsp::log_error!("Can't index targets options: {err:?}");
            }
            if let Err(err) = index_targets_target_calls(doc, &node, &mut entries) {
                lsp::log_error!("Can't index targets: {err:?}");
            }
        }
    }

    entries
}

fn is_targets_pipeline_uri(uri: &Url) -> bool {
    if is_targets_script_uri(uri) || is_conventional_targets_pipeline_uri(uri) {
        return true;
    }

    SOURCED_TARGET_PIPELINE_URIS.lock().unwrap().contains(uri)
}

fn is_targets_script_uri(uri: &Url) -> bool {
    uri.path_segments()
        .and_then(|mut segments| segments.next_back())
        .is_some_and(|segment| segment == "_targets.R")
}

fn is_conventional_targets_pipeline_uri(uri: &Url) -> bool {
    uri.path_segments()
        .is_some_and(|mut segments| segments.any(|segment| segment == "_target_pipelines"))
}

pub fn find_in_document(
    symbol: &str,
    uri: &Url,
    document: &Document,
) -> Option<(FileId, IndexEntry)> {
    let mut symbol_index = HashMap::new();

    for entry in index_document_entries_for_uri(document, uri) {
        index_insert(&mut symbol_index, entry);
    }

    symbol_index
        .get(symbol)
        .cloned()
        .map(|entry| (FileId::from_uri(uri.clone()), entry))
}

fn index_node(doc: &Document, node: &Node, entries: &mut Vec<IndexEntry>) -> anyhow::Result<()> {
    index_assignment(doc, node, entries)?;
    index_comment(doc, node, entries)?;
    Ok(())
}

fn index_targets_option_set(
    doc: &Document,
    node: &Node,
    entries: &mut Vec<IndexEntry>,
) -> anyhow::Result<()> {
    if !node.is_call() {
        return Ok(());
    }

    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(());
    };
    let callee = callee.node_as_str(&doc.contents)?;
    if !matches!(
        callee,
        "tar_option_set" | "targets::tar_option_set" | "targets:::tar_option_set"
    ) {
        return Ok(());
    }

    for (name, value) in node.arguments() {
        let Some(name) = name else {
            continue;
        };
        let Some(value) = value else {
            continue;
        };
        if name.node_as_str(&doc.contents)? != "packages" {
            continue;
        }

        let start = doc.lsp_position_from_tree_sitter_point(value.start_position())?;
        let end = doc.lsp_position_from_tree_sitter_point(value.end_position())?;
        let range = Range { start, end };

        for package in targets_option_package_values(doc, value)? {
            entries.push(IndexEntry {
                key: format!("targets-package:{package}"),
                range,
                data: IndexEntryData::PackageImport { package },
            });
        }
    }

    Ok(())
}

fn index_targets_target_calls(
    doc: &Document,
    node: &Node,
    entries: &mut Vec<IndexEntry>,
) -> anyhow::Result<()> {
    if node.is_call() {
        index_targets_target_call(doc, node, entries)?;
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        index_targets_target_calls(doc, &child, entries)?;
    }

    Ok(())
}

fn index_targets_target_call(
    doc: &Document,
    node: &Node,
    entries: &mut Vec<IndexEntry>,
) -> anyhow::Result<()> {
    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(());
    };
    let callee = callee.node_as_str(&doc.contents)?;
    if !matches!(
        callee,
        "tar_target" | "targets::tar_target" | "targets:::tar_target"
    ) {
        return Ok(());
    }

    let target_node =
        node.arguments().into_iter().find_map(
            |(name, value)| {
                if name.is_none() {
                    value
                } else {
                    None
                }
            },
        );
    let Some(target_node) = target_node else {
        return Ok(());
    };

    let name = target_node
        .get_identifier_or_string_text(&doc.contents)?
        .to_string();
    let start = doc.lsp_position_from_tree_sitter_point(target_node.start_position())?;
    let end = doc.lsp_position_from_tree_sitter_point(target_node.end_position())?;
    let range = Range { start, end };

    entries.push(IndexEntry {
        key: name.clone(),
        range,
        data: IndexEntryData::Target { name },
    });

    Ok(())
}

fn index_targets_sourced_pipeline_files(doc: &Document, uri: &Url) {
    if !is_targets_script_uri(uri) {
        return;
    }

    for sourced_uri in targets_sourced_pipeline_uris(doc, uri) {
        if sourced_uri == *uri {
            continue;
        }

        SOURCED_TARGET_PIPELINE_URIS
            .lock()
            .unwrap()
            .insert(sourced_uri.clone());

        if let Err(err) = create(&sourced_uri) {
            lsp::log_error!("Can't index sourced targets pipeline {sourced_uri}: {err:?}");
        }
    }
}

fn targets_sourced_pipeline_uris(doc: &Document, uri: &Url) -> Vec<Url> {
    let Ok(root_path) = uri.to_file_path() else {
        return Vec::new();
    };
    let Some(root_dir) = root_path.parent() else {
        return Vec::new();
    };

    let mut paths = Vec::new();
    collect_targets_source_paths(doc, &doc.ast.root_node(), root_dir, &mut paths);

    let mut uris = Vec::new();
    for path in paths {
        if path.is_dir() {
            for entry in WalkDir::new(path).into_iter().filter_entry(filter_entry) {
                let Ok(entry) = entry else {
                    continue;
                };
                if !entry.file_type().is_file() {
                    continue;
                }
                if !is_r_file(entry.path()) {
                    continue;
                }
                if let Ok(uri) = Url::from_file_path(entry.path()) {
                    uris.push(uri);
                }
            }
        } else if path.is_file() && is_r_file(path.as_path()) {
            if let Ok(uri) = Url::from_file_path(path.as_path()) {
                uris.push(uri);
            }
        }
    }

    uris.sort_by(|left, right| left.as_str().cmp(right.as_str()));
    uris.dedup();
    uris
}

fn collect_targets_source_paths(
    doc: &Document,
    node: &Node,
    root_dir: &Path,
    paths: &mut Vec<std::path::PathBuf>,
) {
    if node.is_call() {
        if let Err(err) = collect_targets_source_call_paths(doc, node, root_dir, paths) {
            lsp::log_error!("Can't collect target source paths: {err:?}");
        }
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_targets_source_paths(doc, &child, root_dir, paths);
    }
}

fn collect_targets_source_call_paths(
    doc: &Document,
    node: &Node,
    root_dir: &Path,
    paths: &mut Vec<std::path::PathBuf>,
) -> anyhow::Result<()> {
    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(());
    };
    let callee = callee.node_as_str(&doc.contents)?;
    if !matches!(
        callee,
        "source" |
            "base::source" |
            "base:::source" |
            "tar_source" |
            "targets::tar_source" |
            "targets:::tar_source"
    ) {
        return Ok(());
    }

    for (index, (name, value)) in node.arguments().into_iter().enumerate() {
        if !is_targets_source_path_argument(doc, index, name.as_ref())? {
            continue;
        }
        let Some(value) = value else {
            continue;
        };
        for path in targets_source_path_values(doc, value)? {
            let path = Path::new(path.as_str());
            let path = if path.is_absolute() {
                path.to_path_buf()
            } else {
                root_dir.join(path)
            };
            paths.push(path);
        }
    }

    Ok(())
}

fn is_targets_source_path_argument(
    doc: &Document,
    index: usize,
    name: Option<&Node>,
) -> anyhow::Result<bool> {
    let Some(name) = name else {
        return Ok(index == 0);
    };

    Ok(matches!(
        name.node_as_str(&doc.contents)?,
        "file" | "files" | "path" | "paths"
    ))
}

fn targets_source_path_values(doc: &Document, node: Node) -> anyhow::Result<Vec<String>> {
    let mut paths = Vec::new();
    collect_targets_source_path_values(doc, node, &mut paths)?;
    paths.sort();
    paths.dedup();
    Ok(paths)
}

fn collect_targets_source_path_values(
    doc: &Document,
    node: Node,
    paths: &mut Vec<String>,
) -> anyhow::Result<()> {
    if node.is_string() {
        paths.push(
            node.get_identifier_or_string_text(&doc.contents)?
                .to_string(),
        );
        return Ok(());
    }

    if !node.is_call() {
        return Ok(());
    }

    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(());
    };
    let callee = callee.node_as_str(&doc.contents)?;
    if !matches!(callee, "c" | "base::c" | "base:::c") {
        return Ok(());
    }

    for (_name, value) in node.arguments() {
        let Some(value) = value else {
            continue;
        };
        collect_targets_source_path_values(doc, value, paths)?;
    }

    Ok(())
}

fn is_r_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| matches!(extension, "r" | "R"))
}

fn targets_option_package_values(doc: &Document, node: Node) -> anyhow::Result<Vec<String>> {
    let mut packages = Vec::new();
    collect_targets_option_package_values(doc, node, &mut packages)?;
    packages.sort();
    packages.dedup();
    Ok(packages)
}

fn collect_targets_option_package_values(
    doc: &Document,
    node: Node,
    packages: &mut Vec<String>,
) -> anyhow::Result<()> {
    if node.is_string() {
        packages.push(
            node.get_identifier_or_string_text(&doc.contents)?
                .to_string(),
        );
        return Ok(());
    }

    if !node.is_call() {
        return Ok(());
    }

    let Some(callee) = node.child_by_field_name("function") else {
        return Ok(());
    };
    let callee = callee.node_as_str(&doc.contents)?;
    if !matches!(callee, "c" | "base::c" | "base:::c") {
        return Ok(());
    }

    for (_name, value) in node.arguments() {
        let Some(value) = value else {
            continue;
        };
        collect_targets_option_package_values(doc, value, packages)?;
    }

    Ok(())
}

fn index_assignment(
    doc: &Document,
    node: &Node,
    entries: &mut Vec<IndexEntry>,
) -> anyhow::Result<()> {
    if !matches!(
        node.node_type(),
        NodeType::BinaryOperator(BinaryOperatorType::LeftAssignment) |
            NodeType::BinaryOperator(BinaryOperatorType::EqualsAssignment)
    ) {
        return Ok(());
    }

    let lhs = match node.child_by_field_name("lhs") {
        Some(lhs) => lhs,
        None => return Ok(()),
    };

    let Some(rhs) = node.child_by_field_name("rhs") else {
        return Ok(());
    };

    if crate::treesitter::node_is_call(&rhs, "R6Class", &doc.contents) ||
        crate::treesitter::node_is_namespaced_call(&rhs, "R6", "R6Class", &doc.contents)
    {
        index_r6_class_methods(doc, &rhs, entries)?;
        // Fallthrough to index the variable to which the R6 class is assigned
    }

    let lhs_text = lhs.node_to_string(&doc.contents)?;

    // The method matching is super hacky but let's wait until the typed API to
    // do better
    if !lhs_text.starts_with("method(") && !lhs.is_identifier_or_string() {
        return Ok(());
    }

    let Some(rhs) = node.child_by_field_name("rhs") else {
        return Ok(());
    };

    if rhs.is_function_definition() {
        // If RHS is a function definition, emit a function symbol
        let mut arguments = Vec::new();
        if let Some(parameters) = rhs.child_by_field_name("parameters") {
            let mut cursor = parameters.walk();
            for child in parameters.children(&mut cursor) {
                let name = unwrap!(child.child_by_field_name("name"), None => continue);
                if name.is_identifier() {
                    let name = name.node_to_string(&doc.contents)?;
                    arguments.push(name);
                }
            }
        }

        // Note that unlike document symbols whose ranges cover the whole entity
        // they represent, the range of workspace symbols only cover the identifers
        let start = doc.lsp_position_from_tree_sitter_point(lhs.start_position())?;
        let end = doc.lsp_position_from_tree_sitter_point(lhs.end_position())?;

        entries.push(IndexEntry {
            key: lhs_text.clone(),
            range: Range { start, end },
            data: IndexEntryData::Function {
                name: lhs_text,
                arguments,
            },
        });
    } else {
        // Otherwise, emit variable
        let start = doc.lsp_position_from_tree_sitter_point(lhs.start_position())?;
        let end = doc.lsp_position_from_tree_sitter_point(lhs.end_position())?;
        entries.push(IndexEntry {
            key: lhs_text.clone(),
            range: Range { start, end },
            data: IndexEntryData::Variable { name: lhs_text },
        });
    }

    Ok(())
}

fn index_r6_class_methods(
    doc: &Document,
    node: &Node,
    entries: &mut Vec<IndexEntry>,
) -> anyhow::Result<()> {
    // Tree-sitter query to match individual methods in R6Class public/private lists
    static R6_METHODS_QUERY: LazyLock<Query> = LazyLock::new(|| {
        let query_str = r#"
            (argument
                name: (identifier) @access
                value: (call
                    function: (identifier) @_list_fn
                    arguments: (arguments
                        (argument
                            name: (identifier) @method_name
                            value: (function_definition) @method_fn
                        )
                    )
                )
                (#match? @access "public|private")
                (#eq? @_list_fn "list")
            )
        "#;
        let language = &tree_sitter_r::LANGUAGE.into();
        Query::new(language, query_str).expect("Failed to compile R6 methods query")
    });
    let mut ts_query = TsQuery::from_query(&R6_METHODS_QUERY);

    for method_node in ts_query.captures_for(*node, "method_name", doc.contents.as_bytes()) {
        let name = method_node.node_to_string(&doc.contents)?;
        let start = doc.lsp_position_from_tree_sitter_point(method_node.start_position())?;
        let end = doc.lsp_position_from_tree_sitter_point(method_node.end_position())?;

        entries.push(IndexEntry {
            key: name.clone(),
            range: Range { start, end },
            data: IndexEntryData::Method { name },
        });
    }

    Ok(())
}

fn index_comment(doc: &Document, node: &Node, entries: &mut Vec<IndexEntry>) -> anyhow::Result<()> {
    // check for comment
    if !node.is_comment() {
        return Ok(());
    }

    // see if it looks like a section
    let comment = node.node_as_str(&doc.contents)?;
    let matches = match RE_COMMENT_SECTION.captures(comment) {
        Some(m) => m,
        None => return Ok(()),
    };

    let level = matches.get(1).into_result()?;
    let title = matches.get(2).into_result()?;

    let level = level.as_str().len();
    let title = title.as_str().to_string();

    // skip things that look like knitr output
    if title.starts_with("----") {
        return Ok(());
    }

    let start = doc.lsp_position_from_tree_sitter_point(node.start_position())?;
    let end = doc.lsp_position_from_tree_sitter_point(node.end_position())?;

    entries.push(IndexEntry {
        key: title.clone(),
        range: Range::new(start, end),
        data: IndexEntryData::Section { level, title },
    });

    Ok(())
}

#[cfg(test)]
mod tests {

    use assert_matches::assert_matches;
    use insta::assert_debug_snapshot;
    use tower_lsp::lsp_types;

    use super::*;
    use crate::lsp::document::Document;

    macro_rules! test_index {
        ($code:expr) => {
            let doc = Document::new($code, None);
            let root = doc.ast.root_node();
            let mut cursor = root.walk();

            let mut entries = vec![];
            for node in root.children(&mut cursor) {
                let _ = index_node(&doc, &node, &mut entries);
            }
            assert_debug_snapshot!(entries);
        };
    }

    // Note that unlike document symbols whose ranges cover the whole entity
    // they represent, the range of workspace symbols only cover the identifers

    #[test]
    fn test_index_function() {
        test_index!(
            r#"
my_function <- function(a, b = 1) {
  a + b

  # These are not indexed as workspace symbol
  inner <- function() {
    2
  }
  inner_var <- 3
}

my_variable <- 1
"#
        );
    }

    #[test]
    fn test_index_variable() {
        test_index!(
            r#"
x <- 10
y = "hello"
"#
        );
    }

    #[test]
    fn test_index_s7_methods() {
        test_index!(
            r#"
Class <- new_class("Class")
generic <- new_generic("generic", "arg",
  function(arg) {
    S7_dispatch()
  }
)
method(generic, Class) <- function(arg) {
  NULL
}
"#
        );
    }

    #[test]
    fn test_index_comment_section() {
        test_index!(
            r#"
# Section 1 ----
x <- 10

## Subsection ======
y <- 20

x <- function() {
    # This inner section is not indexed ----
}

"#
        );
    }

    #[test]
    fn test_index_targets_option_packages() {
        let doc = Document::new(
            r#"
targets::tar_option_set(
    packages = c("data.table", "dplyr"),
    controller = crew::crew_controller_local(workers = snipe::n_workers())
)
"#,
            None,
        );
        let uri = Url::parse("file:///tmp/example/_targets.R").unwrap();

        let packages: Vec<_> = index_document_entries_for_uri(&doc, &uri)
            .into_iter()
            .filter_map(|entry| match entry.data {
                IndexEntryData::PackageImport { package } => Some(package),
                _ => None,
            })
            .collect();

        assert_eq!(packages, vec!["data.table", "dplyr"]);
        assert!(
            index_document_entries(&doc)
                .into_iter()
                .all(|entry| !matches!(entry.data, IndexEntryData::PackageImport { .. })),
            "targets package imports should only be indexed from _targets.R"
        );
    }

    #[test]
    fn test_index_targets_target_names() {
        let doc = Document::new(
            r#"
list(
    targets::tar_target(raw_data, read.csv("data.csv")),
    tar_target(clean_data, raw_data)
)
"#,
            None,
        );
        let uri = Url::parse("file:///tmp/example/_targets.R").unwrap();

        let targets: Vec<_> = index_document_entries_for_uri(&doc, &uri)
            .into_iter()
            .filter_map(|entry| match entry.data {
                IndexEntryData::Target { name } => Some(name),
                _ => None,
            })
            .collect();

        assert_eq!(targets, vec!["raw_data", "clean_data"]);
        assert!(
            index_document_entries(&doc)
                .into_iter()
                .all(|entry| !matches!(entry.data, IndexEntryData::Target { name } if name == "raw_data" || name == "clean_data")),
            "targets should only be indexed from _targets.R"
        );
    }

    #[test]
    fn test_find_in_document_indexes_open_targets_script_targets() {
        let doc = Document::new(
            r#"
list(
    tar_target(open_target, 1)
)
"#,
            None,
        );
        let uri = Url::parse("file:///tmp/example/_targets.R").unwrap();

        let (_, entry) =
            find_in_document("open_target", &uri, &doc).expect("expected open target definition");

        assert_matches!(
            entry.data,
            IndexEntryData::Target { ref name } if name == "open_target"
        );
    }

    #[test]
    fn test_index_conventional_target_pipeline_names() {
        let doc = Document::new(
            r#"
list(
    tar_target(split_target, 1)
)
"#,
            None,
        );
        let uri = Url::parse("file:///tmp/example/_target_pipelines/analysis.R").unwrap();

        let targets: Vec<_> = index_document_entries_for_uri(&doc, &uri)
            .into_iter()
            .filter_map(|entry| match entry.data {
                IndexEntryData::Target { name } => Some(name),
                _ => None,
            })
            .collect();

        assert_eq!(targets, vec!["split_target"]);
    }

    #[test]
    fn test_index_targets_script_sources_pipeline_files() {
        let _lock = indexer_test_lock();
        let _guard = ResetIndexerGuard;
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let targets_path = tempdir.path().join("_targets.R");
        let pipeline_dir = tempdir.path().join("pipelines");
        let pipeline_path = pipeline_dir.join("analysis.R");

        std::fs::create_dir_all(&pipeline_dir).expect("expected pipeline dir");
        std::fs::write(
            &targets_path,
            r#"
targets::tar_source("pipelines")
"#,
        )
        .expect("expected targets script");
        std::fs::write(
            &pipeline_path,
            r#"
list(
    tar_target(sourced_target, 1)
)
"#,
        )
        .expect("expected pipeline script");

        let targets_uri = Url::from_file_path(&targets_path).expect("expected targets uri");
        let pipeline_uri = Url::from_file_path(&pipeline_path).expect("expected pipeline uri");
        create(&targets_uri).expect("expected targets script indexing");

        let (_, entry) = find_in_file("sourced_target", &pipeline_uri)
            .expect("expected sourced target definition");
        assert_matches!(
            entry.data,
            IndexEntryData::Target { ref name } if name == "sourced_target"
        );
    }

    #[test]
    fn test_index_targets_script_ignores_non_path_source_string_arguments() {
        let _lock = indexer_test_lock();
        let _guard = ResetIndexerGuard;
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let targets_path = tempdir.path().join("_targets.R");
        let pipeline_path = tempdir.path().join("analysis.R");
        let encoding_path = tempdir.path().join("UTF-8.R");

        std::fs::write(
            &targets_path,
            r#"
source("analysis.R", encoding = "UTF-8")
"#,
        )
        .expect("expected targets script");
        std::fs::write(
            &pipeline_path,
            r#"
list(tar_target(real_source_target, 1))
"#,
        )
        .expect("expected pipeline script");
        std::fs::write(
            &encoding_path,
            r#"
list(tar_target(wrong_encoding_target, 1))
"#,
        )
        .expect("expected decoy script");

        let targets_uri = Url::from_file_path(&targets_path).expect("expected targets uri");
        let pipeline_uri = Url::from_file_path(&pipeline_path).expect("expected pipeline uri");
        let encoding_uri = Url::from_file_path(&encoding_path).expect("expected encoding uri");
        create(&targets_uri).expect("expected targets script indexing");

        assert!(find_in_file("real_source_target", &pipeline_uri).is_some());
        assert!(
            find_in_file("wrong_encoding_target", &encoding_uri).is_none(),
            "source() option strings should not be treated as sourced pipeline paths"
        );
    }

    #[test]
    fn test_index_r6class() {
        test_index!(
            r#"
class <- R6Class(
    public = list(
        initialize = function() {
            1
        },
        public_method = function() {
            2
        },
        public_variable = NA
    ),
    private = list(
        private_method = function() {
            1
        },
        private_variable = NA
    ),
    other = list(
        other_method = function() {
            1
        }
    )
)
"#
        );
    }

    #[test]
    fn test_index_r6class_namespaced() {
        test_index!(
            r#"
class <- R6::R6Class(
    public = list(
        initialize = function() {
            1
        },
    )
)
"#
        );
    }

    #[test]
    fn test_index_insert_priority() {
        let mut index = HashMap::new();

        let section_entry = IndexEntry {
            key: "foo".to_string(),
            range: Range::new(
                lsp_types::Position::new(0, 0),
                lsp_types::Position::new(0, 3),
            ),
            data: IndexEntryData::Section {
                level: 1,
                title: "foo".to_string(),
            },
        };

        let variable_entry = IndexEntry {
            key: "foo".to_string(),
            range: Range::new(
                lsp_types::Position::new(1, 0),
                lsp_types::Position::new(1, 3),
            ),
            data: IndexEntryData::Variable {
                name: "foo".to_string(),
            },
        };

        // The Variable has priority and should replace the Section
        index_insert(&mut index, section_entry.clone());
        index_insert(&mut index, variable_entry.clone());
        assert_matches!(
            &index.get("foo").unwrap().data,
            IndexEntryData::Variable { name } => assert_eq!(name, "foo")
        );

        // Inserting a Section again with the same key does not override the Variable
        index_insert(&mut index, section_entry.clone());
        assert_matches!(
            &index.get("foo").unwrap().data,
            IndexEntryData::Variable { name } => assert_eq!(name, "foo")
        );

        let function_entry = IndexEntry {
            key: "foo".to_string(),
            range: Range::new(
                lsp_types::Position::new(2, 0),
                lsp_types::Position::new(2, 3),
            ),
            data: IndexEntryData::Function {
                name: "foo".to_string(),
                arguments: vec!["a".to_string()],
            },
        };

        // Inserting another kind of variable (e.g., Function) with the same key
        // does not override it either. The first occurrence is generally retained.
        index_insert(&mut index, function_entry.clone());
        assert_matches!(
            &index.get("foo").unwrap().data,
            IndexEntryData::Variable { name } => assert_eq!(name, "foo")
        );
    }

    #[test]
    fn test_update_skips_ark_virtual_doc() {
        let _guard = ResetIndexerGuard;

        let ark_uri = Url::parse("ark://namespace/test.R").unwrap();
        let doc = Document::new("foo <- 1", None);

        update(&doc, &ark_uri).unwrap();
        assert!(find("foo").is_none());
    }

    #[test]
    fn test_update_indexes_git_uri() {
        let _guard = ResetIndexerGuard;

        let git_uri = Url::parse("git:///home/user/test.R?ref=HEAD").unwrap();
        let doc = Document::new("foo <- 1", None);

        update(&doc, &git_uri).unwrap();
        assert!(find("foo").is_some());
    }

    #[test]
    fn test_create_skips_non_file_uri() {
        let _guard = ResetIndexerGuard;

        let ark_uri = Url::parse("ark://namespace/test.R").unwrap();

        create(&ark_uri).unwrap();
        assert!(find("foo").is_none());
    }
}
