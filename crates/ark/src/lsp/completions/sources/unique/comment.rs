//
// comment.rs
//
// Copyright (C) 2023-2025 Posit Software, PBC. All rights reserved.
//
//

use std::path::PathBuf;
use std::sync::LazyLock;
use std::sync::Mutex;

use anyhow::anyhow;
use harp::exec::RFunction;
use harp::exec::RFunctionExt;
use regex::Regex;
use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::Documentation;
use tower_lsp::lsp_types::InsertTextFormat;
use tower_lsp::lsp_types::MarkupContent;
use tower_lsp::lsp_types::MarkupKind;
use yaml_rust::YamlLoader;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::CompletionData;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::traits::node::NodeExt;
use crate::treesitter::NodeTypeExt;

static ROXYGEN_TAG_PATTERN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^.*\s").unwrap());
static ROXYGEN_TAG_CACHE: LazyLock<Mutex<Option<CachedRoxygenTags>>> =
    LazyLock::new(|| Mutex::new(None));

#[derive(Clone, Debug, PartialEq, Eq)]
struct CachedRoxygenTags {
    path: PathBuf,
    items: Vec<RoxygenTagEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RoxygenTagEntry {
    name: String,
    template: Option<String>,
    description: Option<String>,
}

pub(super) struct CommentSource;

impl CompletionSource for CommentSource {
    fn name(&self) -> &'static str {
        "comment"
    }

    fn provide_completions(
        &self,
        completion_context: &CompletionContext,
    ) -> anyhow::Result<Option<Vec<CompletionItem>>> {
        completions_from_comment(completion_context.document_context)
    }
}

fn completions_from_comment(
    context: &DocumentContext,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    let node = context.node;

    if !node.is_comment() {
        return Ok(None);
    }

    let contents = node.node_as_str(&context.document.contents)?;
    let token = ROXYGEN_TAG_PATTERN.replace(contents, "");

    let mut completions: Vec<CompletionItem> = vec![];

    if !token.starts_with('@') {
        // We are done, there are no completions, but we are in a comment so
        // no one else should get a chance to register anything
        return Ok(Some(completions));
    }

    for entry in roxygen_tag_entries()?.iter() {
        let item = completion_item_from_roxygen(
            entry.name.as_str(),
            entry.template.as_deref(),
            entry.description.as_deref(),
        )?;

        completions.push(item);
    }

    Ok(Some(completions))
}

fn roxygen_tag_entries() -> anyhow::Result<Vec<RoxygenTagEntry>> {
    let Some(path) = roxygen_tag_path()? else {
        return Ok(vec![]);
    };

    {
        let cache = ROXYGEN_TAG_CACHE
            .lock()
            .map_err(|err| anyhow!("failed to lock roxygen tag cache: {err}"))?;
        if let Some(cache) = cache.as_ref() {
            if cache.path == path {
                return Ok(cache.items.clone());
            }
        }
    }

    let items = load_roxygen_tag_entries(&path)?;
    let cached = CachedRoxygenTags {
        path,
        items: items.clone(),
    };

    let mut cache = ROXYGEN_TAG_CACHE
        .lock()
        .map_err(|err| anyhow!("failed to lock roxygen tag cache: {err}"))?;
    *cache = Some(cached);

    Ok(items)
}

fn roxygen_tag_path() -> anyhow::Result<Option<PathBuf>> {
    let path = RFunction::new("base", "system.file")
        .param("package", "roxygen2")
        .add("roxygen2-tags.yml")
        .call()?
        .to::<String>()?;

    if path.is_empty() {
        return Ok(None);
    }

    let path = PathBuf::from(path);
    if !path.exists() {
        return Ok(None);
    }

    Ok(Some(path))
}

fn load_roxygen_tag_entries(path: &PathBuf) -> anyhow::Result<Vec<RoxygenTagEntry>> {
    let contents = std::fs::read_to_string(path)?;
    parse_roxygen_tag_entries(contents.as_str())
}

fn parse_roxygen_tag_entries(contents: &str) -> anyhow::Result<Vec<RoxygenTagEntry>> {
    let docs = YamlLoader::load_from_str(contents)
        .map_err(|err| anyhow!("failed to parse roxygen tags: {err}"))?;
    let Some(doc) = docs.first() else {
        return Ok(vec![]);
    };

    let Some(items) = doc.as_vec() else {
        return Ok(vec![]);
    };

    let mut out = Vec::new();
    for entry in items.iter() {
        let Some(name) = entry["name"].as_str() else {
            continue;
        };

        out.push(RoxygenTagEntry {
            name: name.to_string(),
            template: entry["template"]
                .as_str()
                .map(inject_roxygen_comment_after_newline),
            description: entry["description"].as_str().map(str::to_string),
        });
    }

    Ok(out)
}

