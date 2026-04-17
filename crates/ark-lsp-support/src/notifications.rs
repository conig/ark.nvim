//
// notifications.rs
//
// Copyright (C) 2024 Posit Software, PBC. All rights reserved.
//
//

#[derive(Debug)]
pub struct ConsoleInputs {
    /// List of console scopes, from innermost (global or debug) to outermost
    /// scope. Currently the scopes are vectors of symbol names. TODO: In the
    /// future, we should send structural information like search path, and let
    /// the LSP query us for the contents so that the LSP can cache the
    /// information.
    pub console_scopes: Vec<Vec<String>>,

    /// Packages currently installed in the library path. TODO: Should send
    /// library paths instead and inspect and cache package information in the LSP.
    pub installed_packages: Vec<String>,
}

#[derive(Debug)]
pub struct DidOpenVirtualDocumentParams {
    pub uri: String,
    pub contents: String,
}

#[derive(Debug)]
pub struct DidCloseVirtualDocumentParams {
    pub uri: String,
}

#[derive(Debug)]
#[allow(clippy::enum_variant_names)]
pub enum KernelNotification {
    DidChangeConsoleInputs(ConsoleInputs),
    DidOpenVirtualDocument(DidOpenVirtualDocumentParams),
    DidCloseVirtualDocument(DidCloseVirtualDocumentParams),
}

/// A thin wrapper struct with a custom `Debug` method more appropriate for trace logs.
pub struct TraceKernelNotification<'a> {
    inner: &'a KernelNotification,
}

impl KernelNotification {
    pub fn trace(&self) -> TraceKernelNotification<'_> {
        TraceKernelNotification { inner: self }
    }
}

impl std::fmt::Debug for TraceKernelNotification<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.inner {
            KernelNotification::DidChangeConsoleInputs(_) => f.write_str("DidChangeConsoleInputs"),
            KernelNotification::DidOpenVirtualDocument(params) => f
                .debug_struct("DidOpenVirtualDocument")
                .field("uri", &params.uri)
                .field("contents", &"<snip>")
                .finish(),
            KernelNotification::DidCloseVirtualDocument(params) => f
                .debug_struct("DidCloseVirtualDocument")
                .field("uri", &params.uri)
                .finish(),
        }
    }
}
