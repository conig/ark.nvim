//
// keyword.rs
//
// Copyright (C) 2023-2025 Posit Software, PBC. All rights reserved.
//
//

use tower_lsp::lsp_types::CompletionItem;
use tower_lsp::lsp_types::CompletionItemKind;
use tower_lsp::lsp_types::CompletionItemLabelDetails;

use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::CompletionData;

pub(super) struct KeywordSource;

impl CompletionSource for KeywordSource {
    fn name(&self) -> &'static str {
        "keyword"
    }

    fn provide_completions(
        &self,
        _completion_context: &CompletionContext,
    ) -> anyhow::Result<Option<Vec<CompletionItem>>> {
        completions_from_keywords()
    }
}

pub fn completions_from_keywords() -> anyhow::Result<Option<Vec<CompletionItem>>> {
    Ok(Some(
        BARE_KEYWORDS
            .iter()
            .filter_map(|keyword| {
                let item = completion_item(keyword, CompletionData::Keyword {
                    name: keyword.to_string(),
                });

                let mut item = match item {
                    Ok(item) => item,
                    Err(err) => {
                        log::error!(
                            "Failed to construct completion item for keyword '{keyword}' due to {err:?}."
                        );
                        return None;
                    },
                };

                item.kind = Some(CompletionItemKind::KEYWORD);
                item.label_details = Some(CompletionItemLabelDetails {
                    detail: None,
                    description: Some("[keyword]".to_string()),
                });

                Some(item)
            })
            .collect(),
    ))
}

const BARE_KEYWORDS: &[&str] = &[
    "TRUE",
    "FALSE",
    "NULL",
    "Inf",
    "NaN",
    "NA",
    "NA_integer_",
    "NA_real_",
    "NA_complex_",
    "NA_character_",
    "if",
    "else",
    "repeat",
    "while",
    "function",
    "for",
    "in",
    "next",
    "break",
];

#[cfg(test)]
mod tests {
    use tower_lsp::lsp_types::CompletionItemLabelDetails;
    use tower_lsp::lsp_types::{self};

    #[test]
    fn test_presence_bare_keywords() {
        let completions = super::completions_from_keywords().unwrap().unwrap();
        let keyword_completions: Vec<_> = completions
            .iter()
            .filter(|item| item.kind == Some(lsp_types::CompletionItemKind::KEYWORD))
            .collect();

        for keyword in super::BARE_KEYWORDS {
            let item = keyword_completions
                .iter()
                .find(|item| item.label == *keyword);
            assert!(
                item.is_some(),
                "Expected keyword '{keyword}' not found in completions"
            );
            let item = item.unwrap();
            assert_eq!(
                item.label_details,
                Some(CompletionItemLabelDetails {
                    detail: None,
                    description: Some("[keyword]".to_string()),
                })
            );
        }
    }

    #[test]
    fn test_no_keyword_snippets() {
        let completions = super::completions_from_keywords().unwrap().unwrap();
        assert!(completions
            .iter()
            .all(|item| item.kind != Some(lsp_types::CompletionItemKind::SNIPPET)));
    }
}
