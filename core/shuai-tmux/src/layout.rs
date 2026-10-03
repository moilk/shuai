//! Parser for tmux layout strings (`csum,WxH,X,Y{...}` / `[...]` / `,pane`).
//!
//! Only the classic format is handled; tmux 3.8 sends it unless the client opts into
//! the new JSON layouts.

use std::fmt;

use crate::ids::PaneId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutKind {
    Pane(PaneId),
    /// `{a,b}`: children side by side.
    LeftRight(Vec<LayoutNode>),
    /// `[a,b]`: children stacked.
    TopBottom(Vec<LayoutNode>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutNode {
    pub width: u32,
    pub height: u32,
    pub x: u32,
    pub y: u32,
    pub kind: LayoutKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Layout {
    /// The 4-hex-digit checksum as sent.
    pub checksum: String,
    pub root: LayoutNode,
    /// The text after `csum,` as sent (what the checksum covers).
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutError(pub String);

impl fmt::Display for LayoutError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid layout: {}", self.0)
    }
}
impl std::error::Error for LayoutError {}

fn err<T>(m: &str) -> Result<T, LayoutError> {
    Err(LayoutError(m.to_string()))
}

struct Cursor<'a> {
    b: &'a [u8],
    i: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }
    fn eat(&mut self, c: u8) -> Result<(), LayoutError> {
        if self.peek() == Some(c) {
            self.i += 1;
            Ok(())
        } else {
            err(&format!("expected {:?} at {}", c as char, self.i))
        }
    }
    fn num(&mut self) -> Result<u32, LayoutError> {
        let start = self.i;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.i += 1;
        }
        std::str::from_utf8(&self.b[start..self.i])
            .ok()
            .and_then(|s| s.parse().ok())
            .map_or_else(|| err(&format!("expected number at {start}")), Ok)
    }
    fn node(&mut self) -> Result<LayoutNode, LayoutError> {
        let width = self.num()?;
        self.eat(b'x')?;
        let height = self.num()?;
        self.eat(b',')?;
        let x = self.num()?;
        self.eat(b',')?;
        let y = self.num()?;
        let kind = match self.peek() {
            Some(b',') => {
                self.i += 1;
                LayoutKind::Pane(PaneId(self.num()?))
            }
            Some(open @ (b'{' | b'[')) => {
                self.i += 1;
                let close = if open == b'{' { b'}' } else { b']' };
                let mut kids = vec![self.node()?];
                while self.peek() == Some(b',') {
                    self.i += 1;
                    kids.push(self.node()?);
                }
                self.eat(close)?;
                if open == b'{' {
                    LayoutKind::LeftRight(kids)
                } else {
                    LayoutKind::TopBottom(kids)
                }
            }
            _ => return err(&format!("expected pane id or children at {}", self.i)),
        };
        Ok(LayoutNode {
            width,
            height,
            x,
            y,
            kind,
        })
    }
}

impl LayoutNode {
    fn collect(&self, out: &mut Vec<PaneId>) {
        match &self.kind {
            LayoutKind::Pane(p) => out.push(*p),
            LayoutKind::LeftRight(k) | LayoutKind::TopBottom(k) => {
                k.iter().for_each(|n| n.collect(out))
            }
        }
    }
}

impl Layout {
    pub fn parse(s: &str) -> Result<Layout, LayoutError> {
        let Some((csum, body)) = s.split_once(',') else {
            return err("missing checksum");
        };
        if csum.len() != 4 || !csum.bytes().all(|b| b.is_ascii_hexdigit()) {
            return err("bad checksum");
        }
        let mut c = Cursor {
            b: body.as_bytes(),
            i: 0,
        };
        let root = c.node()?;
        if c.i != body.len() {
            return err(&format!("trailing data at {}", c.i));
        }
        Ok(Layout {
            checksum: csum.to_string(),
            root,
            body: body.to_string(),
        })
    }
    /// Does the checksum match the body (tmux `layout_checksum`)?
    pub fn checksum_ok(&self) -> bool {
        u16::from_str_radix(&self.checksum, 16).is_ok_and(|c| c == checksum(&self.body))
    }
    /// All pane ids, depth first.
    pub fn pane_ids(&self) -> Vec<PaneId> {
        let mut v = vec![];
        self.root.collect(&mut v);
        v
    }
}

/// tmux's layout checksum of `body` (everything after the `csum,`).
pub fn checksum(body: &str) -> u16 {
    body.bytes().fold(0u16, |c, b| {
        (c >> 1)
            .wrapping_add((c & 1) << 15)
            .wrapping_add(u16::from(b))
    })
}
