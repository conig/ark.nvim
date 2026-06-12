use std::env;
use std::fs;
use std::path::Path;
use std::path::PathBuf;

use url::Url;
use yaml_rust2::Yaml;
use yaml_rust2::YamlLoader;

pub(crate) fn targets_config_path(root: &Path) -> PathBuf {
    let config = env::var("TAR_CONFIG")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| String::from("_targets.yaml"));
    let path = PathBuf::from(config);

    if path.is_absolute() {
        path
    } else {
        root.join(path)
    }
}

pub(crate) fn targets_config_value(root: &Path, name: &str) -> Option<String> {
    let config = targets_config_path(root);
    let contents = fs::read_to_string(config).ok()?;
    let docs = YamlLoader::load_from_str(&contents).ok()?;
    let project = env::var("TAR_PROJECT")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| String::from("main"));

    for doc in &docs {
        if let Some(value) = yaml_project_value(doc, &project, name) {
            return Some(value);
        }
    }

    for doc in &docs {
        if let Some(value) = yaml_scalar(&doc[name]) {
            return Some(value);
        }
    }

    None
}

pub(crate) fn targets_resolve_project_path(root: &Path, path: &str) -> Option<PathBuf> {
    if path.is_empty() {
        return None;
    }

    let path = PathBuf::from(path);
    if path.is_absolute() {
        Some(path)
    } else {
        Some(root.join(path))
    }
}

pub(crate) fn targets_script_for_root(root: &Path) -> PathBuf {
    targets_config_value(root, "script")
        .and_then(|script| targets_resolve_project_path(root, &script))
        .unwrap_or_else(|| root.join("_targets.R"))
}

pub(crate) fn find_targets_root_for_path(path: &Path) -> Option<PathBuf> {
    let start = if path.is_dir() { path } else { path.parent()? };

    for ancestor in start.ancestors() {
        if ancestor.join("_targets.R").exists() {
            return Some(ancestor.to_path_buf());
        }

        let config = targets_config_path(ancestor);
        if config.exists() {
            return Some(ancestor.to_path_buf());
        }
    }

    None
}

pub(crate) fn targets_script_for_path(path: &Path) -> Option<PathBuf> {
    let root = find_targets_root_for_path(path)?;
    Some(targets_script_for_root(&root))
}

pub(crate) fn is_targets_script_path(path: &Path) -> bool {
    if path.file_name().is_some_and(|file| file == "_targets.R") {
        return true;
    }

    targets_script_for_path(path).is_some_and(|script| script == path)
}

pub(crate) fn is_targets_script_uri(uri: &Url) -> bool {
    let Ok(path) = uri.to_file_path() else {
        return false;
    };

    is_targets_script_path(&path)
}

pub(crate) fn related_targets_script_uri(uri: &Url) -> Option<Url> {
    let path = uri.to_file_path().ok()?;
    let script = targets_script_for_path(&path)?;

    if !script.exists() {
        return None;
    }

    Url::from_file_path(script).ok()
}

fn yaml_project_value(doc: &Yaml, project: &str, name: &str) -> Option<String> {
    let project = &doc[project];
    if project.is_badvalue() {
        return None;
    }

    yaml_scalar(&project[name])
}

fn yaml_scalar(value: &Yaml) -> Option<String> {
    match value {
        Yaml::String(value) if !value.is_empty() => Some(value.clone()),
        Yaml::Integer(value) => Some(value.to_string()),
        Yaml::Real(value) if !value.is_empty() => Some(value.clone()),
        Yaml::Boolean(value) => Some(value.to_string()),
        _ => None,
    }
}
