use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct ProductMetadata {
    pub component: &'static str,
    pub product_version: &'static str,
    pub bridge_schema: &'static str,
    pub crate_version: &'static str,
    pub commit: &'static str,
    pub target: &'static str,
    pub profile: &'static str,
    pub rustc: &'static str,
}

pub fn metadata() -> ProductMetadata {
    ProductMetadata {
        component: "ark-lsp",
        product_version: env!("ARK_PRODUCT_VERSION"),
        bridge_schema: env!("ARK_BRIDGE_SCHEMA"),
        crate_version: env!("CARGO_PKG_VERSION"),
        commit: env!("ARK_BUILD_COMMIT"),
        target: env!("ARK_BUILD_TARGET"),
        profile: env!("ARK_BUILD_PROFILE"),
        rustc: env!("ARK_BUILD_RUSTC"),
    }
}

pub fn plain_version() -> String {
    let metadata = metadata();
    format!(
        "ark-lsp {} (schema {}, commit {}, target {}, profile {}, rustc {})",
        metadata.product_version,
        metadata.bridge_schema,
        short_commit(metadata.commit),
        metadata.target,
        metadata.profile,
        metadata.rustc
    )
}

fn short_commit(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_version_matches_release_manifest() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../../../release-manifest.json")).unwrap();

        assert_eq!(manifest["product_version"], metadata().product_version);
        assert_eq!(
            manifest["compatibility"]["bridge_schema"],
            metadata().bridge_schema
        );
    }
}
