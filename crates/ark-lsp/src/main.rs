use ark_lsp::lsp::backend;
use ark_lsp::lsp::state::RuntimeMode;

fn print_usage() {
    println!(
        "Usage: ark-lsp [--runtime-mode detached|attached]\n\n\
         The default runtime mode is `detached`, which disables live R session features."
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut runtime_mode = RuntimeMode::Detached;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--runtime-mode" => {
                let Some(value) = args.next() else {
                    return Err(anyhow::anyhow!(
                        "A value must follow `--runtime-mode` (`detached` or `attached`)."
                    ));
                };

                runtime_mode = match value.as_str() {
                    "detached" => RuntimeMode::Detached,
                    "attached" => RuntimeMode::Attached,
                    _ => {
                        return Err(anyhow::anyhow!(
                            "Invalid runtime mode `{value}`. Expected `detached` or `attached`."
                        ));
                    },
                };
            },
            "--help" | "-h" => {
                print_usage();
                return Ok(());
            },
            other => {
                return Err(anyhow::anyhow!("Unknown argument: {other}"));
            },
        }
    }

    backend::start_stdio_lsp(runtime_mode).await
}
