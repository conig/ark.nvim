//
// backend.rs
//
// Copyright (C) 2022-2026 Posit Software, PBC. All rights reserved.
//
//

#![allow(deprecated)]

use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use serde_json::Value;
use tokio::sync::mpsc::unbounded_channel as tokio_unbounded_channel;
use tokio::sync::Notify;
use tower_lsp::jsonrpc;
use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::request::GotoImplementationParams;
use tower_lsp::lsp_types::request::GotoImplementationResponse;
use tower_lsp::lsp_types::FoldingRange;
use tower_lsp::lsp_types::SelectionRange;
use tower_lsp::lsp_types::*;
use tower_lsp::Client;
use tower_lsp::LanguageServer;
use tower_lsp::LspService;
use tower_lsp::Server;

use super::main_loop::LSP_HAS_CRASHED;
use crate::console::ConsoleNotification;
use crate::lsp::handlers::HelpTextParams;
use crate::lsp::handlers::SessionBootstrapResponse;
use crate::lsp::handlers::SessionUpdateParams;
use crate::lsp::handlers::StatusParams;
use crate::lsp::handlers::ViewCellParams;
use crate::lsp::handlers::ViewExportParams;
use crate::lsp::handlers::ViewFilterParams;
use crate::lsp::handlers::ViewOpenParams;
use crate::lsp::handlers::ViewPageParams;
use crate::lsp::handlers::ViewProfileParams;
use crate::lsp::handlers::ViewRpcRequest;
use crate::lsp::handlers::ViewSchemaSearchParams;
use crate::lsp::handlers::ViewSessionParams;
use crate::lsp::handlers::ViewSortParams;
use crate::lsp::handlers::VirtualDocumentParams;
use crate::lsp::handlers::VirtualDocumentResponse;
use crate::lsp::handlers::ARK_HELP_TEXT_REQUEST;
use crate::lsp::handlers::ARK_SESSION_BOOTSTRAP_REQUEST;
use crate::lsp::handlers::ARK_SESSION_UPDATE_NOTIFICATION;
use crate::lsp::handlers::ARK_STATUS_REQUEST;
use crate::lsp::handlers::ARK_VDOC_REQUEST;
use crate::lsp::handlers::ARK_VIEW_CELL_REQUEST;
use crate::lsp::handlers::ARK_VIEW_CLOSE_REQUEST;
use crate::lsp::handlers::ARK_VIEW_CODE_REQUEST;
use crate::lsp::handlers::ARK_VIEW_EXPORT_REQUEST;
use crate::lsp::handlers::ARK_VIEW_FILTER_REQUEST;
use crate::lsp::handlers::ARK_VIEW_OPEN_REQUEST;
use crate::lsp::handlers::ARK_VIEW_PAGE_REQUEST;
use crate::lsp::handlers::ARK_VIEW_PROFILE_REQUEST;
use crate::lsp::handlers::ARK_VIEW_SCHEMA_SEARCH_REQUEST;
use crate::lsp::handlers::ARK_VIEW_SORT_REQUEST;
use crate::lsp::handlers::ARK_VIEW_STATE_REQUEST;
use crate::lsp::help_topic;
use crate::lsp::help_topic::HelpTopicParams;
use crate::lsp::help_topic::HelpTopicResponse;
use crate::lsp::input_boundaries;
use crate::lsp::input_boundaries::InputBoundariesParams;
use crate::lsp::input_boundaries::InputBoundariesResponse;
use crate::lsp::main_loop::Event;
use crate::lsp::main_loop::GlobalState;
use crate::lsp::main_loop::TokioUnboundedSender;
use crate::lsp::session_bridge::HelpPage;
use crate::lsp::state::RuntimeMode;
use crate::lsp::statement_range;
use crate::lsp::statement_range::StatementRangeParams;
use crate::lsp::statement_range::StatementRangeResponse;

// This enum is useful for two things. First it allows us to distinguish a
// normal request failure from a crash. In the latter case we send a
// notification to the client so the user knows the LSP has crashed.
//
// Once the LSP has crashed all requests respond with an error. This prevents
// any handler from running while we process the message to shut down the
// server. The `Disabled` enum variant is an indicator of this state. We could
// have just created an anyhow error passed through the `Result` variant but that
// would flood the LSP logs with irrelevant backtraces.
#[expect(clippy::large_enum_variant)]
pub(crate) enum RequestResponse {
    Disabled,
    Crashed(anyhow::Error),
    Result(LspResult<LspResponse>),
}

