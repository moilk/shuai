//! shuai-tmux: pure, I/O-free (sans-io) tmux helpers.
//!
//! * [`cmd`] builds safely quoted tmux commands (argv / shell string / control-mode line).
//! * [`parse`] and [`topology`] parse fixed-format `list-*` output into a typed tree and diff it.
//! * [`control`] is an incremental parser for the `tmux -C` / `-CC` line protocol.
//! * [`layout`] parses tmux layout strings (`%layout-change`).
//! * [`version`] parses `tmux -V` and maps versions to capabilities.

pub mod clients;
pub mod cmd;
pub mod control;
pub mod controller;
pub mod ids;
pub mod layout;
pub mod parse;
pub mod quote;
pub mod topology;
pub mod version;

pub use cmd::{Direction, Target, TmuxCommand};
pub use control::{CommandReply, ControlEvent, ControlParser};
pub use ids::{PaneId, SessionId, WindowId};
pub use layout::{Layout, LayoutKind, LayoutNode};
pub use parse::ParseError;
pub use topology::{TmuxPane, TmuxSession, TmuxTopology, TmuxWindow, TopologyChange};
pub use version::{Capabilities, TmuxVersion};
