//! Typed tmux object ids (`$0`, `@1`, `%2`).

use std::fmt;
use std::str::FromStr;

/// Error parsing an id such as `@12`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseIdError(pub String);

impl fmt::Display for ParseIdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid tmux id: {:?}", self.0)
    }
}

impl std::error::Error for ParseIdError {}

macro_rules! id_type {
    ($(#[$m:meta])* $name:ident, $sigil:literal) => {
        $(#[$m])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(pub u32);

        impl fmt::Display for $name {
            fn fmt(&self, _f: &mut fmt::Formatter<'_>) -> fmt::Result {
                todo!()
            }
        }

        impl FromStr for $name {
            type Err = ParseIdError;
            fn from_str(_s: &str) -> Result<Self, Self::Err> {
                todo!()
            }
        }
    };
}

id_type!(/// Session id, `$N`.
    SessionId, "$");
id_type!(/// Window id, `@N`.
    WindowId, "@");
id_type!(/// Pane id, `%N`.
    PaneId, "%");
