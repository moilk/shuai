//! Typed tmux command builder.

use crate::ids::{PaneId, SessionId, WindowId};
use crate::quote::{escape_format, shell_quote, tmux_quote};

/// ASCII unit separator used between `-F` fields. tmux passes literal bytes of the
/// format string through untouched while escaping control characters found in *data*
/// (names, titles, paths) as `\ooo` (verified on tmux 3.6), so this byte never occurs
/// inside a field. Tab would not do: it can appear raw in window names.
pub const FIELD_SEP: char = '\u{1f}';

/// Format for `list-sessions -F`.
pub const SESSION_FORMAT: &str = "#{session_id}\u{1f}#{session_name}\u{1f}#{session_attached}";
/// Format for `list-windows -a -F`.
pub const WINDOW_FORMAT: &str = "#{session_id}\u{1f}#{window_id}\u{1f}#{window_index}\u{1f}#{window_name}\u{1f}#{window_active}\u{1f}#{window_flags}";
/// Format for `list-panes -a -F` (carries the whole tree).
pub const PANE_FORMAT: &str = "#{session_id}\u{1f}#{session_name}\u{1f}#{session_attached}\u{1f}#{window_id}\u{1f}#{window_index}\u{1f}#{window_name}\u{1f}#{window_active}\u{1f}#{window_flags}\u{1f}#{pane_id}\u{1f}#{pane_index}\u{1f}#{pane_active}\u{1f}#{pane_current_command}\u{1f}#{pane_current_path}\u{1f}#{pane_pid}\u{1f}#{pane_tty}\u{1f}#{pane_title}\u{1f}#{pane_width}\u{1f}#{pane_height}";

/// A tmux command: name plus arguments, unquoted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxCommand {
    args: Vec<String>,
}

impl TmuxCommand {
    fn new<I, S>(args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            args: args.into_iter().map(Into::into).collect(),
        }
    }
    fn arg(mut self, a: impl Into<String>) -> Self {
        self.args.push(a.into());
        self
    }
    fn opt(self, flag: &str, v: Option<&str>) -> Self {
        match v {
            Some(v) => self.arg(flag).arg(escape_format(v)),
            None => self,
        }
    }
    fn target(self, t: &Target) -> Self {
        self.arg("-t").arg(t.0.clone())
    }

    /// Raw arguments (`["new-window", "-t", ...]`), for `exec`-style callers.
    pub fn argv(&self) -> &[String] {
        &self.args
    }
    /// Full shell command line starting with `tmux` (for an SSH exec channel).
    pub fn to_shell(&self) -> String {
        let mut out = String::from("tmux");
        for a in &self.args {
            out.push(' ');
            out.push_str(&shell_quote(a));
        }
        out
    }
    /// One control-mode stdin line (no trailing newline), quoted for tmux's parser.
    pub fn to_control_line(&self) -> String {
        self.args
            .iter()
            .map(|a| tmux_quote(a))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// A tmux target (`-t` argument), always built so that it is exact, never a prefix match.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target(String);

impl Target {
    pub fn as_str(&self) -> &str {
        &self.0
    }
    /// Session by exact name (`=name:`).
    pub fn session(name: &str) -> Self {
        Target(format!("={name}:"))
    }
    /// Session by id.
    pub fn session_id(id: SessionId) -> Self {
        Target(id.to_string())
    }
    /// Window by index inside a named session (`=name:3`).
    pub fn window_index(session: &str, index: u32) -> Self {
        Target(format!("={session}:{index}"))
    }
    pub fn window(id: WindowId) -> Self {
        Target(id.to_string())
    }
    pub fn pane(id: PaneId) -> Self {
        Target(id.to_string())
    }
}

/// Split direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Panes side by side (`-h`).
    Horizontal,
    /// Panes stacked (`-v`).
    Vertical,
}

pub fn tmux_version() -> TmuxCommand {
    TmuxCommand::new(["-V"])
}

/// `new-session -A -s NAME [-x W -y H] [-c CWD]`. Note tmux itself rewrites `.` and `:`
/// in session names to `_`.
pub fn new_session_attach(name: &str, size: Option<(u32, u32)>, cwd: Option<&str>) -> TmuxCommand {
    let mut c = TmuxCommand::new(["new-session", "-A", "-s"]).arg(escape_format(name));
    if let Some((w, h)) = size {
        c = c.arg("-x").arg(w.to_string()).arg("-y").arg(h.to_string());
    }
    c.opt("-c", cwd)
}

