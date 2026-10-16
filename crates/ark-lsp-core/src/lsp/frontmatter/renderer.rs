//! Renderer discovery is scheduled by the main loop. Completion snapshots only
//! read this bounded cache; they never load packages, stat files, or wait for R.
use std::collections::HashMap;
use std::collections::HashSet;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;
use std::time::SystemTime;

use anyhow::anyhow;
use serde::Deserialize;
use tokio::io::AsyncReadExt;
use tokio::io::AsyncWriteExt;
use url::Url;
use yaml_rust2::Yaml;

use super::semantic;
use crate::lsp::document::Document;
use crate::lsp::state::WorldState;

const MAX_ENTRIES: usize = 32;
const REFRESH_AFTER: Duration = Duration::from_secs(60);
const MAX_OUTPUT: u64 = 1024 * 1024;
const SCRIPT: &str = include_str!("renderer_schema.R");

#[derive(Clone, Debug, Default, Deserialize)]
pub(crate) struct Field {
    pub path: Vec<String>,
    pub choices: Vec<String>,
    #[serde(default)]
    pub boolean: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(crate) struct Schema {
    pub options: Vec<Field>,
    pub metadata: Vec<Field>,
    #[serde(default)]
    headers: Vec<String>,
    #[serde(default)]
    dependencies: Vec<PathBuf>,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct Key {
    renderer: String,
    directory: PathBuf,
    libraries: Vec<PathBuf>,
    rscript: String,
}

#[derive(Clone, Debug)]
struct Entry {
    schema: Arc<Schema>,
    checked: Instant,
    stamps: Vec<(PathBuf, Option<(SystemTime, u64)>)>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct RendererSchemas {
    documents: HashMap<Url, Vec<String>>,
    entries: HashMap<Key, Entry>,
    pending: Option<Key>,
}

#[derive(Clone, Debug)]
pub(crate) struct Request {
    key: Key,
    previous: Option<Entry>,
}

#[derive(Debug)]
pub(crate) struct Discovery {
    request: Request,
    result: anyhow::Result<Entry>,
}

impl RendererSchemas {
    pub(crate) fn observe(&mut self, uri: Url, document: Option<&Document>) {
        let outputs = document.map(semantic::selected_outputs).unwrap_or_default();
        if outputs.is_empty() {
            self.documents.remove(&uri);
        } else {
            self.documents.insert(uri, outputs);
        }
    }

    pub(crate) fn get<'a>(
        &'a self,
        document: &Document,
        renderer: &str,
        state: &WorldState,
    ) -> Option<&'a Schema> {
        let directory = document.path.as_ref()?.parent()?.to_path_buf();
        let key = key(renderer, directory, state);
        self.entries.get(&key).map(|entry| entry.schema.as_ref())
    }

    pub(crate) fn apply(&mut self, discovery: Discovery) {
        if self.pending.as_ref() != Some(&discovery.request.key) {
            return;
        }
        self.pending = None;
        let entry = discovery.result.unwrap_or_else(|_| Entry {
            schema: Arc::default(),
            checked: Instant::now(),
            stamps: Vec::new(),
        });
        self.entries.insert(discovery.request.key, entry);
    }
}

fn canonical_renderer(renderer: &str) -> String {
    if renderer.contains("::") {
        renderer.to_string()
    } else {
        format!("rmarkdown::{renderer}")
    }
}

fn key(renderer: &str, directory: PathBuf, state: &WorldState) -> Key {
    let directory = state
        .workspace
        .folders
        .iter()
        .filter_map(|uri| uri.to_file_path().ok())
        .filter(|root| directory.starts_with(root))
        .max_by_key(|root| root.components().count())
        .unwrap_or(directory);
    Key {
        renderer: canonical_renderer(renderer),
        directory,
        libraries: state
            .library
            .library_paths
            .iter()
            .take(64)
            .cloned()
            .collect(),
        rscript: std::env::var("ARK_NVIM_RSCRIPT")
            .ok()
            .filter(|path| !path.is_empty())
            .unwrap_or_else(|| String::from("Rscript")),
    }
}

pub(crate) fn prepare(state: &mut WorldState) -> Option<Request> {
    if state.renderer_schemas.pending.is_some() {
        return None;
    }
    let mut desired = HashSet::new();
    for (uri, outputs) in &state.renderer_schemas.documents {
        let Some(directory) = uri
            .to_file_path()
            .ok()
            .and_then(|path| path.parent().map(PathBuf::from))
        else {
            continue;
        };
        for renderer in outputs {
            if desired.len() < MAX_ENTRIES {
                desired.insert(key(renderer, directory.clone(), state));
            }
        }
    }
    let cache = &mut state.renderer_schemas;
    cache.entries.retain(|key, _| desired.contains(key));
    for key in desired {
        let previous = cache.entries.get(&key);
        if previous.is_some_and(|entry| entry.checked.elapsed() < REFRESH_AFTER) {
            continue;
        }
        let request = Request {
            key: key.clone(),
            previous: previous.cloned(),
        };
        cache.pending = Some(key);
        return Some(request);
    }
    None
}

fn stamp(path: &PathBuf) -> Option<(SystemTime, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    Some((metadata.modified().ok()?, metadata.len()))
}

// The guard also reaps ordinary descendants started by package load hooks.
struct ProcessGroup(u32);
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        if let Ok(pid) = i32::try_from(self.0) {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(pid),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
    }
}

