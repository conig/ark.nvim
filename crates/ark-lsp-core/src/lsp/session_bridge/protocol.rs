use serde::Deserialize;
use serde::Serialize;

use super::deserialize_string_vec;

#[derive(Clone, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HelpReference {
    pub label: String,
    pub topic: String,
    #[serde(default)]
    pub package: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HelpPage {
    pub text: String,
    #[serde(default)]
    pub references: Vec<HelpReference>,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct InspectRequest {
    pub(super) request_id: String,
    pub(super) auth_token: String,
    pub(super) expr: String,
    pub(super) session: BridgeSession,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) options: Option<InspectOptions>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub(super) struct InspectOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) accessor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) include_member_stats: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) max_members: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) member_name_filter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) member_name_prefix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) request_profile: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub(super) struct BridgeSession {
    pub(super) backend: String,
    pub(super) session_id: String,
    pub(super) tmux_socket: String,
    pub(super) tmux_session: String,
    pub(super) tmux_pane: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct InspectResponse {
    #[serde(default)]
    pub(super) error: Option<BridgeError>,
    #[serde(default)]
    pub(super) object_meta: Option<ObjectMeta>,
    #[serde(default)]
    pub(super) members: Vec<BridgeMember>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct BridgeError {
    #[serde(default)]
    pub(super) code: String,
    #[serde(default)]
    pub(super) message: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct ObjectMeta {
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    pub(super) class: Vec<String>,
    #[serde(default)]
    pub(super) length: usize,
    #[serde(default)]
    pub(super) summary: String,
    #[serde(default)]
    pub(super) r#type: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct BridgeMember {
    #[serde(default)]
    pub(super) insert_text: String,
    #[serde(default)]
    pub(super) name_display: String,
    #[serde(default)]
    pub(super) name_raw: String,
    #[serde(default)]
    pub(super) summary: String,
    #[serde(default)]
    pub(super) r#type: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct SessionStatusPayload {
    #[serde(default)]
    pub(super) status: String,
    #[serde(default)]
    pub(super) product_version: String,
    #[serde(default)]
    pub(super) bridge_schema: String,
    #[serde(default)]
    pub(super) port: Option<u16>,
    #[serde(default)]
    pub(super) auth_token: String,
    #[serde(default)]
    pub(super) repl_seq: Option<u64>,
    #[serde(default)]
    pub(super) bootstrap: Option<StatusBootstrapPayload>,
    #[serde(default)]
    pub(super) bootstrap_path: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct StatusBootstrapPayload {
    #[serde(default)]
    pub(super) repl_seq: Option<u64>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    pub(super) search_path_symbols: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    pub(super) library_paths: Vec<String>,
    #[serde(default)]
    pub(super) total_ms: Option<u64>,
    #[serde(default)]
    pub(super) search_path_symbols_ms: Option<u64>,
    #[serde(default)]
    pub(super) library_paths_ms: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct BootstrapRequest {
    pub(super) request_id: String,
    pub(super) auth_token: String,
    pub(super) command: String,
    pub(super) session: BridgeSession,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct BootstrapResponse {
    #[serde(default)]
    pub(super) error: Option<BridgeError>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    pub(super) search_path_symbols: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_string_vec")]
    pub(super) library_paths: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct HelpTextRequest {
    pub(super) request_id: String,
    pub(super) auth_token: String,
    pub(super) command: String,
    pub(super) topic: String,
    pub(super) session: BridgeSession,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct HelpTextResponse {
    #[serde(default)]
    pub(super) error: Option<BridgeError>,
    #[serde(default)]
    pub(super) found: bool,
    #[serde(default)]
    pub(super) text: String,
    #[serde(default)]
    pub(super) references: Vec<HelpReference>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub(super) struct PackageInfoResponse {
    #[serde(default)]
    pub(super) found: bool,
    #[serde(default)]
    pub(super) package: String,
    #[serde(default)]
    pub(super) title: String,
    #[serde(default)]
    pub(super) version: String,
    #[serde(default)]
    pub(super) description: String,
    #[serde(default)]
    pub(super) license: String,
    #[serde(default)]
    pub(super) url: String,
    #[serde(default)]
    pub(super) lib_path: String,
}

#[derive(Clone, Debug, Serialize)]
pub(super) struct BridgeCommandRequest<T>
where
    T: Serialize,
{
    pub(super) request_id: String,
    pub(super) auth_token: String,
    pub(super) command: String,
    pub(super) session: BridgeSession,
    #[serde(flatten)]
    pub(super) payload: T,
}