pub fn attach_session(name: &str) -> TmuxCommand {
    TmuxCommand::new(["attach-session"]).target(&Target::session(name))
}

/// `tmux -C attach -t =name:` (the notification side channel).
pub fn control_attach(name: &str, double_c: bool) -> TmuxCommand {
    TmuxCommand::new([if double_c { "-CC" } else { "-C" }, "attach-session"])
        .target(&Target::session(name))
}

pub fn list_sessions() -> TmuxCommand {
    TmuxCommand::new(["list-sessions", "-F", SESSION_FORMAT])
}
pub fn list_windows_all() -> TmuxCommand {
    TmuxCommand::new(["list-windows", "-a", "-F", WINDOW_FORMAT])
}
pub fn list_panes_all() -> TmuxCommand {
    TmuxCommand::new(["list-panes", "-a", "-F", PANE_FORMAT])
}

pub fn select_window(t: &Target) -> TmuxCommand {
    TmuxCommand::new(["select-window"]).target(t)
}
pub fn select_pane(t: &Target) -> TmuxCommand {
    TmuxCommand::new(["select-pane"]).target(t)
}
pub fn new_window(session: &Target, cwd: Option<&str>, name: Option<&str>) -> TmuxCommand {
    TmuxCommand::new(["new-window"])
        .target(session)
        .opt("-c", cwd)
        .opt("-n", name)
}
pub fn kill_window(t: &Target) -> TmuxCommand {
    TmuxCommand::new(["kill-window"]).target(t)
}
pub fn kill_session(t: &Target) -> TmuxCommand {
    TmuxCommand::new(["kill-session"]).target(t)
}
pub fn rename_window(t: &Target, name: &str) -> TmuxCommand {
    // `--` so a name starting with `-` is not parsed as a flag.
    TmuxCommand::new(["rename-window"])
        .target(t)
        .arg("--")
        .arg(escape_format(name))
}
pub fn split_window(t: &Target, dir: Direction, cwd: Option<&str>) -> TmuxCommand {
    let flag = match dir {
        Direction::Horizontal => "-h",
        Direction::Vertical => "-v",
    };
    TmuxCommand::new(["split-window", flag])
        .target(t)
        .opt("-c", cwd)
}
/// `send-keys -t T -l -- TEXT`.
pub fn send_keys_literal(t: &Target, text: &str) -> TmuxCommand {
    TmuxCommand::new(["send-keys"])
        .target(t)
        .arg("-l")
        .arg("--")
        .arg(text)
}
/// `send-keys -t T KEY...` with tmux key names (`Enter`, `C-c`, `Up`...). Names are validated.
pub fn send_keys_named(t: &Target, keys: &[&str]) -> Result<TmuxCommand, String> {
    let mut c = TmuxCommand::new(["send-keys"]).target(t);
    for k in keys {
        let bad = k.is_empty()
            || (k.len() > 1 && k.starts_with('-'))
            || k.chars()
                .any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '\'');
        if bad {
            return Err(format!("invalid key name: {k:?}"));
        }
        c = c.arg(*k);
    }
    Ok(c)
}
pub fn resize_window(t: &Target, cols: u32, rows: u32) -> TmuxCommand {
    TmuxCommand::new(["resize-window"])
        .target(t)
        .arg("-x")
        .arg(cols.to_string())
        .arg("-y")
        .arg(rows.to_string())
}
/// `capture-pane -p -e -J -t T [-S -N]`: `scrollback_lines` of history above the screen.
pub fn capture_pane(t: &Target, scrollback_lines: Option<u32>) -> TmuxCommand {
    let c = TmuxCommand::new(["capture-pane", "-p", "-e", "-J"]).target(t);
    match scrollback_lines {
        Some(n) => c.arg("-S").arg(format!("-{n}")),
        None => c,
    }
}
/// `refresh-client -C WxH` (control mode client size).
pub fn refresh_client_size(cols: u32, rows: u32) -> TmuxCommand {
    TmuxCommand::new(["refresh-client", "-C"]).arg(format!("{cols}x{rows}"))
}

/// `refresh-client -f|-F FLAGS` (used by [`crate::version`]).
pub(crate) fn refresh_client_flags(flag: &str, flags: &str) -> TmuxCommand {
    TmuxCommand::new(["refresh-client", flag, flags])
}