// Based on https://stackoverflow.com/a/69324393/1725177
macro_rules! cast_response {
    ($self:expr, $target:expr, $pat:path) => {{
        match $target {
            RequestResponse::Result(Ok($pat(resp))) => Ok(resp),
            RequestResponse::Result(Ok(_)) => {
                let message = format!("Unexpected variant while casting to {}", stringify!($pat));
                log::error!("{message}");
                Err(new_jsonrpc_error(message))
            },
            RequestResponse::Result(Err(err)) => match err {
                LspError::JsonRpc(err) => Err(err),
                LspError::Anyhow(err) => Err(new_jsonrpc_error(format!("{err:?}"))),
            },
            RequestResponse::Crashed(err) => {
                // Notify user that the LSP has crashed and is no longer active
                report_crash();

                // The backtrace is reported via `err` and eventually shows up
                // in the LSP logs on the client side
                let _ = $self.shutdown_tx.send(()).await;
                Err(new_jsonrpc_error(format!("{err:?}")))
            },
            RequestResponse::Disabled => Err(new_jsonrpc_error(String::from(
                "The LSP server has crashed and is now shut down!",
            ))),
        }
    }};
}

fn report_crash() {
    log::error!(
        "The R language server has crashed and has been disabled. Please report this crash to https://github.com/conig/ark.nvim/issues with full logs from the current Neovim session."
    );
}

#[derive(Debug)]
#[expect(clippy::large_enum_variant)]
pub(crate) enum LspMessage {
    Notification(u64, LspNotification),
    Request(LspRequest, TokioUnboundedSender<RequestResponse>),
}

#[derive(Debug)]
pub(crate) enum LspNotification {
    Initialized(InitializedParams),
    SessionUpdate(SessionUpdateParams),
    DidChangeWorkspaceFolders(DidChangeWorkspaceFoldersParams),
    DidChangeConfiguration(DidChangeConfigurationParams),
    DidChangeWatchedFiles(DidChangeWatchedFilesParams),
    DidOpenTextDocument(DidOpenTextDocumentParams),
    DidChangeTextDocument(DidChangeTextDocumentParams),
    DidSaveTextDocument(DidSaveTextDocumentParams),
    DidCloseTextDocument(DidCloseTextDocumentParams),
    DidCreateFiles(CreateFilesParams),
    DidDeleteFiles(DeleteFilesParams),
    DidRenameFiles(RenameFilesParams),
}

#[derive(Debug)]
#[expect(clippy::large_enum_variant)]
pub(crate) enum LspRequest {
    Initialize(InitializeParams),
    WorkspaceSymbol(WorkspaceSymbolParams),
    DocumentSymbol(DocumentSymbolParams),
    FoldingRange(FoldingRangeParams),
    ExecuteCommand(ExecuteCommandParams),
    Completion(CompletionParams),
    CompletionResolve(CompletionItem),
    Hover(HoverParams),
    SignatureHelp(SignatureHelpParams),
    GotoDefinition(GotoDefinitionParams),
    GotoImplementation(GotoImplementationParams),
    SelectionRange(SelectionRangeParams),
    References(ReferenceParams),
    StatementRange(StatementRangeParams),
    HelpTopic(HelpTopicParams),
    OnTypeFormatting(DocumentOnTypeFormattingParams),
    CodeAction(CodeActionParams),
    VirtualDocument(VirtualDocumentParams),
    Status(StatusParams),
    HelpText(HelpTextParams),
    InputBoundaries(InputBoundariesParams),
    SessionBootstrap(SessionUpdateParams),
    ViewRpc(ViewRpcRequest),
}

