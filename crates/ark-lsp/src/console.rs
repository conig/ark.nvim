use harp::RObject;
use harp::R_ENVS;

#[derive(Debug)]
pub enum ConsoleNotification {
    DidChangeDocument(String),
}

pub struct Console;

impl Console {
    pub fn is_initialized() -> bool {
        false
    }
}

pub fn selected_env() -> RObject {
    R_ENVS.global.into()
}
