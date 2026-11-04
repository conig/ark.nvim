use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::anyhow;

use crate::lsp::session_bridge::HelpPage;
use crate::lsp::session_bridge::SessionBootstrap;
use crate::lsp::session_bridge::SessionBootstrapTimings;

mod worker;

const LIBRARY_PATHS_MARKER: &str = "__ARK_LIBRARY_PATHS__";
const INSTALLED_PACKAGES_MARKER: &str = "__ARK_INSTALLED_PACKAGES__";
const SEARCH_PATH_SYMBOLS_MARKER: &str = "__ARK_SEARCH_PATH_SYMBOLS__";
const STATIC_OBJECT_MEMBERS_MARKER: &str = "__ARK_STATIC_OBJECT_MEMBERS__";

pub(crate) fn bootstrap() -> anyhow::Result<SessionBootstrap> {
    let started = Instant::now();
    let output = worker::request("bootstrap")?;
    let parsed = parse_baseline_output(&output)?;
    let total_ms = millis(started);

    Ok(SessionBootstrap {
        search_path_symbols: parsed.search_path_symbols,
        installed_packages: parsed.installed_packages,
        library_paths: parsed
            .library_paths
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        static_object_members: parsed.static_object_members,
        timings: SessionBootstrapTimings {
            total_ms,
            search_path_symbols_ms: 0,
            library_paths_ms: 0,
        },
    })
}

pub(crate) fn help_text(topic: &str) -> anyhow::Result<Option<HelpPage>> {
    let topic = topic.trim();
    if topic.is_empty() {
        return Ok(None);
    }

    // Keep an encoded request smaller than a pipe buffer, even if a broken
    // helper never reads stdin, so the response deadline still bounds it.
    if topic.len() > 1024 {
        return Err(anyhow!("help topic is too long"));
    }

    // Hex encoding is data-only, unlike interpolating an R expression.
    let encoded: String = topic
        .as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    match worker::request(&format!("help {encoded}")) {
        Ok(text) => {
            let text = clean_rd2txt_output(text.as_str()).trim().to_string();
            if text.is_empty() {
                Ok(None)
            } else {
                Ok(Some(HelpPage {
                    text,
                    references: Vec::new(),
                }))
            }
        },
        Err(err) if err.to_string().contains("ARK_HELP_NOT_FOUND") => Ok(None),
        Err(err) => Err(err),
    }
}

fn clean_rd2txt_output(text: &str) -> String {
    let mut cleaned = String::with_capacity(text.len());

    for character in text.chars() {
        if character == '\x08' {
            cleaned.pop();
        } else {
            cleaned.push(character);
        }
    }

    cleaned
}

#[derive(Default)]
struct BaselineOutput {
    library_paths: Vec<String>,
    installed_packages: Vec<String>,
    search_path_symbols: Vec<String>,
    static_object_members: HashMap<String, Vec<String>>,
}

fn parse_baseline_output(output: &str) -> anyhow::Result<BaselineOutput> {
    enum Section {
        None,
        LibraryPaths,
        InstalledPackages,
        SearchPathSymbols,
        StaticObjectMembers,
    }

    let mut parsed = BaselineOutput::default();
    let mut section = Section::None;

    for line in output.lines() {
        match line {
            LIBRARY_PATHS_MARKER => {
                section = Section::LibraryPaths;
                continue;
            },
            INSTALLED_PACKAGES_MARKER => {
                section = Section::InstalledPackages;
                continue;
            },
            SEARCH_PATH_SYMBOLS_MARKER => {
                section = Section::SearchPathSymbols;
                continue;
            },
            STATIC_OBJECT_MEMBERS_MARKER => {
                section = Section::StaticObjectMembers;
                continue;
            },
            _ => {},
        }

        let value = line.trim();
        if value.is_empty() {
            continue;
        }

        match section {
            Section::None => {},
            Section::LibraryPaths => parsed.library_paths.push(value.to_string()),
            Section::InstalledPackages => parsed.installed_packages.push(value.to_string()),
            Section::SearchPathSymbols => parsed.search_path_symbols.push(value.to_string()),
            Section::StaticObjectMembers => {
                if let Some((object, member)) = value.split_once('\t') {
                    let object = object.trim();
                    let member = member.trim();
                    if !object.is_empty() && !member.is_empty() {
                        parsed
                            .static_object_members
                            .entry(object.to_string())
                            .or_default()
                            .push(member.to_string());
                    }
                }
            },
        }
    }

    if parsed.library_paths.is_empty() {
        return Err(anyhow!(
            "detached R metadata helper returned no library paths"
        ));
    }

    parsed.installed_packages.sort();
    parsed.installed_packages.dedup();
    parsed.search_path_symbols.sort();
    parsed.search_path_symbols.dedup();
    for members in parsed.static_object_members.values_mut() {
        members.sort();
        members.dedup();
    }

    Ok(parsed)
}

