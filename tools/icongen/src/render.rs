//! SVG rasterisation through resvg.

use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg::{Options, Tree};

/// Renders `svg` scaled to a square `px` x `px` pixmap (transparent where nothing is drawn).
pub fn render(svg: &str, px: u32) -> Result<Pixmap, String> {
    let tree = Tree::from_str(svg, &Options::default()).map_err(|e| e.to_string())?;
    let mut pix = Pixmap::new(px, px).ok_or("invalid pixmap size")?;
    let size = tree.size();
    let t = Transform::from_scale(px as f32 / size.width(), px as f32 / size.height());
    resvg::render(&tree, t, &mut pix.as_mut());
    Ok(pix)
}
