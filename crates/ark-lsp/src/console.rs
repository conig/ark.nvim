#[cfg(test)]
use anyhow::Result;
#[cfg(test)]
use ark_lsp_support::notifications::ConsoleInputs;
#[cfg(test)]
use harp::environment::Environment;
#[cfg(test)]
use harp::exec::RFunction;
#[cfg(test)]
use harp::exec::RFunctionExt;
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

#[cfg(test)]
pub(crate) fn console_inputs() -> Result<ConsoleInputs> {
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
