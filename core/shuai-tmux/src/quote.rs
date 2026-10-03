//! Quoting for the three contexts a tmux argument can travel through.

/// Quote for a POSIX shell (the SSH exec channel runs the user's login shell).
pub fn shell_quote(_s: &str) -> String {
    todo!()
}

/// Quote for tmux's own command parser (control-mode stdin lines, `source-file`).
pub fn tmux_quote(_s: &str) -> String {
    todo!()
}

/// Escape `#` as `##` so tmux does not format-expand a name/path argument.
pub fn escape_format(_s: &str) -> String {
    todo!()
}
