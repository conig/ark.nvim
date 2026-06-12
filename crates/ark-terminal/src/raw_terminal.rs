use std::io;
use std::os::fd::AsFd;

use nix::sys::termios::cfmakeraw;
use nix::sys::termios::tcgetattr;
use nix::sys::termios::tcsetattr;
use nix::sys::termios::SetArg;
use nix::sys::termios::Termios;

pub struct RawTerminal<Fd: AsFd> {
    fd: Fd,
    original: Option<Termios>,
}

impl<Fd: AsFd> RawTerminal<Fd> {
    pub fn enter(fd: Fd) -> io::Result<Self> {
        let mut termios = tcgetattr(&fd).map_err(io::Error::from)?;
        let original = termios.clone();
        cfmakeraw(&mut termios);
        tcsetattr(&fd, SetArg::TCSANOW, &termios).map_err(io::Error::from)?;

        Ok(Self {
            fd,
            original: Some(original),
        })
    }
}

impl<Fd: AsFd> Drop for RawTerminal<Fd> {
    fn drop(&mut self) {
        if let Some(original) = self.original.take() {
            let _ = tcsetattr(&self.fd, SetArg::TCSANOW, &original);
        }
    }
}
