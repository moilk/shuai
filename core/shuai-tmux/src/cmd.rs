//! Typed tmux command builder.

use crate::ids::{PaneId, SessionId, WindowId};

/// ASCII unit separator used between `-F` fields. tmux passes literal bytes of the
/// format string through untouched while escaping control characters found in *data*
/// (names, titles, paths) as `\ooo`, so this byte never occurs inside a field.
pub const FIELD_SEP: char = '\u{1f}';

/// Format for `list-sessions -F`.
pub const SESSION_FORMAT: &str = "";
/// Format for `list-windows -a -F`.
pub const WINDOW_FORMAT: &str = "";
/// Format for `list-panes -a -F` (carries the whole tree).
pub const PANE_FORMAT: &str = "";

/// A tmux command: name plus arguments, unquoted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxCommand {
    args: Vec<String>,
}

impl TmuxCommand {
    /// Raw arguments (`["new-window", "-t", ...]`), for `exec`-style callers.
    pub fn argv(&self) -> &[String] {
        &self.args
    }
    /// Full shell command line starting with `tmux` (for an SSH exec channel).
    pub fn to_shell(&self) -> String {
        todo!()
    }
    /// One control-mode stdin line (no trailing newline), quoted for tmux's parser.
    pub fn to_control_line(&self) -> String {
        todo!()
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
    pub fn session(_name: &str) -> Self {
        todo!()
    }
    /// Session by id.
    pub fn session_id(_id: SessionId) -> Self {
        todo!()
    }
    /// Window by index inside a named session (`=name:3`).
    pub fn window_index(_session: &str, _index: u32) -> Self {
        todo!()
    }
    pub fn window(_id: WindowId) -> Self {
        todo!()
    }
    pub fn pane(_id: PaneId) -> Self {
        todo!()
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
    todo!()
}
pub fn new_session_attach(
    _name: &str,
    _size: Option<(u32, u32)>,
    _cwd: Option<&str>,
) -> TmuxCommand {
    todo!()
}
pub fn attach_session(_name: &str) -> TmuxCommand {
    todo!()
}
/// `tmux -C attach -t =name:` (the notification side channel).
pub fn control_attach(_name: &str, _double_c: bool) -> TmuxCommand {
    todo!()
}
pub fn list_sessions() -> TmuxCommand {
    todo!()
}
pub fn list_windows_all() -> TmuxCommand {
    todo!()
}
pub fn list_panes_all() -> TmuxCommand {
    todo!()
}
pub fn select_window(_t: &Target) -> TmuxCommand {
    todo!()
}
pub fn select_pane(_t: &Target) -> TmuxCommand {
    todo!()
}
pub fn new_window(_session: &Target, _cwd: Option<&str>, _name: Option<&str>) -> TmuxCommand {
    todo!()
}
pub fn kill_window(_t: &Target) -> TmuxCommand {
    todo!()
}
pub fn kill_session(_t: &Target) -> TmuxCommand {
    todo!()
}
pub fn rename_window(_t: &Target, _name: &str) -> TmuxCommand {
    todo!()
}
pub fn split_window(_t: &Target, _dir: Direction, _cwd: Option<&str>) -> TmuxCommand {
    todo!()
}
/// `send-keys -t T -l -- TEXT`.
pub fn send_keys_literal(_t: &Target, _text: &str) -> TmuxCommand {
    todo!()
}
/// `send-keys -t T KEY...` with tmux key names (`Enter`, `C-c`, `Up`...). Names are validated.
pub fn send_keys_named(_t: &Target, _keys: &[&str]) -> Result<TmuxCommand, String> {
    todo!()
}
pub fn resize_window(_t: &Target, _cols: u32, _rows: u32) -> TmuxCommand {
    todo!()
}
/// `capture-pane -p -e -J -t T [-S -N]`: `scrollback_lines` of history above the screen.
pub fn capture_pane(_t: &Target, _scrollback_lines: Option<u32>) -> TmuxCommand {
    todo!()
}
/// `refresh-client -C WxH` (control mode client size).
pub fn refresh_client_size(_cols: u32, _rows: u32) -> TmuxCommand {
    todo!()
}
