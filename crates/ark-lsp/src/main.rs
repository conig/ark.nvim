use ark_lsp::lsp::backend;
use ark_lsp::product;

fn print_usage() {
    println!(
        "Usage: ark-lsp [--runtime-mode detached]\n\
         ark-lsp --version [--json]\n\n\
         The detached stdio server receives live R session features through arkbridge."
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // This worker is also used by the editor; it runs off the startup/UI path.
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.get(1).map(String::as_str) == Some("--source-identity") {
        let root = arguments
            .get(2)
            .ok_or_else(|| anyhow::anyhow!("missing checkout path"))?;
        let component = arguments.get(3).map(String::as_str).unwrap_or("lsp");
        let mut snapshot =
            ark_lsp::source_identity::snapshot(std::path::Path::new(root), component)
                .map_err(|error| anyhow::anyhow!("{error}"))?;
        snapshot["built"] = serde_json::to_value(product::metadata())?;
        println!("{}", snapshot);
        return Ok(());
    }
    let mut print_version = false;
    let mut json = false;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--runtime-mode" => {
                let Some(value) = args.next() else {
                    return Err(anyhow::anyhow!(
                        "A value must follow `--runtime-mode` (`detached`)."
                    ));
                };

                if value != "detached" {
                    return Err(anyhow::anyhow!(
                        "Invalid runtime mode `{value}`. Expected `detached`."
                    ));
                }
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

    backend::start_stdio_lsp().await
}
