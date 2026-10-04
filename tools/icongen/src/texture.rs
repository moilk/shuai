//! Oracle-texture layer (grain, cracks, margin motifs). Filled in by the texture task.

use crate::config::TextureCfg;
use crate::glyph::MarkBounds;

/// SVG fragment (elements only, no `<svg>` wrapper) for the texture layer on a `size` px canvas.
/// Empty when the texture is disabled. Must be deterministic for a given config.
pub fn layer_svg(cfg: &TextureCfg, _mark: &MarkBounds, _size: u32) -> String {
    if !cfg.enabled {
        return String::new();
    }
    String::from("<g id=\"texture\"/>")
}
