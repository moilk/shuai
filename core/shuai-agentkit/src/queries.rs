//! UI-facing queries over the tracker.

use shuai_tmux::{PaneId, TmuxTopology, WindowId};

use crate::tracker::{AgentSession, AgentTracker, Badge, SessionKey, SessionState};

impl AgentSession {
    /// Badge for this session; `None` once it has ended.
    pub fn badge(&self) -> Option<Badge> {
        Some(match &self.state {
            SessionState::NeedsPermission => Badge::NeedsPermission,
            SessionState::NeedsInput => Badge::NeedsInput,
            SessionState::Failed { .. } => Badge::Failed,
            SessionState::Done if !self.seen => Badge::Done,
            SessionState::Working { .. } => Badge::Working,
            SessionState::Starting | SessionState::Done => Badge::Idle,
            SessionState::Ended => return None,
        })
    }
}

impl AgentTracker {
    /// The user looked at this session: unseen Done/Failed/NeedsInput stop counting as
    /// attention until the next state change. Returns whether anything changed.
    pub fn mark_seen(&mut self, key: &SessionKey) -> bool {
        match self.sessions.get_mut(key) {
            Some(s) if !s.seen => {
                s.seen = true;
                true
            }
            _ => false,
        }
    }

    /// Next session that wants the user after `after`, in priority order, wrapping around.
    /// If `after` is `None` or no longer needs attention, the most urgent one is returned.
    pub fn next_needing_attention(&self, after: Option<&SessionKey>) -> Option<&AgentSession> {
        let list: Vec<&AgentSession> = self
            .sessions()
            .into_iter()
            .filter(|s| s.needs_attention())
            .collect();
        let idx = after
            .and_then(|k| {
                list.iter()
                    .position(|s| s.host == k.host && s.session_id == k.session_id)
            })
            .map(|i| (i + 1) % list.len());
        list.get(idx.unwrap_or(0)).copied()
    }

    /// The live (not Ended) session running in `pane` on `host`, most recently updated first.
    /// Note: tmux pane ids are only unique per tmux server; with several sockets on one host
    /// the newest session wins.
    pub fn session_for_pane(&self, host: &str, pane: PaneId) -> Option<&AgentSession> {
        self.sessions
            .values()
            .filter(|s| {
                s.host == host && s.tmux_pane == Some(pane) && s.state != SessionState::Ended
            })
            .max_by_key(|s| s.updated_at)
    }

    pub fn badge_for_pane(&self, host: &str, pane: PaneId) -> Option<Badge> {
        self.session_for_pane(host, pane).and_then(|s| s.badge())
    }

    /// Highest-priority badge over all panes of `window` (looked up in `topology`).
    pub fn badge_for_window(
        &self,
        host: &str,
        topology: &TmuxTopology,
        window: WindowId,
    ) -> Option<Badge> {
        topology
            .sessions
            .iter()
            .flat_map(|s| &s.windows)
            .filter(|w| w.id == window)
            .flat_map(|w| &w.panes)
            .filter_map(|p| self.badge_for_pane(host, p.id))
            .max()
    }
}