#[derive(Debug)]
#[expect(clippy::large_enum_variant)]
pub(crate) enum LspResponse {
    Initialize(InitializeResult),
    WorkspaceSymbol(Option<Vec<SymbolInformation>>),
    DocumentSymbol(Option<DocumentSymbolResponse>),
    FoldingRange(Option<Vec<FoldingRange>>),
    ExecuteCommand(Option<Value>),
    Completion(Option<CompletionResponse>),
    CompletionResolve(CompletionItem),
    Hover(Option<Hover>),
    SignatureHelp(Option<SignatureHelp>),
    GotoDefinition(Option<GotoDefinitionResponse>),
    GotoImplementation(Option<GotoImplementationResponse>),
    SelectionRange(Option<Vec<SelectionRange>>),
    References(Option<Vec<Location>>),
    StatementRange(Option<StatementRangeResponse>),
    HelpTopic(Option<HelpTopicResponse>),
    OnTypeFormatting(Option<Vec<TextEdit>>),
    CodeAction(Option<CodeActionResponse>),
    VirtualDocument(VirtualDocumentResponse),
    Status(Value),
    HelpText(Option<HelpPage>),
    InputBoundaries(InputBoundariesResponse),
    SessionBootstrap(SessionBootstrapResponse),
    ViewRpc(Value),
}

pub(crate) type LspResult<T> = std::result::Result<T, LspError>;

#[derive(Debug)]
pub(crate) enum LspError {
    JsonRpc(jsonrpc::Error),
    Anyhow(anyhow::Error),
}

impl std::error::Error for LspError {}

impl std::fmt::Display for LspError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LspError::JsonRpc(error) => write!(f, "{error:?}"),
            LspError::Anyhow(error) => write!(f, "{error:?}"),
        }
    }
}

// For the ability to `?` a `jsonrpc::Error` into an `LspError`
impl From<jsonrpc::Error> for LspError {
    fn from(error: jsonrpc::Error) -> Self {
        Self::JsonRpc(error)
    }
}

// For the ability to `?` an `anyhow::Error` into an `LspError`
impl From<anyhow::Error> for LspError {
    fn from(error: anyhow::Error) -> Self {
        Self::Anyhow(error)
    }
}

#[derive(Debug)]
struct Backend {
    /// Shutdown notifier used to unwind tower-lsp and disconnect from the
    /// client when an LSP handler panics.
    shutdown_tx: tokio::sync::mpsc::Sender<()>,

    /// Channel for communication with the main loop.
    events_tx: TokioUnboundedSender<Event>,

    /// Ensures requests see the effects of earlier notifications.
    notification_barrier: Arc<NotificationBarrier>,

    /// Handle to main loop. Drop it to cancel the loop, all associated tasks,
    /// and drop all owned state.
    _main_loop: tokio::task::JoinSet<()>,
}

#[derive(Debug, Default)]
pub(crate) struct NotificationBarrier {
    queued: AtomicU64,
    processed: AtomicU64,
    wake: Notify,
}

impl NotificationBarrier {
    fn enqueue(&self) -> u64 {
        self.queued.fetch_add(1, Ordering::AcqRel) + 1
    }

    fn queued(&self) -> u64 {
        self.queued.load(Ordering::Acquire)
    }

    pub(crate) async fn wait_for(&self, target: u64) {
        while self.processed.load(Ordering::Acquire) < target {
            self.wake.notified().await;
        }
    }

    pub(crate) fn mark_processed(&self, sequence: u64) {
        self.processed.store(sequence, Ordering::Release);
        self.wake.notify_waiters();
    }
}

impl Backend {
    fn parse_session_update_params(params: Value) -> Option<SessionUpdateParams> {
        match params {
            Value::Object(_) => serde_json::from_value(params).ok(),
            Value::Array(mut values) if values.len() == 1 => {
                serde_json::from_value(values.remove(0)).ok()
            },
            _ => None,
        }
    }

    async fn request(&self, request: LspRequest) -> RequestResponse {
        if LSP_HAS_CRASHED.load(Ordering::Acquire) {
            return RequestResponse::Disabled;
        }

        self.notification_barrier
            .wait_for(self.notification_barrier.queued())
            .await;

        let (response_tx, mut response_rx) = tokio_unbounded_channel::<RequestResponse>();

        // Relay request to main loop
        self.events_tx
            .send(Event::Lsp(LspMessage::Request(request, response_tx)))
            .unwrap();

        // Wait for response from main loop
        response_rx.recv().await.unwrap()
    }

    fn notify(&self, notif: LspNotification) {
        let sequence = self.notification_barrier.enqueue();

        // Relay notification to main loop
        self.events_tx
            .send(Event::Lsp(LspMessage::Notification(sequence, notif)))
            .unwrap();
    }
}

