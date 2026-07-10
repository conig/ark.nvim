//
// handler.rs
//
// Copyright (C) 2022-2026 Posit Software, PBC. All rights reserved.
//
//

use std::sync::Arc;

use amalthea::comm::server_comm::ServerStartMessage;
use amalthea::comm::server_comm::ServerStartedMessage;
use amalthea::language::server_handler::ServerHandler;
use amalthea::socket::comm::CommOutgoingTx;
use bus::BusReader;
use crossbeam::channel::Sender;
use stdext::spawn;
use tokio::runtime::Builder;
use tokio::runtime::Runtime;
use tokio::sync::mpsc::UnboundedSender as AsyncUnboundedSender;

use super::backend;
use crate::console::HostNotification;
use crate::console::KernelInfo;

pub(crate) struct Lsp {
    runtime: Arc<Runtime>,
    kernel_init_rx: BusReader<KernelInfo>,
    kernel_initialized: bool,
    host_notification_tx: AsyncUnboundedSender<HostNotification>,
}

impl Lsp {
    pub(crate) fn new(
        kernel_init_rx: BusReader<KernelInfo>,
        host_notification_tx: AsyncUnboundedSender<HostNotification>,
    ) -> Self {
        let rt = Builder::new_multi_thread()
            .enable_all()
            // One for the main loop and one spare
            .worker_threads(2)
            // Used for diagnostics
            .max_blocking_threads(2)
            .build()
            .unwrap();

        Self {
            runtime: Arc::new(rt),
            kernel_init_rx,
            kernel_initialized: false,
            host_notification_tx,
        }
    }
}

impl ServerHandler for Lsp {
    fn start(
        &mut self,
        server_start: ServerStartMessage,
        server_started_tx: Sender<ServerStartedMessage>,
        _comm_tx: CommOutgoingTx,
    ) -> Result<(), amalthea::error::Error> {
        // If the kernel hasn't been initialized yet, wait for it to finish.
        // This prevents the LSP from attempting to start up before the kernel
        // is ready; on subsequent starts (reconnects), the kernel will already
        // be initialized.
        if !self.kernel_initialized {
            let status = self.kernel_init_rx.recv();
            if let Err(error) = status {
                log::error!("Error waiting for kernel to initialize: {}", error);
            }
            self.kernel_initialized = true;
        }

        // Retain ownership of the tokio `runtime` inside the `Lsp` to
        // account for potential reconnects
        let runtime = self.runtime.clone();

        let start_config = backend::LspStartConfig::new(server_start.ip_address().to_string());
        let server_started = move |started: backend::LspStarted| {
            server_started_tx
                .send(ServerStartedMessage::new(started.port()))
                .map_err(|err| anyhow::anyhow!("{err}"))
        };
        let host_notification_tx = self.host_notification_tx.clone();
        spawn!("ark-lsp", move || {
            backend::start_lsp(runtime, start_config, server_started, host_notification_tx)
        });
        Ok(())
    }
}
