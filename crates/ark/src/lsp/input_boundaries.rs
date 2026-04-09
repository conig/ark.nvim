use serde::Deserialize;
use serde::Serialize;

use crate::analysis::input_boundaries::InputBoundary;

pub static ARK_INPUT_BOUNDARIES_REQUEST: &str = "ark/inputBoundaries";

#[derive(Debug, Eq, PartialEq, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InputBoundariesParams {
    pub text: String,
}

#[derive(Debug, Eq, PartialEq, Clone, Serialize)]
pub struct InputBoundariesResponse {
    pub boundaries: Vec<InputBoundary>,
}
