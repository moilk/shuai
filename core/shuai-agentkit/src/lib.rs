//! shuai-agentkit: pure, sans-io agent-session logic shared by the iPad and Android apps.
//!
//! * [`AgentTracker`] folds the `shuai-agent watch` event stream ([`shuai_proto::Envelope`]) into
//!   per-session state, deduplicating replays, and reports [`TrackerChange`]s for banners/haptics.
//!
//! Nothing here touches the clock, the network or the filesystem: time comes from event
//! timestamps or is passed in by the caller.

mod tracker;

pub use tracker::{
    AgentSession, AgentTracker, Badge, PendingPermission, SessionKey, SessionState, TrackerChange,
};