#[tower_lsp::async_trait]
impl LanguageServer for Backend {
    async fn initialize(&self, params: InitializeParams) -> Result<InitializeResult> {
        cast_response!(
            self,
            self.request(LspRequest::Initialize(params)).await,
            LspResponse::Initialize
        )
    }

    async fn initialized(&self, params: InitializedParams) {
        self.notify(LspNotification::Initialized(params));
    }

    async fn shutdown(&self) -> Result<()> {
        // Don't go through the main loop because we want this request to
        // succeed even when the LSP has crashed and has been disabled.
        Ok(())
    }

    async fn did_change_workspace_folders(&self, params: DidChangeWorkspaceFoldersParams) {
        self.notify(LspNotification::DidChangeWorkspaceFolders(params));
    }

    async fn did_change_configuration(&self, params: DidChangeConfigurationParams) {
        self.notify(LspNotification::DidChangeConfiguration(params));
    }

    async fn did_change_watched_files(&self, params: DidChangeWatchedFilesParams) {
        self.notify(LspNotification::DidChangeWatchedFiles(params));
    }

    async fn did_create_files(&self, params: CreateFilesParams) {
        self.notify(LspNotification::DidCreateFiles(params));
    }

    async fn did_delete_files(&self, params: DeleteFilesParams) {
        self.notify(LspNotification::DidDeleteFiles(params));
    }

    async fn did_rename_files(&self, params: RenameFilesParams) {
        self.notify(LspNotification::DidRenameFiles(params));
    }

    async fn symbol(
        &self,
        params: WorkspaceSymbolParams,
    ) -> Result<Option<Vec<SymbolInformation>>> {
        cast_response!(
            self,
            self.request(LspRequest::WorkspaceSymbol(params)).await,
            LspResponse::WorkspaceSymbol
        )
    }

    async fn document_symbol(
        &self,
        params: DocumentSymbolParams,
    ) -> Result<Option<DocumentSymbolResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::DocumentSymbol(params)).await,
            LspResponse::DocumentSymbol
        )
    }

    async fn folding_range(&self, params: FoldingRangeParams) -> Result<Option<Vec<FoldingRange>>> {
        cast_response!(
            self,
            self.request(LspRequest::FoldingRange(params)).await,
            LspResponse::FoldingRange
        )
    }

    async fn execute_command(
        &self,
        params: ExecuteCommandParams,
    ) -> jsonrpc::Result<Option<Value>> {
        cast_response!(
            self,
            self.request(LspRequest::ExecuteCommand(params)).await,
            LspResponse::ExecuteCommand
        )
    }

    async fn did_open(&self, params: DidOpenTextDocumentParams) {
        self.notify(LspNotification::DidOpenTextDocument(params));
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        self.notify(LspNotification::DidChangeTextDocument(params));
    }

    async fn did_save(&self, params: DidSaveTextDocumentParams) {
        self.notify(LspNotification::DidSaveTextDocument(params));
    }

    async fn did_close(&self, params: DidCloseTextDocumentParams) {
        self.notify(LspNotification::DidCloseTextDocument(params));
    }

    async fn completion(&self, params: CompletionParams) -> Result<Option<CompletionResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::Completion(params)).await,
            LspResponse::Completion
        )
    }

    async fn completion_resolve(&self, item: CompletionItem) -> Result<CompletionItem> {
        cast_response!(
            self,
            self.request(LspRequest::CompletionResolve(item)).await,
            LspResponse::CompletionResolve
        )
    }

    async fn hover(&self, params: HoverParams) -> Result<Option<Hover>> {
        cast_response!(
            self,
            self.request(LspRequest::Hover(params)).await,
            LspResponse::Hover
        )
    }

    async fn signature_help(&self, params: SignatureHelpParams) -> Result<Option<SignatureHelp>> {
        cast_response!(
            self,
            self.request(LspRequest::SignatureHelp(params)).await,
            LspResponse::SignatureHelp
        )
    }

    async fn goto_definition(
        &self,
        params: GotoDefinitionParams,
    ) -> Result<Option<GotoDefinitionResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::GotoDefinition(params)).await,
            LspResponse::GotoDefinition
        )
    }

    async fn goto_implementation(
        &self,
        params: GotoImplementationParams,
    ) -> Result<Option<GotoImplementationResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::GotoImplementation(params)).await,
            LspResponse::GotoImplementation
        )
    }

    async fn selection_range(
        &self,
        params: SelectionRangeParams,
    ) -> Result<Option<Vec<SelectionRange>>> {
        cast_response!(
            self,
            self.request(LspRequest::SelectionRange(params)).await,
            LspResponse::SelectionRange
        )
    }

    async fn references(&self, params: ReferenceParams) -> Result<Option<Vec<Location>>> {
        cast_response!(
            self,
            self.request(LspRequest::References(params)).await,
            LspResponse::References
        )
    }

    async fn on_type_formatting(
        &self,
        params: DocumentOnTypeFormattingParams,
    ) -> Result<Option<Vec<TextEdit>>> {
        cast_response!(
            self,
            self.request(LspRequest::OnTypeFormatting(params)).await,
            LspResponse::OnTypeFormatting
        )
    }

    async fn code_action(&self, params: CodeActionParams) -> Result<Option<CodeActionResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::CodeAction(params)).await,
            LspResponse::CodeAction
        )
    }
}

