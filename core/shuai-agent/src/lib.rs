//! shuai-agent: the small helper installed on dev servers (`~/.shuai/bin/shuai-agent`).
//!
//! It is invoked by Claude Code / Codex hooks to record events, and by the iPad app (over an
//! SSH exec channel) to watch events and answer permission requests.

pub mod doctor;
pub mod hook;
pub mod ntfy;
pub mod respond;
pub mod state;
pub mod store;
pub mod watch;
