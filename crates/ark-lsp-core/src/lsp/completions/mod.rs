//
// completions.rs
//
// Copyright (C) 2023 Posit Software, PBC. All rights reserved.
//
//

mod completion_context;
mod completion_item;
mod function_context;
mod provide;
mod resolve;
mod sources;
mod types;

#[cfg(test)]
mod tests;

pub(crate) use provide::provide_completions;
pub(crate) use provide::provide_detached_post_bridge_completions;
pub(crate) use provide::provide_detached_pre_bridge_completions;
pub(crate) use provide::provide_detached_static_completions;
pub(crate) use resolve::resolve_completion;
pub(crate) use sources::composite::dedupe_and_sort_completion_items;
pub(crate) use sources::composite::find_pipe_root_name;
pub(crate) use sources::utils::call_node_position_type;
pub(crate) use sources::utils::CallNodePositionType;