fn completion_item_from_roxygen(
    name: &str,
    template: Option<&str>,
    description: Option<&str>,
) -> anyhow::Result<CompletionItem> {
    let label = name.to_string();

    let mut item = completion_item(
        label.clone(),
        CompletionData::RoxygenTag { tag: label.clone() },
    )?;

    // TODO: What is the appropriate icon for us to use here?
    if let Some(template) = template {
        item.insert_text_format = Some(InsertTextFormat::SNIPPET);
        item.insert_text = Some(format!("{name}{template}"));
    } else {
        item.insert_text = Some(label.to_string());
    }

    item.detail = Some(format!("roxygen @{} (R)", name));
    if let Some(description) = description {
        let markup = MarkupContent {
            kind: MarkupKind::Markdown,
            value: description.to_string(),
        };
        item.documentation = Some(Documentation::MarkupContent(markup));
    }

    Ok(item)
}

fn inject_roxygen_comment_after_newline(x: &str) -> String {
    x.replace("\n", "\n#' ")
}

#[test]
fn test_comment() {
    use tree_sitter::Point;

    use crate::lsp::document::Document;
    use crate::r_task;

    r_task(|| {
        // If not in a comment, return `None`
        let point = Point { row: 0, column: 1 };
        let document = Document::new("mean()", None);
        let context = DocumentContext::new(&document, point, None);
        let completions = completions_from_comment(&context).unwrap();
        assert!(completions.is_none());

        // If in a comment, return empty vector
        let point = Point { row: 0, column: 1 };
        let document = Document::new("# mean", None);
        let context = DocumentContext::new(&document, point, None);
        let completions = completions_from_comment(&context).unwrap().unwrap();
        assert!(completions.is_empty());
    });
}

#[test]
fn test_roxygen_comment() {
    use libr::LOGICAL_ELT;
    use tree_sitter::Point;

    use crate::lsp::document::Document;
    use crate::r_task;

    r_task(|| unsafe {
        let installed = RFunction::new("", ".ps.is_installed")
            .add("roxygen2")
            .add("7.2.1.9000")
            .call()
            .unwrap();
        let installed = LOGICAL_ELT(*installed, 0) != 0;

        if !installed {
            return;
        }

        let point = Point { row: 0, column: 4 };
        let document = Document::new("#' @", None);
        let context = DocumentContext::new(&document, point, None);
        let completions = completions_from_comment(&context).unwrap().unwrap();

        // Make sure we find it
        let aliases: Vec<&CompletionItem> = completions
            .iter()
            .filter(|item| item.label == "aliases")
            .collect();
        assert_eq!(aliases.len(), 1);

        // Replace `\n` with `\n#' ` since we are directly injecting into the
        // document with no allowance for context specific rules to kick in
        // and automatically add the leading comment for us.
        let description: Vec<&CompletionItem> = completions
            .iter()
            .filter(|item| item.label == "description")
            .collect();
        let description = description.first().unwrap();
        assert_eq!(
            description.insert_text,
            Some(String::from(
                "description\n#' ${1:A short description...}\n#' "
            ))
        );
    });
}

#[test]
fn test_roxygen_completion_item() {
    let name = "aliases";
    let template = " ${1:alias}";
    let description = "Add additional aliases to the topic.";

    // With all optional details
    let item = completion_item_from_roxygen(name, Some(template), Some(description)).unwrap();
    assert_eq!(item.label, name);
    assert_eq!(item.detail, Some("roxygen @aliases (R)".to_string()));
    assert_eq!(item.insert_text, Some("aliases ${1:alias}".to_string()));

    let markup = Documentation::MarkupContent(MarkupContent {
        kind: MarkupKind::Markdown,
        value: description.to_string(),
    });
    assert_eq!(item.documentation, Some(markup));

    // Without optional details
    let name = "export";
    let item = completion_item_from_roxygen(name, None, None).unwrap();
    assert_eq!(item.label, name);
    assert_eq!(item.insert_text, Some("export".to_string()));
    assert_eq!(item.documentation, None);
}

#[test]
fn test_parse_roxygen_tag_entries() {
    let entries = parse_roxygen_tag_entries(
        r#"
- name: description
  template: |
    ${1:A short description...}
  description: Explain the object.
- name: export
"#,
    )
    .unwrap();

    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].name, "description");
    assert_eq!(
        entries[0].template,
        Some("${1:A short description...}\n#' ".to_string())
    );
    assert_eq!(
        entries[0].description,
        Some("Explain the object.".to_string())
    );
    assert_eq!(entries[1].name, "export");
    assert_eq!(entries[1].template, None);
    assert_eq!(entries[1].description, None);
}
