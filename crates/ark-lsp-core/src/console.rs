use aether_path::FilePath;
use anyhow::Result;
use ark_lsp_support::notifications::ConsoleInputs;
use harp::environment::Environment;
use harp::exec::RFunction;
use harp::exec::RFunctionExt;
use harp::object::RObject;
use harp::R_ENVS;

#[derive(Debug)]
pub enum ConsoleNotification {
    DidChangeDocument(FilePath),
}

pub struct Console;

impl Console {
    pub fn is_initialized() -> bool {
        crate::runtime::console_is_initialized()
    }
}

pub fn selected_env() -> RObject {
    crate::runtime::selected_env()
}

pub fn console_inputs() -> Result<ConsoleInputs> {
    crate::runtime::console_inputs()
}

pub(crate) fn default_selected_env() -> RObject {
    R_ENVS.global.into()
}

pub(crate) fn default_console_inputs() -> Result<ConsoleInputs> {
    let env = Environment::new(R_ENVS.global.into());
    let scopes = env.ancestors().map(|e| e.names()).collect();

    let installed_packages: Vec<String> = RFunction::new("base", ".packages")
        .param("all.available", true)
        .call()?
        .try_into()?;

    Ok(ConsoleInputs {
        console_scopes: scopes,
        installed_packages,
    })
}