fn millis(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

const BASELINE_SCRIPT: &str = r#"
local({
  cat("__ARK_LIBRARY_PATHS__\n")
  writeLines(normalizePath(base::.libPaths(), winslash = "/", mustWork = FALSE))

  cat("__ARK_INSTALLED_PACKAGES__\n")
  writeLines(base::.packages(all.available = TRUE))

  cat("__ARK_SEARCH_PATH_SYMBOLS__\n")
  envs <- base::setdiff(base::search(), ".GlobalEnv")
  symbols <- base::unique(base::unlist(base::lapply(envs, function(name) {
    base::ls(base::as.environment(name), all.names = TRUE)
  }), use.names = FALSE))
  writeLines(base::as.character(symbols))

  cat("__ARK_STATIC_OBJECT_MEMBERS__\n")
  for (env_name in envs) {
    env <- base::as.environment(env_name)
    for (object_name in base::ls(env, all.names = TRUE)) {
      value <- base::tryCatch(base::get(object_name, envir = env, inherits = FALSE), error = function(e) NULL)
      members <- NULL

      if (base::is.data.frame(value)) {
        members <- base::names(value)
      } else if (base::is.matrix(value) || base::length(base::dim(value)) >= 2) {
        members <- base::colnames(value)
      } else if (base::is.list(value)) {
        members <- base::names(value)
      }

      members <- members[!base::is.na(members) & base::nzchar(members)]
      if (base::length(members) > 0) {
        writeLines(base::paste(object_name, members, sep = "\t"))
      }
    }
  }
})
"#;

const HELP_TEXT_SCRIPT: &str = r#"
local({
  pkg_name <- NULL

  if (base::grepl("::", topic, fixed = TRUE)) {
    parts <- base::strsplit(topic, "::", fixed = TRUE)[[1]]
    pkg_name <- parts[[1]]
    topic <- parts[[length(parts)]]
  }

  help <- if (is.null(pkg_name)) {
    base::do.call(utils::help, base::list(topic = topic, package = help_packages))
  } else {
    base::do.call(utils::help, base::list(topic = topic, package = pkg_name))
  }

  if (base::length(help) == 0) {
    base::stop("ARK_HELP_NOT_FOUND")
  }

  rd <- utils:::.getHelpFile(help)
  tools::Rd2txt(rd)
})
"#;

#[cfg(test)]
mod tests {
    use std::process::Command;

    use super::*;

    #[test]
    fn parses_sectioned_baseline_output() {
        let parsed = parse_baseline_output(
            r#"
__ARK_LIBRARY_PATHS__
/tmp/R lib
/opt/R/lib
__ARK_INSTALLED_PACKAGES__
utils
base
utils
__ARK_SEARCH_PATH_SYMBOLS__
library
mean
library
__ARK_STATIC_OBJECT_MEMBERS__
mtcars	mpg
mtcars	cyl
mtcars	mpg
"#,
        )
        .unwrap();

        assert_eq!(parsed.library_paths, vec![
            String::from("/tmp/R lib"),
            String::from("/opt/R/lib")
        ]);
        assert_eq!(parsed.installed_packages, vec![
            String::from("base"),
            String::from("utils")
        ]);
        assert_eq!(parsed.search_path_symbols, vec![
            String::from("library"),
            String::from("mean")
        ]);
        assert_eq!(parsed.static_object_members.get("mtcars").unwrap(), &vec![
            String::from("cyl"),
            String::from("mpg")
        ]);
    }

    #[test]
    fn help_text_finds_qualified_function_topic() {
        if Command::new("Rscript").arg("--version").output().is_err() {
            return;
        }

        let help = help_text("utils::head")
            .expect("expected help lookup to succeed")
            .expect("expected help text for utils::head");

        assert!(help.text.contains("head"));
        assert!(!help.text.contains('\x08'));
    }

    #[test]
    fn help_worker_survives_missing_and_source_like_topics() {
        if Command::new("Rscript").arg("--version").output().is_err() {
            return;
        }
        assert!(help_text("Rd2txt").unwrap().is_none());
        let before = help_text("base::mean").unwrap().unwrap();
        // Rd rendering loads tools, but must not widen vanilla topic lookup.
        assert!(help_text("Rd2txt").unwrap().is_none());
        assert!(help_text("ark_missing_help_topic_982374")
            .unwrap()
            .is_none());
        assert!(help_text("\"; stop('not R source'); #\nλ")
            .unwrap()
            .is_none());
        let after = help_text("base::mean").unwrap().unwrap();
        assert_eq!(before.text, after.text);
        assert!(help_text(&"x".repeat(1025)).is_err());
    }

    #[test]
    fn cleans_rd2txt_overstrike_sequences() {
        let text =
            "_\x08D_\x08e_\x08s_\x08c_\x08r_\x08i_\x08p_\x08t_\x08i_\x08o_\x08n:\nD\x08Do\x08oc";

        let cleaned = clean_rd2txt_output(text);

        assert_eq!(cleaned, "Description:\nDoc");
    }
}
