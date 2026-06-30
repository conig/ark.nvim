use std::marker::PhantomData;
use std::path::PathBuf;
use std::sync::OnceLock;

use ark_lsp_support::notifications::ConsoleInputs;
use harp::object::RObject;

use crate::lsp::main_loop::LspEventSender;

pub struct ErasedRTask {
    data: *mut (),
    run: unsafe fn(*mut ()),
}

unsafe impl Send for ErasedRTask {}

impl ErasedRTask {
    /// Runs the erased task.
    ///
    /// # Safety
    ///
    /// The task must be run exactly once while the stack frame that created it
    /// is still alive. Host runtimes must not store the task or run it after
    /// returning from the `run_r_task` hook.
    pub unsafe fn run(self) {
        unsafe { (self.run)(self.data) };
    }
}

#[derive(Clone, Copy)]
pub struct HostHooks {
    pub run_r_task: unsafe fn(ErasedRTask),
    pub console_is_initialized: fn() -> bool,
    pub selected_env: fn() -> RObject,
    pub console_inputs: fn() -> anyhow::Result<ConsoleInputs>,
    pub attached_library_paths: fn() -> Vec<PathBuf>,
    pub show_crash_message: fn(&str),
    pub set_lsp_channel: fn(LspEventSender),
    pub remove_lsp_channel: fn(),
}

static HOST_HOOKS: OnceLock<HostHooks> = OnceLock::new();

pub fn install_host_hooks(hooks: HostHooks) {
    let _ = HOST_HOOKS.set(hooks);
}

fn hooks() -> HostHooks {
    HOST_HOOKS.get().copied().unwrap_or(HostHooks {
        run_r_task: default_run_r_task,
        console_is_initialized: || false,
        selected_env: crate::console::default_selected_env,
        console_inputs: crate::console::default_console_inputs,
        attached_library_paths: Vec::new,
        show_crash_message: |message| log::error!("{message}"),
        set_lsp_channel: |_| {},
        remove_lsp_channel: || {},
    })
}

struct RTask<'env, F, T>
where
    F: FnOnce() -> T + Send + 'env,
    T: Send + 'env,
{
    f: Option<F>,
    output: Option<T>,
    _marker: PhantomData<&'env mut ()>,
}

unsafe fn run_task<'env, F, T>(data: *mut ())
where
    F: FnOnce() -> T + Send + 'env,
    T: Send + 'env,
{
    let task = unsafe { &mut *(data as *mut RTask<'env, F, T>) };
    let f = task.f.take().unwrap();
    task.output = Some(f());
}

pub fn r_task<'env, F, T>(f: F) -> T
where
    F: FnOnce() -> T + Send + 'env,
    T: Send + 'env,
{
    let mut task = RTask {
        f: Some(f),
        output: None,
        _marker: PhantomData,
    };

    let erased = ErasedRTask {
        data: &mut task as *mut RTask<'env, F, T> as *mut (),
        run: run_task::<'env, F, T>,
    };

    unsafe { (hooks().run_r_task)(erased) };

    task.output.take().unwrap()
}

unsafe fn default_run_r_task(task: ErasedRTask) {
    if stdext::IS_TESTING {
        let _lock = harp::fixtures::R_TEST_LOCK.lock();
        crate::fixtures::r_test_init();
        unsafe { task.run() };
        return;
    }

    unsafe { task.run() };
}

pub fn console_is_initialized() -> bool {
    (hooks().console_is_initialized)()
}

pub fn selected_env() -> RObject {
    (hooks().selected_env)()
}

pub fn console_inputs() -> anyhow::Result<ConsoleInputs> {
    (hooks().console_inputs)()
}

pub fn attached_library_paths() -> Vec<PathBuf> {
    (hooks().attached_library_paths)()
}

pub fn show_crash_message(message: &str) {
    (hooks().show_crash_message)(message)
}

pub fn set_lsp_channel(events_tx: LspEventSender) {
    (hooks().set_lsp_channel)(events_tx)
}

pub fn remove_lsp_channel() {
    (hooks().remove_lsp_channel)()
}
