//! Push notifications through an ntfy server.

use crate::state::{Ntfy, Result, State, hostname};
use shuai_proto::{AgentEvent, Envelope};
use std::time::Duration;

#[derive(Debug, Default, Clone)]
pub struct Message<'a> {
    pub title: &'a str,
    pub body: &'a str,
    pub click: Option<&'a str>,
    pub priority: Option<&'a str>,
    pub tags: Option<&'a str>,
}

pub fn send(cfg: &Ntfy, m: &Message) -> Result<()> {
    let url = format!("{}/{}", cfg.server.trim_end_matches('/'), cfg.topic);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(5)))
        .build()
        .into();
    let mut req = agent.post(&url).header("Title", m.title);
    if let Some(c) = m.click {
        req = req.header("Click", c);
    }
    if let Some(p) = m.priority {
        req = req.header("Priority", p);
    }
    if let Some(t) = m.tags {
        req = req.header("Tags", t);
    }
    if let Some(tok) = &cfg.token {
        req = req.header("Authorization", format!("Bearer {tok}"));
    }
    req.send(m.body)?;
    Ok(())
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(max).collect();
        t.push('…');
        t
    }
}

/// Deep link back to the pane: `shuai://host/<host_id>/pane/<%N>`.
pub fn click_url(state: &State, env: &Envelope) -> Option<String> {
    let pane = &env.tmux.as_ref()?.pane;
    let host = state.config().host_id.unwrap_or_else(hostname);
    Some(format!(
        "shuai://host/{}/pane/{}",
        percent_encode(&host),
        percent_encode(pane)
    ))
}

/// Push a notification for "attention worthy" events when ntfy is configured and no app is
/// watching. Failures are logged, never returned.
pub fn maybe_push(state: &State, env: &Envelope) {
    let cfg = state.config();
    let Some(ntfy) = cfg.ntfy else { return };
    if state.present() {
        return;
    }
    let (title, body, priority, tags): (&str, String, &str, &str) = match &env.event {
        AgentEvent::Notification {
            notification_type,
            message,
            ..
        } => {
            let msg = message.clone().unwrap_or_default();
            match notification_type.as_deref() {
                Some("permission_prompt") => ("Claude needs approval", msg, "high", "warning"),
                Some("idle_prompt") => ("Claude is waiting for you", msg, "default", "hourglass"),
                _ => return,
            }
        }
        AgentEvent::Stop {
            last_assistant_message,
            ctx,
            ..
        } if ctx.agent_id.is_none() => (
            "Claude finished",
            last_assistant_message
                .clone()
                .unwrap_or_else(|| "Done".into()),
            "default",
            "white_check_mark",
        ),
        AgentEvent::AgentTurnComplete {
            last_assistant_message,
            ..
        } => (
            "Codex finished",
            last_assistant_message
                .clone()
                .unwrap_or_else(|| "Done".into()),
            "default",
            "white_check_mark",
        ),
        _ => return,
    };
    let click = click_url(state, env);
    let body = clip(&body, 300);
    let m = Message {
        title,
        body: &body,
        click: click.as_deref(),
        priority: Some(priority),
        tags: Some(tags),
    };
    if let Err(e) = send(&ntfy, &m) {
        state.log(&format!("ntfy push failed: {e}"));
    }
}
