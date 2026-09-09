//! One input inventory and content identity for builds and editor reconciliation.
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::path::PathBuf;

fn manifest(path: &Path) -> Result<toml::Value, Box<dyn std::error::Error>> {
    Ok(fs::read_to_string(path)?.parse()?)
}

fn dependencies(
    value: &toml::Value,
    workspace: &toml::Value,
    directory: &Path,
    root: &Path,
    crates: &mut BTreeSet<PathBuf>,
) -> Result<(), Box<dyn std::error::Error>> {
    for section in ["dependencies", "build-dependencies"] {
        if let Some(table) = value.get(section).and_then(toml::Value::as_table) {
            for (name, dependency) in table {
                let inherited =
                    dependency.get("workspace").and_then(toml::Value::as_bool) == Some(true);
                let dependency = if inherited {
                    &workspace["workspace"]["dependencies"][name]
                } else {
                    dependency
                };
                if let Some(path) = dependency.get("path").and_then(toml::Value::as_str) {
                    let path = if inherited { root } else { directory }
                        .join(path)
                        .canonicalize()?;
                    if !path.starts_with(root) {
                        return Err(format!(
                            "local dependency outside checkout: {}",
                            path.display()
                        )
                        .into());
                    }
                    if crates.insert(path.clone()) {
                        dependencies(
                            &manifest(&path.join("Cargo.toml"))?,
                            workspace,
                            &path,
                            root,
                            crates,
                        )?;
                    }
                }
            }
        }
    }
    if let Some(targets) = value.get("target").and_then(toml::Value::as_table) {
        for target in targets.values() {
            dependencies(target, workspace, directory, root, crates)?;
        }
    }
    Ok(())
}

fn collect(path: &Path, paths: &mut BTreeSet<PathBuf>) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() {
        return Err(std::io::Error::other(format!(
            "symlink in build inputs: {}",
            path.display()
        )));
    }
    paths.insert(path.to_path_buf());
    if metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') ||
                matches!(
                    name.as_ref(),
                    "target" | "snapshots" | "tests" | "symbols.rds"
                ) ||
                [".o", ".so", ".a", ".dll", ".dylib"]
                    .iter()
                    .any(|suffix| name.ends_with(suffix))
            {
                continue;
            }
            collect(&entry.path(), paths)?;
        }
    }
    Ok(())
}

pub fn inputs(
    root: &Path,
    component: &str,
) -> Result<BTreeSet<PathBuf>, Box<dyn std::error::Error>> {
    let root = root.canonicalize()?;
    let mut paths = BTreeSet::new();
    if component == "bridge" {
        collect(&root.join("packages/arkbridge"), &mut paths)?;
        collect(&root.join("scripts/ark-install-bridge.R"), &mut paths)?;
    } else if component == "plugin" {
        for path in [
            "lua",
            "plugin",
            "scripts/ark-console",
            "scripts/ark-r-launcher.sh",
        ] {
            collect(&root.join(path), &mut paths)?;
        }
    } else {
        let workspace = manifest(&root.join("Cargo.toml"))?;
        let first = root.join("crates/ark-lsp");
        let mut crates = BTreeSet::from([first.clone()]);
        dependencies(
            &manifest(&first.join("Cargo.toml"))?,
            &workspace,
            &first,
            &root,
            &mut crates,
        )?;
        for directory in crates {
            // Include native assets and build-script inputs, not only *.rs.
            collect(&directory, &mut paths)?;
        }

        for path in [
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "release-manifest.json",
            "build",
            ".cargo",
        ] {
            collect(&root.join(path), &mut paths)?;
        }
    }
    Ok(paths)
}

pub fn fingerprint(root: &Path, paths: &BTreeSet<PathBuf>) -> std::io::Result<String> {
    let mut hash = blake3::Hasher::new();
    hash.update(b"ark-source-v1\0");
    for path in paths {
        if path.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(std::io::Error::other)?
                .to_string_lossy();
            let bytes = fs::read(path)?;
            hash.update(&(relative.len() as u64).to_le_bytes());
            hash.update(relative.as_bytes());
            hash.update(&(bytes.len() as u64).to_le_bytes());
            hash.update(&bytes);
        }
    }
    Ok(hash.finalize().to_hex().to_string())
}

pub fn snapshot(
    root: &Path,
    component: &str,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let root = root.canonicalize()?;
    let paths = inputs(&root, component)?;
    let fingerprint = fingerprint(&root, &paths)?;
    let mut entries = Vec::new();
    for path in paths {
        let metadata = fs::metadata(&path)?;
        #[cfg(unix)]
        let signature = {
            use std::os::unix::fs::MetadataExt;
            format!(
                "{}:{}:{}:{}:{}",
                metadata.len(),
                metadata.mtime(),
                metadata.mtime_nsec(),
                metadata.ctime(),
                metadata.ctime_nsec()
            )
        };
        #[cfg(not(unix))]
        let signature = format!("{:?}:{}", metadata.modified()?, metadata.len());
        entries.push(serde_json::json!({"path": path, "signature": signature}));
    }
    Ok(serde_json::json!({"fingerprint": fingerprint, "inputs": entries}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_content_additions_deletions_and_local_dependencies_but_not_docs() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        fs::create_dir_all(root.join("crates/ark-lsp/src")).unwrap();
        fs::create_dir_all(root.join("crates/support/src")).unwrap();
        fs::write(
            root.join("Cargo.toml"),
            "[workspace.dependencies]\nsupport = {path = 'crates/support'}\n",
        )
        .unwrap();
        fs::write(
            root.join("crates/ark-lsp/Cargo.toml"),
            "[dependencies]\nsupport.workspace = true\n",
        )
        .unwrap();
        fs::write(
            root.join("crates/support/Cargo.toml"),
            "[package]\nname = 'support'\n",
        )
        .unwrap();
        fs::write(root.join("crates/support/src/lib.rs"), "one").unwrap();
        let fingerprint_now = || fingerprint(&root, &inputs(&root, "lsp").unwrap()).unwrap();
        let first = fingerprint_now();
        fs::write(root.join("README.md"), "documentation only").unwrap();
        assert_eq!(first, fingerprint_now());
        fs::write(root.join("crates/support/src/lib.rs"), "two").unwrap();
        let second = fingerprint_now();
        assert_ne!(first, second);
        let extra = root.join("crates/support/src/extra.rs");
        fs::write(&extra, "new module").unwrap();
        assert_ne!(second, fingerprint_now());
        fs::remove_file(extra).unwrap();
        assert_eq!(second, fingerprint_now());
        fs::remove_file(root.join("crates/support/src/lib.rs")).unwrap();
        assert_ne!(second, fingerprint_now());
    }
}
