//! Sans-io parser for the tmux control-mode (`-C` / `-CC`) protocol.

use std::collections::VecDeque;

use crate::ids::{PaneId, SessionId, WindowId};
use crate::layout::Layout;

/// A completed command reply block (`%begin` ... `%end` / `%error`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandReply {
    pub time: u64,
    /// tmux's command number.
    pub number: u64,
    pub flags: u32,
    /// `%end` -> true, `%error` -> false.
    pub ok: bool,
    /// Body lines (lossy UTF-8, without line terminators).
    pub lines: Vec<String>,
    /// Token registered with [`ControlParser::expect_reply`], if this reply answers a
    /// command sent by us (flags bit 0). Server-originated blocks (e.g. the one printed
    /// on attach) have `None`.
    pub token: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    Reply(CommandReply),
    Output {
        pane: PaneId,
        data: Vec<u8>,
    },
    ExtendedOutput {
        pane: PaneId,
        age_ms: u64,
        data: Vec<u8>,
    },
    WindowAdd {
        window: WindowId,
    },
    WindowClose {
        window: WindowId,
    },
    UnlinkedWindowAdd {
        window: WindowId,
    },
    UnlinkedWindowClose {
        window: WindowId,
    },
    WindowRenamed {
        window: WindowId,
        name: String,
    },
    UnlinkedWindowRenamed {
        window: WindowId,
        name: String,
    },
    WindowPaneChanged {
        window: WindowId,
        pane: PaneId,
    },
    SessionChanged {
        session: SessionId,
        name: String,
    },
    /// tmux >= 3.? includes the id; older versions only the name.
    SessionRenamed {
        session: Option<SessionId>,
        name: String,
    },
    SessionsChanged,
    SessionWindowChanged {
        session: SessionId,
        window: WindowId,
    },
    LayoutChange {
        window: WindowId,
        /// Raw layout string as sent.
        layout: String,
        visible_layout: Option<String>,
        flags: Option<String>,
        /// `layout` parsed; `None` if it did not parse.
        parsed: Option<Layout>,
    },
    PaneModeChanged {
        pane: PaneId,
    },
    ClientSessionChanged {
        client: String,
        session: SessionId,
        name: String,
    },
    ClientDetached {
        client: String,
    },
    Pause {
        pane: PaneId,
    },
    Continue {
        pane: PaneId,
    },
    SubscriptionChanged {
        name: String,
        session: Option<SessionId>,
        window: Option<WindowId>,
        window_index: Option<u32>,
        pane: Option<PaneId>,
        value: String,
    },
    Exit {
        reason: Option<String>,
    },
    /// Anything we do not recognise (forward compatible), without terminator.
    Unknown(String),
}

const DCS_START: &[u8] = b"\x1bP1000p";
const DCS_END: &[u8] = b"\x1b\\";

#[derive(Debug)]
struct Block {
    /// The `time number flags` text after `%begin `, matched verbatim by `%end`/`%error`.
    header: String,
    time: u64,
    number: u64,
    flags: u32,
    lines: Vec<String>,
}

/// Incremental control-mode parser. Feed it whatever bytes arrive from the channel.
#[derive(Debug, Default)]
pub struct ControlParser {
    buf: Vec<u8>,
    block: Option<Block>,
    tokens: VecDeque<u64>,
}

