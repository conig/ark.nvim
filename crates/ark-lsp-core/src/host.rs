use aether_path::FilePath;

/// Notification emitted by the shared LSP loop for an optional host frontend.
///
/// Detached stdio servers intentionally drop these notifications. The retained
/// upstream `ark` host consumes them to keep its attached console in sync.
#[derive(Debug)]
pub enum HostNotification {
    DidChangeDocument(FilePath),
}