impl Request {
    pub(crate) fn is_selected(&self, state: &WorldState) -> bool {
        state
            .renderer_schemas
            .documents
            .iter()
            .any(|(uri, renderers)| {
                let directory = uri
                    .to_file_path()
                    .ok()
                    .and_then(|path| path.parent().map(PathBuf::from));
                directory.is_some_and(|directory| {
                    renderers
                        .iter()
                        .any(|renderer| key(renderer, directory.clone(), state) == self.key)
                })
            })
    }

    pub(crate) fn superseded(self) -> Discovery {
        Discovery {
            request: self,
            result: Err(anyhow!("renderer selection changed")),
        }
    }
}

pub(crate) async fn discover(request: Request) -> Discovery {
    let result = discover_inner(&request).await;
    Discovery { request, result }
}

async fn discover_inner(request: &Request) -> anyhow::Result<Entry> {
    if let Some(previous) = &request.previous {
        if !previous.stamps.is_empty() &&
            previous
                .stamps
                .iter()
                .all(|(path, old)| stamp(path) == *old)
        {
            return Ok(Entry {
                checked: Instant::now(),
                ..previous.clone()
            });
        }
    }
    let renderer = &request.key.renderer;
    let bytes = run_worker(request, Duration::from_secs(10)).await?;
    let mut schema: Schema = serde_json::from_slice(&bytes)?;
    schema.options.truncate(256);
    schema.metadata.truncate(256);
    for header in std::mem::take(&mut schema.headers).into_iter().take(32) {
        add_template_fields(&mut schema, &header, renderer);
    }
    schema.metadata.truncate(256);
    let stamps = schema
        .dependencies
        .iter()
        .take(64)
        .map(|path| (path.clone(), stamp(path)))
        .collect();
    Ok(Entry {
        schema: Arc::new(schema),
        checked: Instant::now(),
        stamps,
    })
}

