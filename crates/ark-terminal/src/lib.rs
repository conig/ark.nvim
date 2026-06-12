mod cli;
mod enhanced;
mod lsp_client;
mod prompt;
mod raw_terminal;
mod render;
mod status;
mod trace;

#[cfg(unix)]
mod pty;

pub mod input;
pub mod keys;
pub use cli::Cli;
pub use enhanced::EnhancedInputRuntime;
pub use enhanced::InputEffect;
pub use lsp_client::apply_lsp_text_edit;
pub use lsp_client::byte_offset_for_position;
pub use lsp_client::completion_items_from_response;
pub use lsp_client::decode_message;
pub use lsp_client::encode_message;
pub use lsp_client::ConsoleDocument;
pub use lsp_client::LspMessageFactory;
pub use lsp_client::LspPosition;
pub use lsp_client::LspTransport;

pub fn run_from_env() -> anyhow::Result<i32> {
    let cli = Cli::parse(std::env::args().skip(1))?;
    run(cli)
}

pub fn run(cli: Cli) -> anyhow::Result<i32> {
    if cli.help {
        println!("{}", Cli::usage());
        return Ok(0);
    }

    if cli.version {
        println!("ark-terminal {}", env!("CARGO_PKG_VERSION"));
        return Ok(0);
    }

    run_platform(cli)
}

#[cfg(unix)]
fn run_platform(cli: Cli) -> anyhow::Result<i32> {
    pty::run(cli)
}

#[cfg(not(unix))]
fn run_platform(_cli: Cli) -> anyhow::Result<i32> {
    return Err(anyhow::anyhow!(
        "ark-terminal managed PTY mode is only supported on Unix"
    ));
}
