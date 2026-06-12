use std::process::ExitCode;

fn main() -> ExitCode {
    match ark_terminal::run_from_env() {
        Ok(code) => exit_code(code),
        Err(err) => {
            eprintln!("ark-terminal: {err:#}");
            ExitCode::FAILURE
        },
    }
}

fn exit_code(code: i32) -> ExitCode {
    match u8::try_from(code) {
        Ok(code) => ExitCode::from(code),
        Err(_) => ExitCode::FAILURE,
    }
}
