//! Correcting tracker state from ground truth (live tmux panes, `claude agents --json`).

use std::collections::HashSet;

use serde_json::Value;
use shuai_tmux::TmuxTopology;

use crate::tracker::{AgentTracker, SessionKey, SessionState, TrackerChange};

/// What `claude agents --json` says about one session, normalized.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reported {
    Busy,
    WaitingPermission,
    WaitingInput,
    Idle,
    Failed,
    Stopped,
}

fn s<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str)
}

fn reported(entry: &Value) -> Option<Reported> {
    let waiting = || {
        let w = s(entry, "waitingFor").unwrap_or("").to_ascii_lowercase();
        if w.contains("permission") || w.contains("approv") {
            Reported::WaitingPermission
        } else {
            Reported::WaitingInput
        }
    };
    let from_state = match s(entry, "state") {
        Some("working") => Some(Reported::Busy),
        Some("blocked") => Some(waiting()),
        Some("done") => Some(Reported::Idle),
        Some("failed") => Some(Reported::Failed),
        Some("stopped") => Some(Reported::Stopped),
        _ => None,
    };
    from_state.or(match s(entry, "status") {
        Some("busy") => Some(Reported::Busy),
        Some("waiting") => Some(waiting()),
        Some("idle") => Some(Reported::Idle),
        _ => None,
    })
}

impl AgentTracker {
    /// Sessions on `host` whose tmux pane is not in `topology` are Ended. Only call this with a
    /// topology freshly read from that host. Sessions without pane info are left alone.
    pub fn reconcile_with_live_panes(
        &mut self,
        host: &str,
        topology: &TmuxTopology,
        now_ms: u64,
    ) -> Vec<TrackerChange> {
        let live: HashSet<_> = topology
            .sessions
            .iter()
            .flat_map(|s| &s.windows)
            .flat_map(|w| &w.panes)
            .map(|p| p.id)
            .collect();
        let gone: Vec<SessionKey> = self
            .sessions
            .values()
            .filter(|x| x.host == host)
            .filter(|x| x.tmux_pane.is_some_and(|p| !live.contains(&p)))
            .map(|x| x.key())
            .collect();
        let mut out = Vec::new();
        for k in gone {
            self.end_session(&k, now_ms, &mut out);
        }
        out
    }

    /// Correct stale states from the output of `claude agents --json` on `host`.
    ///
    /// Lenient: accepts a bare array or `{"agents": [...]}`, ignores unknown fields/values and
    /// malformed entries. Unknown sessions are ignored and Ended sessions are not resurrected.
    pub fn apply_claude_agents_json(
        &mut self,
        host: &str,
        json: &str,
        now_ms: u64,
    ) -> Result<Vec<TrackerChange>, serde_json::Error> {
        let root: Value = serde_json::from_str(json)?;
        let entries: &[Value] = match &root {
            Value::Array(a) => a,
            Value::Object(o) => o
                .get("agents")
                .or_else(|| o.get("sessions"))
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]),
            _ => &[],
        };
        let mut out = Vec::new();
        for e in entries.iter().filter(|e| e.is_object()) {
            let Some(sid) = s(e, "sessionId").or_else(|| s(e, "id")) else {
                continue;
            };
            let key = SessionKey::new(host, sid);
            let Some(sess) = self.sessions.get_mut(&key) else {
                continue;
            };
            if sess.state == SessionState::Ended {
                continue;
            }
            if sess.title.is_none() {
                sess.title = s(e, "name").map(str::to_string);
            }
            if sess.pid.is_none() {
                sess.pid = e.get("pid").and_then(Value::as_u64).map(|p| p as u32);
            }
            if sess.cwd.is_none() {
                sess.cwd = s(e, "cwd").map(str::to_string);
            }
            let Some(rep) = reported(e) else { continue };
            use SessionState::*;
            let new = match (rep, &sess.state) {
                (Reported::Stopped, _) => Some(Ended),
                (Reported::Failed, Failed { .. }) => None,
                (Reported::Failed, _) => Some(Failed {
                    error: "failed".into(),
                }),
                (Reported::Busy, Done | NeedsInput | Starting | Failed { .. }) => {
                    Some(Working { tool: None })
                }
                (Reported::Idle, Working { .. } | Starting | NeedsPermission) => Some(Done),
                (Reported::WaitingPermission, Working { .. } | Starting | Done) => {
                    Some(NeedsPermission)
                }
                (Reported::WaitingInput, Working { .. } | Starting | Done) => Some(NeedsInput),
                _ => None,
            };
            if let Some(new) = new {
                if new == Ended {
                    self.end_session(&key, now_ms, &mut out);
                } else {
                    self.set_state_external(&key, new, now_ms, &mut out);
                }
            }
        }
        Ok(out)
    }
}
