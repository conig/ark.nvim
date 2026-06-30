//
// search_path.rs
//
// Copyright (C) 2023-2026 Posit Software, PBC. All rights reserved.
//
//

use std::collections::BTreeSet;

use harp::env_parent;
use harp::exec::RFunction;
use harp::exec::RFunctionExt;
use harp::utils::r_env_is_pkg_env;
use harp::utils::r_pkg_env_name;
use harp::vector::CharacterVector;
use harp::vector::Vector;
use harp::RObject;
use libr::R_EmptyEnv;
use libr::R_lsInternal;
use tower_lsp::lsp_types::CompletionItem;

use crate::console;
use crate::lsp::call_context::document_context_matches_package_argument;
use crate::lsp::call_context::PackageCompletionMode;
use crate::lsp::completions::completion_context::CompletionContext;
use crate::lsp::completions::completion_item::completion_item_from_function;
use crate::lsp::completions::completion_item::completion_item_from_package;
use crate::lsp::completions::completion_item::completion_item_from_symbol;
use crate::lsp::completions::sources::utils::filter_out_dot_prefixes;
use crate::lsp::completions::sources::utils::set_sort_text_by_words_first;
use crate::lsp::completions::sources::CompletionSource;
use crate::lsp::completions::types::PromiseStrategy;

pub(super) struct SearchPathSource;

impl CompletionSource for SearchPathSource {
    fn name(&self) -> &'static str {
        "search_path"
    }

    fn provide_completions(
        &self,
        completion_context: &CompletionContext,
    ) -> anyhow::Result<Option<Vec<CompletionItem>>> {
        completions_from_search_path(completion_context)
    }
}

fn completions_from_search_path(
    context: &CompletionContext,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    if !context.state.has_attached_runtime() {
        return completions_from_static_search_path(context);
    }

    let mut completions = vec![];

    const KEYWORD_SOURCE: &[&str] = &[
        "if", "else", "repeat", "while", "function", "for", "in", "next", "break",
    ];

    unsafe {
        // Iterate through environments starting from the current frame environment.
        let env_obj = console::selected_env();
        let mut env = env_obj.sexp;

        while env != R_EmptyEnv {
            let is_pkg_env = r_env_is_pkg_env(env);

            // Get package environment name, if there is one
            let name = if is_pkg_env {
                let name = RObject::from(r_pkg_env_name(env));
                let name = String::try_from(name)?;
                Some(name)
            } else {
                None
            };

            let name = name.as_deref();

            // If this is a package environment, we will need to force promises to give meaningful completions,
            // particularly with functions because we add a `CompletionItem::command()` that adds trailing `()` onto
            // the completion and triggers parameter completions.
            let promise_strategy = if is_pkg_env {
                PromiseStrategy::Force
            } else {
                PromiseStrategy::Simple
            };

            // List symbols in the environment.
            let symbols = R_lsInternal(env, 1);

            // Create completion items for each.
            let vector = CharacterVector::new(symbols)?;
            for symbol in vector.iter() {
                // Skip missing values.
                let Some(symbol) = symbol else {
                    continue;
                };

                // Skip anything that is covered by the keyword source.
                let symbol = symbol.as_str();
                if KEYWORD_SOURCE.contains(&symbol) {
                    continue;
                }

                // Add the completion item.
                match completion_item_from_symbol(
                    symbol,
                    env,
                    name,
                    promise_strategy,
                    context.function_context()?,
                ) {
                    Ok(item) => completions.push(item),
                    Err(err) => {
                        // Log the error but continue processing other symbols
                        log::error!("Failed to get completion item for symbol '{symbol}': {err}");
                        continue;
                    },
                };
            }

            // Get the next environment.
            env = env_parent(env);
        }

        // Include installed packages as well.
        // TODO: This can be slow on NFS.
        let packages = RFunction::new("base", ".packages")
            .param("all.available", true)
            .call()?;

        let append_colons = package_items_should_append_colons(context)?;
        let strings = packages.to::<Vec<String>>()?;
        for string in strings.iter() {
            let item = completion_item_from_package(string, append_colons)?;
            completions.push(item);
        }
    }

    filter_out_dot_prefixes(context.document_context, &mut completions);

    // Push search path completions starting with non-word characters to the
    // bottom of the sort list (like those starting with `.`, or `%>%`)
    set_sort_text_by_words_first(&mut completions);

    Ok(Some(completions))
}

fn completions_from_static_search_path(
    context: &CompletionContext,
) -> anyhow::Result<Option<Vec<CompletionItem>>> {
    let mut completions = Vec::new();

    const KEYWORD_SOURCE: &[&str] = &[
        "if", "else", "repeat", "while", "function", "for", "in", "next", "break",
    ];

    let mut seen = BTreeSet::new();
    let function_context = context.function_context()?;
    for symbol in context
        .state
        .console_scopes
        .iter()
        .flat_map(|scope| scope.iter())
    {
        if KEYWORD_SOURCE.contains(&symbol.as_str()) || !seen.insert(symbol.clone()) {
            continue;
        }

        let item = completion_item_from_function(symbol, None, function_context)?;
        completions.push(item);
    }

    let append_colons = package_items_should_append_colons(context)?;
    for package in context.state.installed_packages.iter() {
        if !seen.insert(package.clone()) {
            continue;
        }

        let item = unsafe { completion_item_from_package(package, append_colons)? };
        completions.push(item);
    }

    filter_out_dot_prefixes(context.document_context, &mut completions);
    set_sort_text_by_words_first(&mut completions);

    Ok(Some(completions))
}

fn package_items_should_append_colons(context: &CompletionContext) -> anyhow::Result<bool> {
    Ok(!document_context_matches_package_argument(
        context.document_context,
        PackageCompletionMode::BareSymbol,
    )?)
}

#[cfg(test)]
mod tests {
    use crate::fixtures::point_from_cursor;
    use crate::lsp::completions::completion_context::CompletionContext;
    use crate::lsp::completions::sources::composite::search_path::completions_from_static_search_path;
    use crate::lsp::document::Document;
    use crate::lsp::document_context::DocumentContext;
    use crate::lsp::state::RuntimeMode;
    use crate::lsp::state::WorldState;

    #[test]
    fn test_static_installed_packages_do_not_append_namespace_colons_in_library_call() {
        let (text, point) = point_from_cursor("library(ggplo@)");
        let document = Document::new(text.as_str(), None);
        let document_context = DocumentContext::new(&document, point, None);
        let state = WorldState {
            runtime_mode: RuntimeMode::Detached,
            installed_packages: vec![String::from("ggplot2")],
            ..Default::default()
        };
        let context = CompletionContext::new(&document_context, &state);

        let completions = completions_from_static_search_path(&context)
            .unwrap()
            .unwrap();
        let item = completions
            .iter()
            .find(|item| item.label == "ggplot2")
            .unwrap();

        assert_eq!(item.insert_text.as_deref(), Some("ggplot2"));
        assert!(item.command.is_none());
    }
}