impl ControlParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register that a command was sent; replies with flags bit 0 are matched FIFO.
    pub fn expect_reply(&mut self, token: u64) {
        self.tokens.push_back(token);
    }

    /// Feed bytes; returns every event completed by them. Incomplete trailing lines are
    /// buffered until their newline arrives.
    pub fn push(&mut self, data: &[u8]) -> Vec<ControlEvent> {
        self.buf.extend_from_slice(data);
        let mut events = vec![];
        let mut start = 0;
        while let Some(off) = self.buf[start..].iter().position(|&b| b == b'\n') {
            let end = start + off;
            let mut line = self.buf[start..end].to_vec();
            start = end + 1;
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            self.line(&line, &mut events);
        }
        self.buf.drain(..start);
        events
    }

    fn line(&mut self, raw: &[u8], events: &mut Vec<ControlEvent>) {
        if let Some(block) = &mut self.block {
            let text = String::from_utf8_lossy(raw);
            let closes = |kw: &str| {
                text.strip_prefix(kw)
                    .and_then(|r| r.strip_prefix(' '))
                    .is_some_and(|r| r == block.header)
            };
            let ok = if closes("%end") {
                Some(true)
            } else if closes("%error") {
                Some(false)
            } else {
                None
            };
            match ok {
                None => block.lines.push(text.into_owned()),
                Some(ok) => {
                    let b = self.block.take().expect("block is open");
                    let token = if b.flags & 1 == 1 {
                        self.tokens.pop_front()
                    } else {
                        None
                    };
                    events.push(ControlEvent::Reply(CommandReply {
                        time: b.time,
                        number: b.number,
                        flags: b.flags,
                        ok,
                        lines: b.lines,
                        token,
                    }));
                }
            }
            return;
        }
        let mut line = raw;
        // -CC wrapper: DCS introducer before the first line, ST after %exit.
        while let Some(r) = line
            .strip_prefix(DCS_START)
            .or_else(|| line.strip_prefix(DCS_END))
        {
            line = r;
        }
        if line.is_empty() {
            return;
        }
        if let Some(ev) = self.notification(line) {
            events.push(ev);
        } else if let Some(b) = Self::begin(line) {
            self.block = Some(b);
        } else {
            events.push(ControlEvent::Unknown(
                String::from_utf8_lossy(line).into_owned(),
            ));
        }
    }

    fn begin(line: &[u8]) -> Option<Block> {
        let text = std::str::from_utf8(line).ok()?;
        let header = text.strip_prefix("%begin ")?;
        let mut it = header.split(' ');
        let (time, number, flags) = (
            it.next()?.parse().ok()?,
            it.next()?.parse().ok()?,
            it.next()?.parse().ok()?,
        );
        if it.next().is_some() {
            return None;
        }
        Some(Block {
            header: header.to_string(),
            time,
            number,
            flags,
            lines: vec![],
        })
    }

    /// Parse one notification line; `None` if it is not a (well-formed) notification.
    fn notification(&self, line: &[u8]) -> Option<ControlEvent> {
        if let Some(rest) = line.strip_prefix(b"%output ") {
            let (pane, data) = split_pane(rest)?;
            return Some(ControlEvent::Output {
                pane,
                data: decode_output(data),
            });
        }
        if let Some(rest) = line.strip_prefix(b"%extended-output ") {
            let sep = rest.windows(3).position(|w| w == b" : ")?;
            let head = std::str::from_utf8(&rest[..sep]).ok()?;
            let mut it = head.split(' ');
            let pane = it.next()?.parse().ok()?;
            let age_ms = it.next()?.parse().ok()?;
            return Some(ControlEvent::ExtendedOutput {
                pane,
                age_ms,
                data: decode_output(&rest[sep + 3..]),
            });
        }
        let text = std::str::from_utf8(line).ok()?;
        let (name, rest) = match text.split_once(' ') {
            Some((n, r)) => (n, r),
            None => (text, ""),
        };
        let mut it = rest.split(' ').filter(|s| !s.is_empty());
        use ControlEvent as E;
        Some(match name {
            "%window-add" => E::WindowAdd {
                window: it.next()?.parse().ok()?,
            },
            "%window-close" => E::WindowClose {
                window: it.next()?.parse().ok()?,
            },
            "%unlinked-window-add" => E::UnlinkedWindowAdd {
                window: it.next()?.parse().ok()?,
            },
            "%unlinked-window-close" => E::UnlinkedWindowClose {
                window: it.next()?.parse().ok()?,
            },
            "%window-renamed" | "%unlinked-window-renamed" => {
                let (w, n) = rest.split_once(' ').unwrap_or((rest, ""));
                let window = w.parse().ok()?;
                let name = n.to_string();
                if text.starts_with("%window") {
                    E::WindowRenamed { window, name }
                } else {
                    E::UnlinkedWindowRenamed { window, name }
                }
            }
            "%window-pane-changed" => E::WindowPaneChanged {
                window: it.next()?.parse().ok()?,
                pane: it.next()?.parse().ok()?,
            },
            "%session-changed" => {
                let (s, n) = rest.split_once(' ')?;
                E::SessionChanged {
                    session: s.parse().ok()?,
                    name: n.to_string(),
                }
            }
            "%session-renamed" => match rest.split_once(' ') {
                Some((s, n)) if s.parse::<SessionId>().is_ok() => E::SessionRenamed {
                    session: s.parse().ok(),
                    name: n.to_string(),
                },
                _ => E::SessionRenamed {
                    session: None,
                    name: rest.to_string(),
                },
            },
            "%sessions-changed" => E::SessionsChanged,
            "%session-window-changed" => E::SessionWindowChanged {
                session: it.next()?.parse().ok()?,
                window: it.next()?.parse().ok()?,
            },
            "%layout-change" => {
                let window = it.next()?.parse().ok()?;
                let layout = it.next()?.to_string();
                let visible_layout = it.next().map(str::to_string);
                let flags = it.next().map(str::to_string);
                let parsed = Layout::parse(&layout).ok();
                E::LayoutChange {
                    window,
                    layout,
                    visible_layout,
                    flags,
                    parsed,
                }
            }
            "%pane-mode-changed" => E::PaneModeChanged {
                pane: it.next()?.parse().ok()?,
            },
            "%client-session-changed" => {
                let mut p = rest.splitn(3, ' ');
                E::ClientSessionChanged {
                    client: p.next()?.to_string(),
                    session: p.next()?.parse().ok()?,
                    name: p.next()?.to_string(),
                }
            }
            "%client-detached" => E::ClientDetached {
                client: rest.to_string(),
            },
            "%pause" => E::Pause {
                pane: it.next()?.parse().ok()?,
            },
            "%continue" => E::Continue {
                pane: it.next()?.parse().ok()?,
            },
            "%subscription-changed" => {
                let (head, value) = rest.split_once(" : ")?;
                let t: Vec<&str> = head.split(' ').collect();
                if t.len() != 5 {
                    return None;
                }
                fn opt(s: &str) -> Option<&str> {
                    (s != "-").then_some(s)
                }
                E::SubscriptionChanged {
                    name: t[0].to_string(),
                    session: opt(t[1]).and_then(|s| s.parse().ok()),
                    window: opt(t[2]).and_then(|s| s.parse().ok()),
                    window_index: opt(t[3]).and_then(|s| s.parse().ok()),
                    pane: opt(t[4]).and_then(|s| s.parse().ok()),
                    value: value.to_string(),
                }
            }
            "%exit" => E::Exit {
                reason: (!rest.is_empty()).then(|| rest.to_string()),
            },
            _ => return None,
        })
    }
}

/// Split `%N payload` where the payload follows exactly one space (or is absent).
fn split_pane(rest: &[u8]) -> Option<(PaneId, &[u8])> {
    let (id, data) = match rest.iter().position(|&b| b == b' ') {
        Some(i) => (&rest[..i], &rest[i + 1..]),
        None => (rest, &rest[rest.len()..]),
    };
    Some((std::str::from_utf8(id).ok()?.parse().ok()?, data))
}

/// Decode tmux `%output` payload escapes (`\ooo` -> byte). Malformed escapes are kept.
pub fn decode_output(s: &[u8]) -> Vec<u8> {
    let oct = |b: u8| (b'0'..=b'7').contains(&b);
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'\\' && s.len() - i >= 4 && s[i + 1..i + 4].iter().all(|&b| oct(b)) {
            let v = u32::from(s[i + 1] - b'0') * 64
                + u32::from(s[i + 2] - b'0') * 8
                + u32::from(s[i + 3] - b'0');
            out.push(v as u8);
            i += 4;
            continue;
        }
        out.push(s[i]);
        i += 1;
    }
    out
}
