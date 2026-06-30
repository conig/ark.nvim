use std::path::PathBuf;

use ark_lsp_core::runtime::ErasedRTask;
use ark_lsp_core::runtime::HostHooks;

use crate::console::Console;
use crate::lsp::main_loop::LspEventSender;

pub(crate) fn install_core_hooks() {
    ark_lsp_core::runtime::install_host_hooks(HostHooks {
        run_r_task,
        console_is_initialized,
        selected_env: crate::console::selected_env,
        console_inputs: crate::console::console_inputs,
        attached_library_paths,
        show_crash_message,
        set_lsp_channel,
        remove_lsp_channel,
    });
}

unsafe fn run_r_task(task: ErasedRTask) {
    crate::r_task(move || unsafe {
        task.run();
    });
}

fn console_is_initialized() -> bool {
    Console::is_initialized()
}

fn attached_library_paths() -> Vec<PathBuf> {
    let library_paths = crate::r_task(|| -> anyhow::Result<Vec<String>> {
        Ok(harp::RFunction::new("base", ".libPaths")
            .call()?
            .try_into()?)
    });

    let library_paths = match library_paths {
        Ok(library_paths) => library_paths,
        Err(err) => {
            log::error!("Can't evaluate `libPaths()`: {err:?}");
            Vec::new()
        },
    };

    library_paths.into_iter().map(PathBuf::from).collect()
}

fn show_crash_message(message: &str) {
    let message = String::from(message);
    crate::r_task(move || {
        if let Some(ui) = Console::get().ui_comm() {
            ui.show_message(message);
        }
    });
}

fn set_lsp_channel(events_tx: LspEventSender) {
    crate::r_task(move || {
        Console::get_mut().set_lsp_channel(events_tx);
    });
}

fn remove_lsp_channel() {
    crate::r_task(|| {
        Console::get_mut().remove_lsp_channel();
    });
}
