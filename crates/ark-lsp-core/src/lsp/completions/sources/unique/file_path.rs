//
// file_path.rs
//
// Copyright (C) 2023-2025 Posit Software, PBC. All rights reserved.
//
//

use std::env::current_dir;
use std::env::var_os;
use std::path::PathBuf;

use harp::utils::r_is_string;
use harp::utils::r_normalize_path;
use stdext::unwrap;
use tower_lsp::lsp_types::CompletionItem;
use tree_sitter::Node;

use crate::lsp::completions::completion_item::completion_item_from_direntry;
use crate::lsp::completions::sources::utils::set_sort_text_by_words_first;
use crate::lsp::document_context::DocumentContext;
use crate::lsp::traits::node::NodeExt;

pub(super) fn completions_from_string_file_path(
    node: &Node,
    context: &DocumentContext,
) -> anyhow::Result<Vec<CompletionItem>> {
    log::trace!("completions_from_string_file_path()");

    let mut completions: Vec<CompletionItem> = vec![];

    // Get the contents of the string token.
    //
    // NOTE: This includes the quotation characters on the string, and so
    // also includes any internal escapes! We need to decode the R string
    // by parsing it before searching the path entries.
    let token = node.node_as_str(&context.document.contents)?;

    let Some(mut path) = normalize_string_path(token)? else {
        return Ok(completions);
    };

    // parse the file path and get the directory component
    log::trace!("Normalized path: {}", path.display());

    // if this path doesn't have a root, add it on
    if !path.has_root() {
        let root = current_dir()?;
        path = root.join(path);
    }

    // if this isn't a directory, get the parent path
    if !path.is_dir() {
        if let Some(parent) = path.parent() {
            path = parent.to_path_buf();
        }
    }

    // look for files in this directory
    log::trace!("Reading directory: {}", path.display());
    let entries = std::fs::read_dir(path)?;

    for entry in entries.into_iter() {
        let entry = unwrap!(entry, Err(error) => {
            log::error!("{}", error);
            continue;
        });

        let item = unwrap!(completion_item_from_direntry(entry), Err(error) => {
            log::error!("{}", error);
            continue;
        });

        completions.push(item);
    }

    // Push path completions starting with non-word characters to the bottom of
    // the sort list (like those starting with `.`)
    set_sort_text_by_words_first(&mut completions);

    Ok(completions)
}

fn normalize_string_path(token: &str) -> anyhow::Result<Option<PathBuf>> {
    if crate::console::Console::is_initialized() {
        return normalize_string_path_with_r(token);
    }

    Ok(normalize_string_path_detached(token))
}

fn normalize_string_path_with_r(token: &str) -> anyhow::Result<Option<PathBuf>> {
    // It's entirely possible that we can fail to parse the string, `R_ParseVector()`
    // can fail in various ways. We silently swallow these because they are unlikely
    // to report to real file paths and just bail (posit-dev/positron#6584).
    let Ok(contents) = harp::parse_expr(token) else {
        return Ok(None);
    };

    // Double check that parsing gave a string. It should, because `node` points to
    // a tree-sitter string node.
    if !r_is_string(contents.sexp) {
        return Ok(None);
    }

    // Use R to normalize the path when local R is available.
    let path = r_normalize_path(contents)?;
    Ok(Some(PathBuf::from(path.as_str())))
}

fn normalize_string_path_detached(token: &str) -> Option<PathBuf> {
    let contents = decode_string_token(token)?;
    Some(expand_tilde_path(&contents))
}

fn decode_string_token(token: &str) -> Option<String> {
    let quote = token.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }

    if token.len() < 2 || !token.ends_with(quote) {
        return None;
    }

    let mut chars = token[1..token.len() - 1].chars();
    let mut contents = String::new();

    while let Some(ch) = chars.next() {
        if ch != '\\' {
            contents.push(ch);
            continue;
        }

        let escaped = chars.next()?;
        match escaped {
            '\\' => contents.push('\\'),
            '"' => contents.push('"'),
            '\'' => contents.push('\''),
            'a' => contents.push('\u{0007}'),
            'b' => contents.push('\u{0008}'),
            'f' => contents.push('\u{000C}'),
            'n' => contents.push('\n'),
            'r' => contents.push('\r'),
            't' => contents.push('\t'),
            'v' => contents.push('\u{000B}'),
            _ => return None,
        }
    }

    Some(contents)
}

fn expand_tilde_path(path: &str) -> PathBuf {
    if path == "~" {
        if let Some(home) = var_os("HOME") {
            return PathBuf::from(home);
        }
    }

    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }

    PathBuf::from(path)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use crate::fixtures::point_from_cursor;
    use crate::lsp::completions::sources::unique::file_path::completions_from_string_file_path;
    use crate::lsp::completions::sources::unique::file_path::decode_string_token;
    use crate::lsp::completions::sources::unique::file_path::expand_tilde_path;
    use crate::lsp::document::Document;
    use crate::lsp::document_context::DocumentContext;
    use crate::r_task;
    use crate::treesitter::node_find_string;

    #[test]
    fn test_unparseable_string() {
        // https://github.com/posit-dev/positron/issues/6584
        r_task(|| {
            // "\R" is an unrecognized escape character and `R_ParseVector()` errors on it
            let (text, point) = point_from_cursor(r#" ".\R\utils.R@" "#);
            let document = Document::new(text.as_str(), None);
            let context = DocumentContext::new(&document, point, None);
            let node = node_find_string(&context.node).unwrap();

            let completions = completions_from_string_file_path(&node, &context).unwrap();
            assert_eq!(completions.len(), 0);
        })
    }

    #[test]
    fn test_decode_string_token() {
        assert_eq!(decode_string_token("\".R\""), Some(String::from(".R")));
        assert_eq!(decode_string_token("\" .R \""), Some(String::from(" .R ")));
        assert_eq!(decode_string_token(r#""\.R""#), None);
        assert_eq!(decode_string_token(r#""a\\b""#), Some(String::from("a\\b")));
        assert_eq!(decode_string_token(r#""a\nb""#), Some(String::from("a\nb")));
        assert_eq!(decode_string_token(r#"'a\'b'"#), Some(String::from("a'b")));
    }

    #[test]
    fn test_expand_tilde_path_passthrough() {
        assert_eq!(expand_tilde_path(".R"), PathBuf::from(".R"));
    }
}
