//! Deterministic app icon generator: TOML configs -> layered SVG -> opaque RGB PNG.

pub mod config;
pub mod fidelity;
pub mod glyph;
pub mod pipeline;
pub mod png_out;
pub mod render;
pub mod rng;
pub mod svg;
pub mod texture;