async fn run_worker(request: &Request, timeout: Duration) -> anyhow::Result<Vec<u8>> {
    let renderer = &request.key.renderer;
    let (package, name) = renderer.split_once("::").unwrap_or(("rmarkdown", renderer));
    let payload =
        serde_json::json!({ "package": package, "name": name, "libraries": request.key.libraries });
    let mut command = tokio::process::Command::new(&request.key.rscript);
    if !request.key.libraries.is_empty() {
        // R must find project-local jsonlite before it can decode the request.
        command.env("R_LIBS", std::env::join_paths(&request.key.libraries)?);
    }
    command
        .args(["--vanilla", "-", &payload.to_string()])
        .current_dir(&request.key.directory)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .process_group(0);
    let mut child = command.spawn()?;
    let _group = child.id().map(ProcessGroup);
    let Some(mut stdin) = child.stdin.take() else {
        return Err(anyhow!("renderer worker has no input"));
    };
    let Some(stdout) = child.stdout.take() else {
        return Err(anyhow!("renderer worker has no output"));
    };
    let exchange = async {
        let write = async {
            stdin.write_all(SCRIPT.as_bytes()).await?;
            drop(stdin);
            Ok::<_, std::io::Error>(())
        };
        let read = async {
            let mut bytes = Vec::new();
            stdout.take(MAX_OUTPUT + 1).read_to_end(&mut bytes).await?;
            if bytes.len() as u64 > MAX_OUTPUT {
                return Err(std::io::Error::other("renderer output budget exceeded"));
            }
            Ok::<_, std::io::Error>(bytes)
        };
        let (_, bytes, status) = tokio::try_join!(write, read, child.wait())?;
        if !status.success() {
            return Err(anyhow!("renderer discovery failed"));
        }
        Ok::<_, anyhow::Error>(bytes)
    };
    tokio::time::timeout(timeout, exchange).await?
}

