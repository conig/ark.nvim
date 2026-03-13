use std::collections::HashMap;
use std::env;
use std::path::Path;

use anyhow::anyhow;
use stdext::result::ResultExt;
use url::Url;

use crate::lsp::config::LspConfig;
use crate::lsp::document::Document;
use crate::lsp::document::DocumentKind;
use crate::lsp::inputs::library::Library;
use crate::lsp::inputs::source_root::SourceRoot;
use crate::lsp::session_bridge::SessionBridge;
use crate::lsp::session_bridge::SessionBridgeConfig;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum RuntimeMode {
    #[default]
    Attached,
    Detached,
}

#[derive(Clone, Debug)]
/// The world state, i.e. all the inputs necessary for analysing or refactoring
/// code. This is a pure value. There is no interior mutability in this data
/// structure. It can be cloned and safely sent to other threads.
pub(crate) struct WorldState {
    /// Watched documents
    pub(crate) documents: HashMap<Url, Document>,

    /// Watched folders
    pub(crate) workspace: Workspace,

    /// Virtual documents that the LSP serves as a text document content provider for
    /// Maps a `String` uri to the contents of the document
    pub(crate) virtual_documents: HashMap<String, String>,

    /// The scopes for the console. This currently contains a list (outer `Vec`)
    /// of names (inner `Vec`) within the environments on the search path, starting
    /// from the global environment and ending with the base package. Eventually
    /// this might also be populated with the scope for the current environment
    /// in debug sessions (not implemented yet).
    ///
    /// This is currently one of the main sources of known symbols for
    /// diagnostics. In the future we should better delineate interactive
    /// contexts (e.g. the console, but scripts might also be treated as
    /// interactive, which could be a user setting) and non-interactive ones
    /// (e.g. a package). In non-interactive contexts, the lexical scopes
    /// examined for diagnostics should be fully determined by variable bindings
    /// and imports (code-first diagnostics).
    ///
    /// In the future this should probably become more complex with a list of
    /// either symbol names (as is now the case) or named environments, such as
    /// `pkg:ggplot2`. Storing named environments here will allow the LSP to
    /// retrieve the symbols in a pull fashion (the whole console scopes are
    /// currently pushed to the LSP), and cache the symbols with Salsa. The
    /// performance is not currently an issue but this could change once we do
    /// more analysis of symbols in the search path.
    pub(crate) console_scopes: Vec<Vec<String>>,

    /// Currently installed packages
    pub(crate) installed_packages: Vec<String>,

    /// The root of the source tree (e.g., a package).
    pub(crate) root: Option<SourceRoot>,

    /// Map of package name to package metadata for installed libraries. Lazily populated.
    pub(crate) library: Library,

    pub(crate) config: LspConfig,

    pub(crate) runtime_mode: RuntimeMode,

    pub(crate) session_bridge: Option<SessionBridge>,
}

#[derive(Clone, Default, Debug)]
pub(crate) struct Workspace {
    pub folders: Vec<Url>,
}

impl WorldState {
    pub(crate) fn detached() -> Self {
        Self {
            runtime_mode: RuntimeMode::Detached,
            session_bridge: session_bridge_from_env().log_err().flatten(),
            ..Self::default()
        }
    }

    pub(crate) fn get_document(&self, uri: &Url) -> anyhow::Result<&Document> {
        if let Some(doc) = self.documents.get(uri) {
            Ok(doc)
        } else {
            Err(anyhow!("Can't find document for URI {uri}"))
        }
    }

    pub(crate) fn get_document_mut(&mut self, uri: &Url) -> anyhow::Result<&mut Document> {
        if let Some(doc) = self.documents.get_mut(uri) {
            Ok(doc)
        } else {
            Err(anyhow!("Can't find document for URI {uri}"))
        }
    }

    pub(crate) fn has_attached_runtime(&self) -> bool {
        self.runtime_mode == RuntimeMode::Attached
    }
}

impl Default for WorldState {
    fn default() -> Self {
        Self {
            documents: HashMap::new(),
            workspace: Workspace::default(),
            virtual_documents: HashMap::new(),
            console_scopes: Vec::new(),
            installed_packages: Vec::new(),
            root: None,
            library: Library::default(),
            config: LspConfig::default(),
            runtime_mode: RuntimeMode::Attached,
            session_bridge: None,
        }
    }
}

fn session_bridge_from_env() -> anyhow::Result<Option<SessionBridge>> {
    let Ok(kind) = env::var("ARK_SESSION_KIND") else {
        return Ok(None);
    };

    if kind != "ark" && kind != "rscope" {
        return Err(anyhow!("unsupported session bridge kind: {kind}"));
    }

    let host = env::var("ARK_SESSION_HOST").unwrap_or_else(|_| String::from("127.0.0.1"));
    let port = env::var("ARK_SESSION_PORT")
        .map_err(|_| anyhow!("ARK_SESSION_PORT is required for session bridge"))?
        .parse::<u16>()?;
    let auth_token = env::var("ARK_SESSION_AUTH_TOKEN").unwrap_or_default();
    let tmux_socket = env::var("ARK_SESSION_TMUX_SOCKET").unwrap_or_default();
    let tmux_session = env::var("ARK_SESSION_TMUX_SESSION").unwrap_or_default();
    let tmux_pane = env::var("ARK_SESSION_TMUX_PANE").unwrap_or_default();
    let timeout_ms = env::var("ARK_SESSION_TIMEOUT_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(1000);

    let bridge = SessionBridge::new(SessionBridgeConfig {
        host,
        port,
        auth_token,
        tmux_socket,
        tmux_session,
        tmux_pane,
        timeout_ms,
    })?;

    Ok(Some(bridge))
}

pub(crate) fn with_document<T, F>(
    path: &Path,
    state: &WorldState,
    mut callback: F,
) -> anyhow::Result<T>
where
    F: FnMut(&Document) -> anyhow::Result<T>,
{
    let mut fallback = || {
        let contents = std::fs::read_to_string(path)?;
        let document =
            Document::new_with_kind(contents.as_str(), None, DocumentKind::from_path(path));
        callback(&document)
    };

    // If we have a cached copy of the document (because we're monitoring it)
    // then use that; otherwise, try to read the document from the provided
    // path and use that instead.
    let Ok(uri) = Url::from_file_path(path) else {
        log::info!(
            "couldn't construct uri from {}; reading from disk instead",
            path.display()
        );
        return fallback();
    };

    let Ok(document) = state.get_document(&uri) else {
        log::info!("no document for uri {uri}; reading from disk instead");
        return fallback();
    };

    callback(document)
}

pub(crate) fn workspace_uris(state: &WorldState) -> Vec<Url> {
    let uris: Vec<Url> = state.documents.iter().map(|elt| elt.0.clone()).collect();
    uris
}
