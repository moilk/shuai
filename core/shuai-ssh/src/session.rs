//! Client session, shell and exec channels (stubs; implemented after the tests).

use std::sync::Arc;

use crate::config::{ConnectConfig, HostKeyVerifier, PtyRequest};
use crate::error::{Result, SshError};

/// Collected result of [`Session::exec`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ExecOutput {
    /// Standard output bytes.
    pub stdout: Vec<u8>,
    /// Standard error bytes.
    pub stderr: Vec<u8>,
    /// Exit status, if the server reported one.
    pub exit_status: Option<u32>,
}

/// One event from an [`ExecChannel`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExecEvent {
    /// Bytes on stdout.
    Stdout(Vec<u8>),
    /// Bytes on stderr.
    Stderr(Vec<u8>),
    /// The remote command exited with this status.
    ExitStatus(u32),
}

/// An established, authenticated SSH connection.
pub struct Session {}

/// Interactive PTY shell channel.
pub struct ShellChannel {}

/// Streaming exec channel.
pub struct ExecChannel {}

impl Session {
    /// Connects and authenticates.
    pub async fn connect(
        _config: ConnectConfig,
        _verifier: Arc<dyn HostKeyVerifier>,
    ) -> Result<Session> {
        unimplemented!()
    }
    /// Opens a PTY shell.
    pub async fn open_shell(&self, _pty: PtyRequest) -> Result<ShellChannel> {
        unimplemented!()
    }
    /// Runs a command to completion.
    pub async fn exec(&self, _cmd: &str) -> Result<ExecOutput> {
        unimplemented!()
    }
    /// Starts a command and streams its output.
    pub async fn exec_stream(&self, _cmd: &str) -> Result<ExecChannel> {
        unimplemented!()
    }
    /// Whether the session is gone.
    pub fn is_closed(&self) -> bool {
        unimplemented!()
    }
    /// Resolves once the session has ended; returns why.
    pub async fn closed(&self) -> SshError {
        unimplemented!()
    }
    /// Disconnects.
    pub async fn disconnect(&self) -> Result<()> {
        unimplemented!()
    }
}

impl ShellChannel {
    /// Sends input bytes.
    pub async fn write(&self, _data: &[u8]) -> Result<()> {
        unimplemented!()
    }
    /// Resizes the PTY.
    pub async fn resize(&self, _cols: u32, _rows: u32) -> Result<()> {
        unimplemented!()
    }
    /// Next chunk of output; `None` once the channel is closed.
    pub async fn read(&self) -> Option<Vec<u8>> {
        unimplemented!()
    }
    /// Closes the channel.
    pub async fn close(&self) -> Result<()> {
        unimplemented!()
    }
}

impl ExecChannel {
    /// Next event; `None` once the channel is closed.
    pub async fn next(&self) -> Option<ExecEvent> {
        unimplemented!()
    }
    /// Writes to the command's stdin.
    pub async fn write_stdin(&self, _data: &[u8]) -> Result<()> {
        unimplemented!()
    }
    /// Closes the channel.
    pub async fn close(&self) -> Result<()> {
        unimplemented!()
    }
}