fn add_template_fields(schema: &mut Schema, header: &str, renderer: &str) {
    let Some(documents) = semantic::load_literal_yaml(header) else {
        return;
    };
    let Some(document) = documents.first() else {
        return;
    };
    if !semantic::yaml_outputs(&document["output"])
        .iter()
        .any(|output| canonical_renderer(output) == canonical_renderer(renderer))
    {
        return;
    }
    fn fields(value: &Yaml, path: &mut Vec<String>, out: &mut Vec<Field>) {
        if path.len() >= 6 || out.len() >= 256 {
            return;
        }
        match value {
            Yaml::Hash(mapping) => {
                for (key, value) in mapping {
                    let Some(key) = key.as_str() else {
                        continue;
                    };
                    if !semantic::identifier(key) || (path.is_empty() && key == "output") {
                        continue;
                    }
                    path.push(key.to_string());
                    out.push(Field {
                        boolean: value.as_bool().is_some() ||
                            matches!(value.as_str(), Some("yes" | "no")),
                        path: path.clone(),
                        choices: if value.as_bool().is_some() ||
                            matches!(value.as_str(), Some("yes" | "no"))
                        {
                            vec![String::from("true"), String::from("false")]
                        } else {
                            Vec::new()
                        },
                    });
                    fields(value, path, out);
                    path.pop();
                }
            },
            Yaml::Array(values) => {
                for value in values.iter().take(16) {
                    fields(value, path, out);
                }
            },
            _ => {},
        }
    }
    fields(document, &mut Vec::new(), &mut schema.metadata);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lsp::document::DocumentKind;

    fn document(renderer: &str) -> Document {
        let mut document = Document::new_with_kind(
            &format!("---\noutput: {renderer}\n---\n"),
            None,
            DocumentKind::LiterateR,
        );
        document.path = Some(PathBuf::from("/tmp/paper.Rmd"));
        document
    }

    #[test]
    fn cache_is_scoped_to_renderer_and_libraries_and_deduplicates_workers() {
        let document = document("example::report");
        let uri = Url::from_file_path(document.path.as_ref().unwrap()).unwrap();
        let mut state = WorldState::default();
        state.renderer_schemas.observe(uri.clone(), Some(&document));
        let request = prepare(&mut state).unwrap();
        assert!(prepare(&mut state).is_none());
        state.renderer_schemas.apply(Discovery {
            request,
            result: Ok(Entry {
                schema: Arc::new(Schema::default()),
                checked: Instant::now(),
                stamps: vec![],
            }),
        });
        assert!(state
            .renderer_schemas
            .get(&document, "example::report", &state)
            .is_some());
        assert!(state
            .renderer_schemas
            .get(&document, "example::other", &state)
            .is_none());
        assert!(prepare(&mut state).is_none());
        state
            .workspace
            .folders
            .push(Url::from_directory_path("/tmp").unwrap());
        let mut sibling = document.clone();
        sibling.path = Some(PathBuf::from("/tmp/chapters/other.Rmd"));
        assert!(state
            .renderer_schemas
            .get(&sibling, "example::report", &state)
            .is_some());
        state.library =
            oak_semantic::library::Library::new(vec![PathBuf::from("/another-library")]);
        assert!(state
            .renderer_schemas
            .get(&document, "example::report", &state)
            .is_none());
        assert!(prepare(&mut state).is_some());
        state.renderer_schemas.observe(uri, None);
    }

    #[test]
    fn templates_match_selected_renderer_and_preserve_nested_boolean_fields() {
        let mut schema = Schema::default();
        let header = "---\noutput: example::report\nshorttitle: Example\nauthor:\n  - corresponding: true\n---\n";
        add_template_fields(&mut schema, header, "example::other");
        assert!(schema.metadata.is_empty());
        add_template_fields(&mut schema, header, "example::report");
        assert!(schema
            .metadata
            .iter()
            .any(|field| field.path == ["shorttitle"]));
        let field = schema
            .metadata
            .iter()
            .find(|field| field.path == ["author", "corresponding"])
            .unwrap();
        assert_eq!(field.choices, ["true", "false"]);
        assert!(!schema.metadata.iter().any(|field| field.path == ["output"]));
        let before = schema.metadata.len();
        add_template_fields(
            &mut schema,
            "output: example::report\nx: &anchor [1, 2]\ny: *anchor",
            "example::report",
        );
        assert_eq!(schema.metadata.len(), before);
    }

    #[tokio::test]
    async fn unchanged_dependencies_reuse_cached_schema_without_starting_r() {
        let dependency = tempfile::NamedTempFile::new().unwrap();
        let path = dependency.path().to_path_buf();
        let previous = Entry {
            schema: Arc::new(Schema::default()),
            checked: Instant::now() - REFRESH_AFTER,
            stamps: vec![(path.clone(), stamp(&path))],
        };
        let request = Request {
            key: Key {
                renderer: String::from("example::report"),
                directory: PathBuf::from("/tmp"),
                libraries: vec![],
                rscript: String::from("/does/not/exist/Rscript"),
            },
            previous: Some(previous.clone()),
        };
        let result = discover_inner(&request).await.unwrap();
        assert!(Arc::ptr_eq(&result.schema, &previous.schema));
        std::fs::write(&path, "new package version").unwrap();
        assert!(discover_inner(&request).await.is_err());
    }
    fn worker_fixture(body: &str) -> (tempfile::TempDir, Request) {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let worker = directory.path().join("Rscript");
        std::fs::write(&worker, format!("#!/bin/sh\ncat >/dev/null\n{body}\n")).unwrap();
        std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
        let request = Request {
            key: Key {
                renderer: String::from("example::report"),
                directory: directory.path().to_path_buf(),
                libraries: vec![],
                rscript: worker.to_string_lossy().into_owned(),
            },
            previous: None,
        };
        (directory, request)
    }

    #[tokio::test]
    async fn worker_timeout_terminates_pipe_holding_descendants() {
        let (directory, request) =
            worker_fixture("(while true; do echo tick >> heartbeat; sleep 0.01; done) &\nwait");
        let started = Instant::now();
        assert!(run_worker(&request, Duration::from_millis(150))
            .await
            .is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
        tokio::time::sleep(Duration::from_millis(100)).await;
        let heartbeat = directory.path().join("heartbeat");
        let stopped = std::fs::read(&heartbeat).unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(std::fs::read(heartbeat).unwrap(), stopped);
    }

    #[tokio::test]
    async fn worker_output_is_bounded_before_json_loading() {
        let (_directory, request) = worker_fixture("head -c 1100000 /dev/zero");
        let error = run_worker(&request, Duration::from_secs(2))
            .await
            .unwrap_err();
        assert!(
            error.to_string().contains("output budget exceeded"),
            "{error}"
        );
    }
    #[tokio::test]
    async fn worker_receives_library_context_before_loading_request_parser() {
        let (_directory, mut request) = worker_fixture("printf '%s' \"$R_LIBS\"");
        request.key.libraries = vec![PathBuf::from("/project library"), PathBuf::from("/other")];
        let output = run_worker(&request, Duration::from_secs(2)).await.unwrap();
        assert_eq!(
            String::from_utf8(output).unwrap(),
            "/project library:/other"
        );
    }
}
