use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;

use ignore::DirEntry;
use ignore::WalkBuilder;

const SKIPPED_DIRECTORIES: [&str; 6] = [
    ".git",
    ".Rproj.user",
    "node_modules",
    "revdep",
    "renv",
    "target",
];

#[derive(Debug, Default)]
pub(crate) struct FileDiscovery {
    pub(crate) paths: Vec<PathBuf>,
    pub(crate) error_count: usize,
}

pub(crate) fn r_files(roots: &[PathBuf]) -> FileDiscovery {
    discover_files(roots, is_r_file)
}

pub(crate) fn reference_files(roots: &[PathBuf]) -> FileDiscovery {
    discover_files(roots, is_reference_file)
}

fn discover_files(roots: &[PathBuf], include: fn(&Path) -> bool) -> FileDiscovery {
    let mut paths = HashSet::new();
    let mut error_count = 0;

    for root in roots {
        let mut builder = WalkBuilder::new(root);
        builder
            .standard_filters(true)
            .hidden(false)
            .ignore(true)
            .git_ignore(true)
            .git_global(true)
            .git_exclude(true)
            .parents(true)
            .require_git(false)
            .follow_links(false)
            .filter_entry(include_entry);

        for entry in builder.build() {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    tracing::warn!(root = %root.display(), %error, "Workspace walk entry failed");
                    error_count += 1;
                    continue;
                },
            };

            if entry
                .file_type()
                .is_some_and(|file_type| file_type.is_file()) &&
                include(entry.path())
            {
                paths.insert(entry.into_path());
            }
        }
    }

    let mut paths: Vec<_> = paths.into_iter().collect();
    paths.sort();
    FileDiscovery { paths, error_count }
}

fn include_entry(entry: &DirEntry) -> bool {
    if !entry
        .file_type()
        .is_some_and(|file_type| file_type.is_dir())
    {
        return true;
    }

    let Some(name) = entry.file_name().to_str() else {
        return true;
    };

    !SKIPPED_DIRECTORIES.contains(&name)
}

fn is_r_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| matches!(extension, "r" | "R"))
}

fn is_reference_file(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "r" | "rmd" | "qmd" | "quarto"
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("expected parent directory");
        }
        std::fs::write(path, "value <- 1\n").expect("expected fixture file");
    }

    #[test]
    fn r_files_honors_ignore_sources_and_explicit_directory_skips() {
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let root = tempdir.path();
        write(&root.join("visible.R"));
        write(&root.join("visible.txt"));
        write(&root.join("excluded.R"));
        write(&root.join("generated/ignored.R"));
        write(&root.join("nested/keep.R"));
        write(&root.join("nested/private/ignored.R"));

        std::fs::write(root.join(".gitignore"), "generated/\n").expect("expected gitignore");
        std::fs::write(root.join("nested/.ignore"), "private/\n").expect("expected nested ignore");
        std::fs::create_dir_all(root.join(".git/info")).expect("expected git metadata");
        std::fs::write(root.join(".git/info/exclude"), "excluded.R\n")
            .expect("expected git excludes");

        for directory in SKIPPED_DIRECTORIES {
            write(&root.join(directory).join("ignored.R"));
        }

        let discovery = r_files(&[root.to_path_buf()]);
        let relative: Vec<_> = discovery
            .paths
            .iter()
            .map(|path| path.strip_prefix(root).unwrap().to_path_buf())
            .collect();

        assert_eq!(relative, vec![
            PathBuf::from("nested/keep.R"),
            PathBuf::from("visible.R")
        ]);
        assert_eq!(discovery.error_count, 0);
    }

    #[test]
    fn overlapping_roots_deduplicate_discovered_files() {
        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let nested = tempdir.path().join("nested");
        let file = nested.join("helper.R");
        write(&file);

        let discovery = r_files(&[tempdir.path().to_path_buf(), nested]);

        assert_eq!(discovery.paths, vec![file]);
    }

    #[cfg(unix)]
    #[test]
    fn directory_symlinks_are_not_followed() {
        use std::os::unix::fs::symlink;

        let tempdir = tempfile::tempdir().expect("expected tempdir");
        let external = tempfile::tempdir().expect("expected external tempdir");
        write(&external.path().join("outside.R"));
        symlink(external.path(), tempdir.path().join("linked"))
            .expect("expected directory symlink");

        let discovery = r_files(&[tempdir.path().to_path_buf()]);

        assert!(discovery.paths.is_empty());
    }
}
