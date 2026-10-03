//! Quoting for the three contexts a tmux argument can travel through.

fn is_safe(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | ':' | '@' | '%' | '+' | ',')
}

fn all_safe(s: &str) -> bool {
    !s.is_empty() && s.chars().all(is_safe)
}

/// Quote for a POSIX shell (the SSH exec channel runs the user's login shell).
///
/// Safe words pass through; everything else is single-quoted with `'` as `'\''`.
pub fn shell_quote(s: &str) -> String {
    if all_safe(s) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

/// Quote for tmux's own command parser (control-mode stdin lines, `source-file`).
///
/// Uses double quotes with `\\ \" \$` escapes, `\n`/`\t`/`\r` and `\ooo` for other
/// control bytes, so the result never contains a raw control character (a raw newline
/// would end the command; `;` is only special outside quotes).
pub fn tmux_quote(s: &str) -> String {
    if all_safe(s) {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' | '"' | '$' => {
                out.push('\\');
                out.push(c);
            }
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                out.push_str(&format!("\\{:03o}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Escape `#` as `##` so tmux does not format-expand a name/path argument
/// (`new-session -s`, `new-window -n/-c`, `rename-window`, `split-window -c` all expand).
pub fn escape_format(s: &str) -> String {
    s.replace('#', "##")
}
