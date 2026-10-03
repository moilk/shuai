//! shuai-agentkit: pure, sans-io agent-session logic shared by the iPad and Android apps.
//!
//! * [`AgentTracker`] folds the `shuai-agent watch` event stream ([`shuai_proto::Envelope`]) into
//!   per-session state, deduplicating replays, and reports [`TrackerChange`]s for banners/haptics.
//! * [`install`] plans the remote "enable AI integration" flow (probe script, parsing, steps).
//!
//! Nothing here touches the clock, the network or the filesystem: time comes from event
//! timestamps or is passed in by the caller.

pub mod install;
mod queries;
mod reconcile;
mod tracker;

pub use install::{InstallPlan, InstallStep, ProbeResult, parse_probe, probe_script};
pub use tracker::{
    AgentSession, AgentTracker, Badge, PendingPermission, SessionKey, SessionState, TrackerChange,
};
