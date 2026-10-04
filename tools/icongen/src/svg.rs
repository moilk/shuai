//! Layered SVG output: base, texture, mark, gloss, container and their composite.
//! Numbers use fixed precision so the text is identical on every run.

use crate::config::{BackgroundKind, ThemeCfg};
use crate::glyph::{Glyph, MarkBounds, Pt, contour_path};
use crate::texture;

/// Fixed-precision number: 3 decimals, trailing zeros trimmed, never `-0` or exponent form.
pub fn fmt(v: f64) -> String {
    let mut s = format!("{v:.3}");
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
    if s == "-0" { "0".into() } else { s }
}

#[derive(Debug, Clone)]
pub struct Layers {
    pub base: String,
    pub texture: String,
    pub mark: String,
    pub gloss: String,
    pub container: String,
    pub composite: String,
    pub bounds: MarkBounds,
}

/// Glyph unit to canvas pixel mapping for the mark.
struct Placement {
    scale: f64,
    tx: f64,
    ty: f64,
}

impl Placement {
    fn map(&self, p: Pt) -> Pt {
        (p.0 * self.scale + self.tx, p.1 * self.scale + self.ty)
    }
}

fn place(theme: &ThemeCfg, glyph: &Glyph, size: u32) -> (Placement, MarkBounds) {
    let s = f64::from(size);
    let (x0, y0, x1, y1) = glyph.bounds(theme.mark.weight_at(size));
    let scale = theme.mark.scale * s / (x1 - x0).max(y1 - y0);
    let cx = s / 2.0 + theme.mark.offset[0] * s;
    let cy = s / 2.0 + theme.mark.offset[1] * s;
    let pl = Placement {
        scale,
        tx: cx - scale * (x0 + x1) / 2.0,
        ty: cy - scale * (y0 + y1) / 2.0,
    };
    let (a, b) = (pl.map((x0, y0)), pl.map((x1, y1)));
    let bounds = MarkBounds {
        x0: a.0,
        y0: a.1,
        x1: b.0,
        y1: b.1,
    };
    (pl, bounds)
}

fn doc(size: u32, body: &str) -> String {
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{size}\" height=\"{size}\" viewBox=\"0 0 {size} {size}\">{body}</svg>\n"
    )
}

fn base_fragment(theme: &ThemeCfg, size: u32) -> String {
    let bg = &theme.background;
    let s = f64::from(size);
    match (bg.kind, &bg.color2) {
        (BackgroundKind::Linear, Some(c2)) => {
            let (dx, dy) = (bg.angle.to_radians().cos(), bg.angle.to_radians().sin());
            format!(
                "<defs><linearGradient id=\"bg\" x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\"><stop offset=\"0\" stop-color=\"{}\"/><stop offset=\"1\" stop-color=\"{}\"/></linearGradient></defs><rect id=\"base\" width=\"{}\" height=\"{}\" fill=\"url(#bg)\"/>",
                fmt(0.5 - dx / 2.0),
                fmt(0.5 - dy / 2.0),
                fmt(0.5 + dx / 2.0),
                fmt(0.5 + dy / 2.0),
                bg.color,
                c2,
                fmt(s),
                fmt(s)
            )
        }
        _ => format!(
            "<rect id=\"base\" width=\"{}\" height=\"{}\" fill=\"{}\"/>",
            fmt(s),
            fmt(s),
            bg.color
        ),
    }
}

fn mark_fragment(theme: &ThemeCfg, glyph: &Glyph, pl: &Placement, size: u32) -> String {
    let map = |p: Pt| pl.map(p);
    let mut out = format!("<g id=\"mark\" fill=\"{}\">", theme.mark.fill);
    for piece in glyph.pieces_with(theme.mark.weight_at(size), theme.mark.hole_weight_at(size)) {
        let d: String = piece
            .contours
            .iter()
            .map(|c| contour_path(c, &map))
            .collect();
        let rule = if piece.even_odd {
            " fill-rule=\"evenodd\""
        } else {
            ""
        };
        out.push_str(&format!("<path id=\"{}\"{rule} d=\"{d}\"/>", piece.id));
    }
    out.push_str("</g>");
    out
}

fn gloss_fragment(theme: &ThemeCfg, size: u32) -> String {
    if !theme.gloss.enabled {
        return String::new();
    }
    let s = fmt(f64::from(size));
    format!(
        "<defs><linearGradient id=\"gloss-grad\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#ffffff\" stop-opacity=\"0.18\"/><stop offset=\"0.5\" stop-color=\"#ffffff\" stop-opacity=\"0\"/></linearGradient></defs><rect id=\"gloss\" width=\"{s}\" height=\"{s}\" fill=\"url(#gloss-grad)\"/>"
    )
}

fn squircle_rect(size: u32) -> String {
    let s = f64::from(size);
    format!(
        "<rect width=\"{}\" height=\"{}\" rx=\"{}\" ry=\"{}\"",
        fmt(s),
        fmt(s),
        fmt(s * 0.2237),
        fmt(s * 0.2237)
    )
}

/// Border width as a fraction of the canvas: 2 px at 1024.
const BORDER: f64 = 2.0 / 1024.0;

fn container_fragment(theme: &ThemeCfg, size: u32) -> String {
    if theme.container.kind == "squircle" {
        // The stroke is centred on the edge; inset the rect by half of it so it stays inside.
        let s = f64::from(size);
        let sw = s * BORDER;
        let r = (s * 0.2237 - sw / 2.0).max(0.0);
        format!(
            "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" rx=\"{}\" ry=\"{}\" id=\"container\" fill=\"none\" stroke=\"#000000\" stroke-opacity=\"0.12\" stroke-width=\"{}\"/>",
            fmt(sw / 2.0),
            fmt(sw / 2.0),
            fmt(s - sw),
            fmt(s - sw),
            fmt(r),
            fmt(r),
            fmt(sw)
        )
    } else {
        String::new()
    }
}

/// Builds every layer. The composite stacks base, texture, mark, gloss, container.
pub fn layers(theme: &ThemeCfg, glyph: &Glyph, size: u32) -> Layers {
    let (pl, bounds) = place(theme, glyph, size);
    let base = base_fragment(theme, size);
    let tex = texture::layer_svg(&theme.texture, &bounds, size);
    let mark = mark_fragment(theme, glyph, &pl, size);
    let gloss = gloss_fragment(theme, size);
    let container = container_fragment(theme, size);
    let stack = format!("{base}{tex}{mark}{gloss}");
    let body = if theme.container.kind == "squircle" {
        format!(
            "<clipPath id=\"clip\">{}/></clipPath><g clip-path=\"url(#clip)\">{stack}</g>{container}",
            squircle_rect(size)
        )
    } else {
        stack
    };
    Layers {
        base: doc(size, &base),
        texture: doc(size, &tex),
        mark: doc(size, &mark),
        gloss: doc(size, &gloss),
        container: doc(size, &container),
        composite: doc(size, &body),
        bounds,
    }
}
