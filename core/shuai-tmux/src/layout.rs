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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutError(pub String);

impl fmt::Display for LayoutError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid layout: {}", self.0)
    }
}
impl std::error::Error for LayoutError {}

impl Layout {
    pub fn parse(_s: &str) -> Result<Layout, LayoutError> {
        todo!()
    }
    /// Does the checksum match the body (tmux `layout_checksum`)?
    pub fn checksum_ok(&self) -> bool {
        todo!()
    }
    /// All pane ids, depth first.
    pub fn pane_ids(&self) -> Vec<PaneId> {
        todo!()
    }
}

/// tmux's layout checksum of `body` (everything after the `csum,`).
pub fn checksum(_body: &str) -> u16 {
    todo!()
}
