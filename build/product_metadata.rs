use std::path::PathBuf;
use std::process::Command;

pub fn emit() {
    let manifest_path = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("../../release-manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", manifest_path.display()));
    let manifest: serde_json::Value = serde_json::from_str(&manifest_text)
        .unwrap_or_else(|err| panic!("failed to parse {}: {err}", manifest_path.display()));

    let product_version = manifest["product_version"]
        .as_str()
        .expect("release manifest must contain product_version");
    let bridge_schema = manifest["compatibility"]["bridge_schema"]
        .as_str()
        .expect("release manifest must contain compatibility.bridge_schema");

    let build_commit = std::env::var("ARK_BUILD_COMMIT")
        .or_else(|_| std::env::var("GITHUB_SHA"))
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(git_commit)
        .unwrap_or_else(|| String::from("unknown"));
    let rustc_version = command_first_line(
        std::env::var("RUSTC").unwrap_or_else(|_| String::from("rustc")),
        &["-Vv"],
    )
    .unwrap_or_else(|| String::from("unknown"));

    println!("cargo:rerun-if-changed={}", manifest_path.display());
    println!("cargo:rerun-if-env-changed=ARK_BUILD_COMMIT");
    println!("cargo:rerun-if-env-changed=GITHUB_SHA");
    println!("cargo:rustc-env=ARK_PRODUCT_VERSION={product_version}");
    println!("cargo:rustc-env=ARK_BRIDGE_SCHEMA={bridge_schema}");
    println!("cargo:rustc-env=ARK_BUILD_COMMIT={build_commit}");
    println!(
        "cargo:rustc-env=ARK_BUILD_TARGET={}",
        env_or_unknown("TARGET")
    );
    println!(
        "cargo:rustc-env=ARK_BUILD_PROFILE={}",
        env_or_unknown("PROFILE")
    );
    println!("cargo:rustc-env=ARK_BUILD_RUSTC={rustc_version}");
}

fn env_or_unknown(name: &str) -> String {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| String::from("unknown"))
}

fn git_commit() -> Option<String> {
    command_first_line(String::from("git"), &["rev-parse", "HEAD"])
}

fn command_first_line(program: String, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }

    String::from_utf8(output.stdout)
        .ok()?
        .lines()
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(String::from)
}
