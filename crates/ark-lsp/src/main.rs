use ark_lsp::lsp::backend;
use ark_lsp::lsp::state::RuntimeMode;
use ark_lsp::product;

fn print_usage() {
    println!(
        "Usage: ark-lsp [--runtime-mode detached|attached]\n\
         ark-lsp --version [--json]\n\n\
         The default runtime mode is `detached`, which disables live R session features."
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut runtime_mode = RuntimeMode::Detached;
    let mut print_version = false;
    let mut json = false;
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
            "--version" | "-V" => {
                print_version = true;
            },
            "--json" => {
                json = true;
            },
            other => {
                return Err(anyhow::anyhow!("Unknown argument: {other}"));
            },
        }
    }

    if json && !print_version {
        return Err(anyhow::anyhow!("`--json` is only valid with `--version`."));
    }
    if print_version {
        if json {
            println!("{}", serde_json::to_string(&product::metadata())?);
        } else {
            println!("{}", product::plain_version());
        }
        return Ok(());
    }

    backend::start_stdio_lsp(runtime_mode).await
}