// Custom methods for the backend.
//
// NOTE: Request / notification methods _must_ accept a params object,
// even for notifications that don't include any auxiliary data.
//
// I'm not positive, but I think this is related to the way VSCode
// serializes parameters for notifications / requests when no data
// is supplied. Instead of supplying "nothing", it supplies something
// like `[null]` which tower_lsp seems to quietly reject when attempting
// to invoke the registered method.
//
// See also:
//
// https://github.com/Microsoft/vscode-languageserver-node/blob/18fad46b0e8085bb72e1b76f9ea23a379569231a/client/src/common/client.ts#L802-L838
// https://github.com/Microsoft/vscode-languageserver-node/blob/18fad46b0e8085bb72e1b76f9ea23a379569231a/client/src/common/client.ts#L701-L752
impl Backend {
    async fn statement_range(
        &self,
        params: StatementRangeParams,
    ) -> jsonrpc::Result<Option<StatementRangeResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::StatementRange(params)).await,
            LspResponse::StatementRange
        )
    }

    async fn help_topic(
        &self,
        params: HelpTopicParams,
    ) -> jsonrpc::Result<Option<HelpTopicResponse>> {
        cast_response!(
            self,
            self.request(LspRequest::HelpTopic(params)).await,
            LspResponse::HelpTopic
        )
    }

    async fn virtual_document(
        &self,
        params: VirtualDocumentParams,
    ) -> tower_lsp::jsonrpc::Result<VirtualDocumentResponse> {
        cast_response!(
            self,
            self.request(LspRequest::VirtualDocument(params)).await,
            LspResponse::VirtualDocument
        )
    }

    async fn status(&self, params: StatusParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::Status(params)).await,
            LspResponse::Status
        )
    }

    async fn help_text(
        &self,
        params: HelpTextParams,
    ) -> tower_lsp::jsonrpc::Result<Option<HelpPage>> {
        cast_response!(
            self,
            self.request(LspRequest::HelpText(params)).await,
            LspResponse::HelpText
        )
    }

    async fn input_boundaries(
        &self,
        params: InputBoundariesParams,
    ) -> tower_lsp::jsonrpc::Result<InputBoundariesResponse> {
        cast_response!(
            self,
            self.request(LspRequest::InputBoundaries(params)).await,
            LspResponse::InputBoundaries
        )
    }

    async fn bootstrap_session(
        &self,
        params: SessionUpdateParams,
    ) -> tower_lsp::jsonrpc::Result<SessionBootstrapResponse> {
        cast_response!(
            self,
            self.request(LspRequest::SessionBootstrap(params)).await,
            LspResponse::SessionBootstrap
        )
    }

    async fn view_open(&self, params: ViewOpenParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Open(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_state(&self, params: ViewSessionParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::State(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_page(&self, params: ViewPageParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Page(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_sort(&self, params: ViewSortParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Sort(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_filter(&self, params: ViewFilterParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Filter(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_schema_search(
        &self,
        params: ViewSchemaSearchParams,
    ) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::SchemaSearch(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_profile(&self, params: ViewProfileParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Profile(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_code(&self, params: ViewSessionParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Code(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_export(&self, params: ViewExportParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Export(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_cell(&self, params: ViewCellParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Cell(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn view_close(&self, params: ViewSessionParams) -> tower_lsp::jsonrpc::Result<Value> {
        cast_response!(
            self,
            self.request(LspRequest::ViewRpc(ViewRpcRequest::Close(params)))
                .await,
            LspResponse::ViewRpc
        )
    }

    async fn notification(&self, params: Option<Value>) {
        log::info!("Received legacy ark/notification payload: {:?}", params);
    }

    async fn update_session(&self, params: Value) {
        let Some(params) = Self::parse_session_update_params(params) else {
            log::warn!("Ignoring malformed ark/updateSession notification");
            return;
        };

        self.notify(LspNotification::SessionUpdate(params));
    }
}

pub async fn start_stdio_lsp(runtime_mode: RuntimeMode) -> anyhow::Result<()> {
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();
    let (shutdown_tx, mut shutdown_rx) = tokio::sync::mpsc::channel::<()>(1);
    let (console_notification_tx, _console_notification_rx) =
        tokio_unbounded_channel::<ConsoleNotification>();

    let init = move |client: Client| {
        let notification_barrier = Arc::new(NotificationBarrier::default());
        let state = GlobalState::new_with_runtime_mode(
            client,
            console_notification_tx.clone(),
            runtime_mode,
            notification_barrier.clone(),
        );
        let events_tx = state.events_tx();
        let main_loop = state.start();

        Backend {
            shutdown_tx,
            events_tx,
            notification_barrier,
            _main_loop: main_loop,
        }
    };

    let (service, socket) = LspService::build(init)
        .custom_method(ARK_SESSION_UPDATE_NOTIFICATION, Backend::update_session)
        .custom_method(
            statement_range::ARK_STATEMENT_RANGE_REQUEST,
            Backend::statement_range,
        )
        .custom_method(help_topic::ARK_HELP_TOPIC_REQUEST, Backend::help_topic)
        .custom_method(ARK_VDOC_REQUEST, Backend::virtual_document)
        .custom_method(ARK_STATUS_REQUEST, Backend::status)
        .custom_method(ARK_HELP_TEXT_REQUEST, Backend::help_text)
        .custom_method(ARK_SESSION_BOOTSTRAP_REQUEST, Backend::bootstrap_session)
        .custom_method(ARK_VIEW_OPEN_REQUEST, Backend::view_open)
        .custom_method(ARK_VIEW_STATE_REQUEST, Backend::view_state)
        .custom_method(ARK_VIEW_PAGE_REQUEST, Backend::view_page)
        .custom_method(ARK_VIEW_SORT_REQUEST, Backend::view_sort)
        .custom_method(ARK_VIEW_FILTER_REQUEST, Backend::view_filter)
        .custom_method(ARK_VIEW_SCHEMA_SEARCH_REQUEST, Backend::view_schema_search)
        .custom_method(ARK_VIEW_PROFILE_REQUEST, Backend::view_profile)
        .custom_method(ARK_VIEW_CODE_REQUEST, Backend::view_code)
        .custom_method(ARK_VIEW_EXPORT_REQUEST, Backend::view_export)
        .custom_method(ARK_VIEW_CELL_REQUEST, Backend::view_cell)
        .custom_method(ARK_VIEW_CLOSE_REQUEST, Backend::view_close)
        .custom_method(
            input_boundaries::ARK_INPUT_BOUNDARIES_REQUEST,
            Backend::input_boundaries,
        )
        .custom_method("ark/notification", Backend::notification)
        .finish();

    let server = Server::new(stdin, stdout, socket);

    tokio::select! {
        _ = server.serve(service) => {},
        _ = shutdown_rx.recv() => {},
    }

    Ok(())
}

fn new_jsonrpc_error(message: String) -> jsonrpc::Error {
    jsonrpc::Error {
        code: jsonrpc::ErrorCode::ServerError(-1),
        message: message.into(),
        data: None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::NotificationBarrier;

    #[tokio::test]
    async fn notification_barrier_waits_for_prior_notifications_only() {
        let barrier = Arc::new(NotificationBarrier::default());
        let first = barrier.enqueue();
        let target = barrier.queued();

        let waiter = tokio::spawn({
            let barrier = barrier.clone();
            async move {
                barrier.wait_for(target).await;
            }
        });

        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(!waiter.is_finished());

        let _second = barrier.enqueue();
        barrier.mark_processed(first);

        tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("waiter should be released after first notification is processed")
            .expect("waiter task should finish cleanly");
    }
}
