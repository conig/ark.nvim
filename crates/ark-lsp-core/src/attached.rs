use harp::object::RObject;

/// Whether the optional attached host has initialized its embedded R runtime.
pub(crate) fn is_ready() -> bool {
    #[cfg(feature = "attached-runtime")]
    {
        crate::console::Console::is_initialized()
    }

    #[cfg(not(feature = "attached-runtime"))]
    {
        false
    }
}

/// Return the attached host's selected R environment.
///
/// Callers are reachable only when `WorldState` is in attached mode. Keeping
/// this adapter behind the Cargo feature makes that invariant compile-time
/// visible for the detached product build.
pub(crate) fn selected_env() -> RObject {
    #[cfg(feature = "attached-runtime")]
    {
        crate::console::selected_env()
    }

    #[cfg(not(feature = "attached-runtime"))]
    {
        unreachable!("attached R environment requested by a detached-only LSP build")
    }
}

/// Execute work on the attached host's serialized R thread.
pub(crate) fn run<'env, F, T>(f: F) -> T
where
    F: FnOnce() -> T + Send + 'env,
    T: Send + 'env,
{
    #[cfg(feature = "attached-runtime")]
    {
        crate::runtime::r_task(f)
    }

    #[cfg(not(feature = "attached-runtime"))]
    {
        drop(f);
        unreachable!("attached R task requested by a detached-only LSP build")
    }
}
