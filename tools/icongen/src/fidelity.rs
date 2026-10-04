//! Fidelity metrics of the vector mark against the source raster, plus the tracer that produces a
//! starting `mark.toml` from that raster.
//!
//! All coordinates are source-pixel space: pixel `(i, j)` covers `[i, i+1] x [j, j+1]`, so its
//! centre is `(i + 0.5, j + 0.5)`. `mark.toml` uses the same space, so a glyph rasterised at
//! scale 1 overlays the source mask directly.

use crate::config::{MarkCfg, ThemeCfg};
use crate::glyph::{Glyph, Pt, Tag, contour_path, polygon_area};
use std::collections::BTreeMap;
use std::path::Path;

/// Binary raster mask, row-major, `true` = ink.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mask {
    pub width: usize,
    pub height: usize,
    pub data: Vec<bool>,
}

/// Grayscale raster (0..255), row-major. Kept alongside the mask so tracing can interpolate
/// sub-pixel edge positions from the anti-aliased source.
#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
}

impl Mask {
    /// Ink where the field value is above `threshold`.
    pub fn from_field(f: &Field, threshold: f32) -> Mask {
        Mask {
            width: f.width,
            height: f.height,
            data: f.data.iter().map(|&v| v > threshold).collect(),
        }
    }

    fn at(&self, x: usize, y: usize) -> bool {
        self.data[y * self.width + x]
    }
}

/// Intersection over union of two masks of equal size (1.0 when both are empty).
pub fn iou(a: &Mask, b: &Mask) -> f64 {
    assert_eq!(
        (a.width, a.height),
        (b.width, b.height),
        "mask size mismatch"
    );
    let (mut inter, mut union) = (0usize, 0usize);
    for (&x, &y) in a.data.iter().zip(&b.data) {
        inter += usize::from(x && y);
        union += usize::from(x || y);
    }
    if union == 0 {
        1.0
    } else {
        inter as f64 / union as f64
    }
}

// ---------------------------------------------------------------- loading

/// Decodes a PNG (gray, gray+alpha, RGB, RGBA, indexed, any depth) to luminance over black.
pub fn load_field_png(bytes: &[u8]) -> Result<Field, String> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| e.to_string())?;
    let (w, h) = (info.width as usize, info.height as usize);
    let step = match info.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => return Err("unexpanded indexed PNG".into()),
    };
    let data = buf[..info.buffer_size()]
        .chunks_exact(step)
        .map(|px| {
            let (lum, alpha) = match step {
                1 => (f32::from(px[0]), 255.0),
                2 => (f32::from(px[0]), f32::from(px[1])),
                _ => (
                    0.299 * f32::from(px[0]) + 0.587 * f32::from(px[1]) + 0.114 * f32::from(px[2]),
                    if step == 4 { f32::from(px[3]) } else { 255.0 },
                ),
            };
            lum * alpha / 255.0
        })
        .collect();
    Ok(Field {
        width: w,
        height: h,
        data,
    })
}

/// Source mask: luminance above 127 is ink.
pub fn load_mask_png(bytes: &[u8]) -> Result<Mask, String> {
    Ok(Mask::from_field(&load_field_png(bytes)?, 127.0))
}

// ---------------------------------------------------------------- rasterising

fn render_mask(svg: &str, w: usize, h: usize) -> Result<Mask, String> {
    use resvg::tiny_skia::{Pixmap, Transform};
    use resvg::usvg::{Options, Tree};
    let tree = Tree::from_str(svg, &Options::default()).map_err(|e| e.to_string())?;
    let mut pix = Pixmap::new(w as u32, h as u32).ok_or("invalid raster size")?;
    resvg::render(&tree, Transform::identity(), &mut pix.as_mut());
    Ok(Mask {
        width: w,
        height: h,
        data: pix.pixels().iter().map(|p| p.alpha() > 127).collect(),
    })
}

fn glyph_mask(glyph: &Glyph, weight: f64, (w, h): (usize, usize), map: &dyn Fn(Pt) -> Pt) -> Mask {
    let mut body = String::from("<g fill=\"#000\">");
    for piece in glyph.pieces(weight) {
        let d: String = piece
            .contours
            .iter()
            .map(|c| contour_path(c, map))
            .collect();
        let rule = if piece.even_odd {
            " fill-rule=\"evenodd\""
        } else {
            ""
        };
        body.push_str(&format!("<path{rule} d=\"{d}\"/>"));
    }
    body.push_str("</g>");
    let svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\">{body}</svg>"
    );
    render_mask(&svg, w, h).unwrap_or_else(|_| Mask {
        width: w,
        height: h,
        data: vec![false; w * h],
    })
}

/// Glyph as a mask of `ceil(width*scale) x ceil(height*scale)`; glyph coordinates are source
/// pixels, so scale 1 overlays a `width x height` source mask.
pub fn rasterize(glyph: &Glyph, weight: f64, width: usize, height: usize, scale: f64) -> Mask {
    let size = (
        (width as f64 * scale).ceil() as usize,
        (height as f64 * scale).ceil() as usize,
    );
    glyph_mask(glyph, weight, size, &|p| (p.0 * scale, p.1 * scale))
}

/// Glyph fitted so its ink bounding box's longer side is `px` pixels.
pub fn rasterize_fit(glyph: &Glyph, weight: f64, px: u32) -> Mask {
    fit_mask(glyph, weight, f64::from(px))
}

fn fit_mask(glyph: &Glyph, weight: f64, px: f64) -> Mask {
    let (x0, y0, x1, y1) = glyph.bounds(weight);
    let s = px / (x1 - x0).max(y1 - y0).max(1e-9);
    let size = (
        ((x1 - x0) * s).ceil().max(1.0) as usize,
        ((y1 - y0) * s).ceil().max(1.0) as usize,
    );
    glyph_mask(glyph, weight, size, &|p| ((p.0 - x0) * s, (p.1 - y0) * s))
}

/// Renders arbitrary SVG text into a mask scaled so its viewBox maps onto the `w x h` frame
/// (used for one-off comparisons against other vectorisations).
pub fn svg_mask(svg: &str, w: usize, h: usize) -> Result<Mask, String> {
    render_mask(svg, w, h)
}

// ---------------------------------------------------------------- topology

fn label(w: usize, h: usize, on: &dyn Fn(usize) -> bool, eight: bool) -> (Vec<u32>, u32) {
    let mut lab = vec![0u32; w * h];
    let mut n = 0;
    let mut stack = Vec::new();
    for s in 0..w * h {
        if lab[s] != 0 || !on(s) {
            continue;
        }
        n += 1;
        lab[s] = n;
        stack.push(s);
        while let Some(i) = stack.pop() {
            let (x, y) = ((i % w) as isize, (i / w) as isize);
            for dy in -1..=1isize {
                for dx in -1..=1isize {
                    if (dx == 0 && dy == 0) || (!eight && dx != 0 && dy != 0) {
                        continue;
                    }
                    let (nx, ny) = (x + dx, y + dy);
                    if nx < 0 || ny < 0 || nx >= w as isize || ny >= h as isize {
                        continue;
                    }
                    let j = ny as usize * w + nx as usize;
                    if lab[j] == 0 && on(j) {
                        lab[j] = n;
                        stack.push(j);
                    }
                }
            }
        }
    }
    (lab, n)
}

/// Connected ink pieces (8-connectivity).
pub fn components(m: &Mask) -> usize {
    label(m.width, m.height, &|i| m.data[i], true).1 as usize
}

/// Holes: background regions (4-connectivity) that do not reach the border.
pub fn holes(m: &Mask) -> usize {
    let (pw, ph) = (m.width + 2, m.height + 2);
    let on = |i: usize| {
        let (x, y) = (i % pw, i / pw);
        x == 0 || y == 0 || x == pw - 1 || y == ph - 1 || !m.at(x - 1, y - 1)
    };
    (label(pw, ph, &on, false).1 as usize).saturating_sub(1)
}

// ---------------------------------------------------------------- distances

const BIG: f64 = 1e12;

fn dt1(f: &[f64]) -> Vec<f64> {
    let n = f.len();
    let mut d = vec![0.0; n];
    let mut v = vec![0usize; n];
    let mut z = vec![0.0; n + 1];
    let mut k = 0;
    z[0] = f64::NEG_INFINITY;
    z[1] = f64::INFINITY;
    for q in 1..n {
        loop {
            let p = v[k];
            let s = ((f[q] + (q * q) as f64) - (f[p] + (p * p) as f64)) / (2.0 * (q - p) as f64);
            if s <= z[k] {
                k -= 1;
            } else {
                k += 1;
                v[k] = q;
                z[k] = s;
                z[k + 1] = f64::INFINITY;
                break;
            }
        }
    }
    k = 0;
    for (q, out) in d.iter_mut().enumerate() {
        while z[k + 1] < q as f64 {
            k += 1;
        }
        let dq = q as f64 - v[k] as f64;
        *out = dq * dq + f[v[k]];
    }
    d
}

/// Squared Euclidean distance from every pixel to the nearest `true` in `feature`.
fn edt_sq(feature: &[bool], w: usize, h: usize) -> Vec<f64> {
    let mut g: Vec<f64> = feature.iter().map(|&b| if b { 0.0 } else { BIG }).collect();
    for x in 0..w {
        let col: Vec<f64> = (0..h).map(|y| g[y * w + x]).collect();
        for (y, v) in dt1(&col).into_iter().enumerate() {
            g[y * w + x] = v;
        }
    }
    for y in 0..h {
        let row = dt1(&g[y * w..(y + 1) * w]);
        g[y * w..(y + 1) * w].copy_from_slice(&row);
    }
    g
}

/// Ink pixels with a 4-neighbour outside the ink (or the raster).
fn boundary(m: &Mask) -> Vec<bool> {
    let (w, h) = (m.width, m.height);
    (0..w * h)
        .map(|i| {
            let (x, y) = (i % w, i / w);
            m.data[i]
                && (x == 0
                    || y == 0
                    || x == w - 1
                    || y == h - 1
                    || !m.at(x - 1, y)
                    || !m.at(x + 1, y)
                    || !m.at(x, y - 1)
                    || !m.at(x, y + 1))
        })
        .collect()
}

/// Symmetric Hausdorff distance between the outlines (boundary pixels) of two equal-size masks,
/// in pixels. Infinite when exactly one mask is empty.
pub fn hausdorff(a: &Mask, b: &Mask) -> f64 {
    assert_eq!(
        (a.width, a.height),
        (b.width, b.height),
        "mask size mismatch"
    );
    let (ba, bb) = (boundary(a), boundary(b));
    match (ba.contains(&true), bb.contains(&true)) {
        (false, false) => return 0.0,
        (true, true) => {}
        _ => return f64::INFINITY,
    }
    let directed = |from: &[bool], to: &[bool]| {
        let d = edt_sq(to, a.width, a.height);
        from.iter()
            .zip(&d)
            .filter(|(f, _)| **f)
            .fold(0.0f64, |m, (_, &v)| m.max(v))
    };
    directed(&ba, &bb).max(directed(&bb, &ba)).sqrt()
}

/// Per-piece stroke width estimate: the thickest point of each piece, `2 * d - 1` where `d` is the
/// distance from its deepest ink pixel centre to the nearest background pixel centre.
pub fn piece_widths(m: &Mask) -> Vec<f64> {
    let (pw, ph) = (m.width + 2, m.height + 2);
    let bg: Vec<bool> = (0..pw * ph)
        .map(|i| {
            let (x, y) = (i % pw, i / pw);
            x == 0 || y == 0 || x == pw - 1 || y == ph - 1 || !m.at(x - 1, y - 1)
        })
        .collect();
    let d = edt_sq(&bg, pw, ph);
    let (lab, n) = label(m.width, m.height, &|i| m.data[i], true);
    let mut best = vec![0.0f64; n as usize];
    for (i, &l) in lab.iter().enumerate() {
        if l > 0 {
            let (x, y) = (i % m.width, i / m.width);
            let v = d[(y + 1) * pw + x + 1];
            let slot = &mut best[l as usize - 1];
            *slot = slot.max(v);
        }
    }
    best.into_iter().map(|v| 2.0 * v.sqrt() - 1.0).collect()
}

/// Narrowest piece's width estimate (0 for an empty mask).
pub fn min_stroke_width(m: &Mask) -> f64 {
    piece_widths(m)
        .into_iter()
        .fold(None, |a: Option<f64>, v| Some(a.map_or(v, |a| a.min(v))))
        .unwrap_or(0.0)
}

// ---------------------------------------------------------------- tracing

type Key = (u8, isize, isize);

/// Marching squares at `level` over `f` (outside the raster counts as below the level). Contours are
/// closed polylines in source-pixel coordinates; ink is on the right in screen orientation, so
/// outer contours have positive shoelace area and holes negative.
pub fn trace_contours(f: &Field, level: f32) -> Vec<Vec<Pt>> {
    let (w, h) = (f.width as isize, f.height as isize);
    let val = |x: isize, y: isize| -> f32 {
        if x < 0 || y < 0 || x >= w || y >= h {
            0.0
        } else {
            f.data[(y * w + x) as usize]
        }
    };
    let inside = |x: isize, y: isize| val(x, y) > level;
    let mut pts: BTreeMap<Key, Pt> = BTreeMap::new();
    let mut next: BTreeMap<Key, Key> = BTreeMap::new();
    for y in -1..h {
        for x in -1..w {
            // Corners clockwise from top-left, edges between corner i and i+1.
            let c = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)];
            let keys: [Key; 4] = [(0, x, y), (1, x + 1, y), (0, x, y + 1), (1, x, y)];
            // (key, entering ink)
            let mut cross: Vec<(Key, bool)> = Vec::new();
            for i in 0..4 {
                let (p, q) = (c[i], c[(i + 1) % 4]);
                let (ip, iq) = (inside(p.0, p.1), inside(q.0, q.1));
                if ip == iq {
                    continue;
                }
                let (vp, vq) = (val(p.0, p.1), val(q.0, q.1));
                let t = f64::from((level - vp) / (vq - vp));
                let pos = (
                    p.0 as f64 + t * (q.0 - p.0) as f64 + 0.5,
                    p.1 as f64 + t * (q.1 - p.1) as f64 + 0.5,
                );
                pts.insert(keys[i], pos);
                cross.push((keys[i], iq));
            }
            match cross.len() {
                2 => {
                    let (l, e) = if cross[0].1 {
                        (cross[1].0, cross[0].0)
                    } else {
                        (cross[0].0, cross[1].0)
                    };
                    next.insert(l, e);
                }
                4 => {
                    // Rotate so the sequence is L0 E0 L1 E1.
                    let s = usize::from(cross[0].1);
                    let q: Vec<Key> = (0..4).map(|i| cross[(s + i) % 4].0).collect();
                    let centre = (val(c[0].0, c[0].1)
                        + val(c[1].0, c[1].1)
                        + val(c[2].0, c[2].1)
                        + val(c[3].0, c[3].1))
                        / 4.0;
                    if centre > level {
                        next.insert(q[0], q[1]);
                        next.insert(q[2], q[3]);
                    } else {
                        next.insert(q[0], q[3]);
                        next.insert(q[2], q[1]);
                    }
                }
                _ => {}
            }
        }
    }
    let mut seen: BTreeMap<Key, ()> = BTreeMap::new();
    let mut out = Vec::new();
    for &start in next.keys() {
        if seen.contains_key(&start) {
            continue;
        }
        let mut poly = Vec::new();
        let mut k = start;
        while seen.insert(k, ()).is_none() {
            poly.push(pts[&k]);
            k = next[&k];
        }
        out.push(poly);
    }
    out
}

fn area(c: &[Pt]) -> f64 {
    let n = c.len();
    (0..n)
        .map(|i| c[i].0 * c[(i + 1) % n].1 - c[(i + 1) % n].0 * c[i].1)
        .sum::<f64>()
        / 2.0
}

fn dist_to_segment(p: Pt, a: Pt, b: Pt) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0.0 {
        0.0
    } else {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0)
    };
    (p.0 - a.0 - t * dx).hypot(p.1 - a.1 - t * dy)
}

fn dp_open(pts: &[Pt], lo: usize, hi: usize, eps: f64, keep: &mut [bool]) {
    if hi <= lo + 1 {
        return;
    }
    let (mut far, mut fd) = (lo, 0.0);
    for i in lo + 1..hi {
        let d = dist_to_segment(pts[i], pts[lo], pts[hi]);
        if d > fd {
            (far, fd) = (i, d);
        }
    }
    if fd > eps {
        keep[far] = true;
        dp_open(pts, lo, far, eps, keep);
        dp_open(pts, far, hi, eps, keep);
    }
}

/// Douglas-Peucker on a closed polygon (split at the vertex farthest from vertex 0).
pub fn simplify_closed(pts: &[Pt], eps: f64) -> Vec<Pt> {
    if pts.len() < 4 {
        return pts.to_vec();
    }
    let far = (1..pts.len())
        .max_by(|&a, &b| {
            let da = (pts[a].0 - pts[0].0).hypot(pts[a].1 - pts[0].1);
            let db = (pts[b].0 - pts[0].0).hypot(pts[b].1 - pts[0].1);
            da.total_cmp(&db)
        })
        .unwrap_or(1);
    let mut keep = vec![false; pts.len()];
    keep[0] = true;
    keep[far] = true;
    dp_open(pts, 0, far, eps, &mut keep);
    let mut ring: Vec<Pt> = pts[far..].to_vec();
    ring.push(pts[0]);
    let mut keep2 = vec![false; ring.len()];
    dp_open(&ring, 0, ring.len() - 1, eps, &mut keep2);
    let mut out: Vec<Pt> = (0..pts.len())
        .filter(|&i| keep[i])
        .map(|i| pts[i])
        .collect();
    out.extend((1..ring.len() - 1).filter(|&i| keep2[i]).map(|i| ring[i]));
    out
}

/// Indices of polygon vertices where the path turns by more than `min_turn_deg`.
pub fn corner_points(poly: &[Pt], min_turn_deg: f64) -> Vec<usize> {
    let n = poly.len();
    (0..n)
        .filter(|&i| {
            let (p, c, q) = (poly[(i + n - 1) % n], poly[i], poly[(i + 1) % n]);
            let (a, b) = ((c.0 - p.0, c.1 - p.1), (q.0 - c.0, q.1 - c.1));
            let (la, lb) = (a.0.hypot(a.1), b.0.hypot(b.1));
            if la == 0.0 || lb == 0.0 {
                return false;
            }
            let cos = ((a.0 * b.0 + a.1 * b.1) / (la * lb)).clamp(-1.0, 1.0);
            cos.acos().to_degrees() > min_turn_deg
        })
        .collect()
}

const MIN_CONTOUR_AREA: f64 = 4.0;
const SIMPLIFY_EPS: f64 = 1.0;
const CORNER_TURN: f64 = 35.0;
const CORNER_TOL: f64 = 3.0;

/// Corners of the source outline: contours simplified with Douglas-Peucker, vertices turning more
/// than 35 degrees.
pub fn source_corners(f: &Field) -> Vec<Pt> {
    let mut out = Vec::new();
    for c in trace_contours(f, 127.5) {
        if area(&c).abs() < MIN_CONTOUR_AREA {
            continue;
        }
        let s = simplify_closed(&c, SIMPLIFY_EPS);
        out.extend(corner_points(&s, CORNER_TURN).into_iter().map(|i| s[i]));
    }
    out
}

/// Share of `corners` that have a `c`-tagged glyph vertex within 3 px (1.0 when there are none).
pub fn corners_kept(corners: &[Pt], glyph: &Glyph, weight: f64) -> f64 {
    if corners.is_empty() {
        return 1.0;
    }
    let sharp: Vec<Pt> = glyph
        .pieces(weight)
        .iter()
        .flat_map(|p| p.contours.iter().flatten())
        .filter(|v| v.tag == Tag::Sharp)
        .map(|v| (v.x, v.y))
        .collect();
    let kept = corners
        .iter()
        .filter(|c| {
            sharp
                .iter()
                .any(|s| (s.0 - c.0).hypot(s.1 - c.1) <= CORNER_TOL)
        })
        .count();
    kept as f64 / corners.len() as f64
}

fn point_in_poly(p: Pt, poly: &[Pt]) -> bool {
    let n = poly.len();
    let mut inside = false;
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        if (a.1 > p.1) != (b.1 > p.1) && p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 {
            inside = !inside;
        }
    }
    inside
}

fn tagged(poly: &[Pt]) -> String {
    let corners = corner_points(poly, CORNER_TURN);
    poly.iter()
        .enumerate()
        .map(|(i, p)| {
            let t = if corners.contains(&i) { "c" } else { "s" };
            format!("[{:.2}, {:.2}, \"{t}\"]", p.0, p.1)
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// (right column, centroid y, centerline) of a candidate side stroke.
type StrokeCand = (bool, f64, Vec<(f64, f64, f64)>);

/// Centerline `(x, y, width)` samples of a piece's pixels along their principal axis.
fn centerline(pixels: &[Pt]) -> Vec<(f64, f64, f64)> {
    let n = pixels.len() as f64;
    let (cx, cy) = (
        pixels.iter().map(|p| p.0).sum::<f64>() / n,
        pixels.iter().map(|p| p.1).sum::<f64>() / n,
    );
    let (mut sxx, mut syy, mut sxy) = (0.0, 0.0, 0.0);
    for p in pixels {
        let (dx, dy) = (p.0 - cx, p.1 - cy);
        sxx += dx * dx;
        syy += dy * dy;
        sxy += dx * dy;
    }
    let ang = 0.5 * (2.0 * sxy).atan2(sxx - syy);
    let mut u = (ang.cos(), ang.sin());
    if u.0 < -1e-9 || (u.0.abs() <= 1e-9 && u.1 < 0.0) {
        u = (-u.0, -u.1);
    }
    let v = (-u.1, u.0);
    let proj: Vec<(f64, f64)> = pixels
        .iter()
        .map(|p| {
            (
                (p.0 - cx) * u.0 + (p.1 - cy) * u.1,
                (p.0 - cx) * v.0 + (p.1 - cy) * v.1,
            )
        })
        .collect();
    let tmin = proj.iter().map(|p| p.0).fold(f64::MAX, f64::min);
    let tmax = proj.iter().map(|p| p.0).fold(f64::MIN, f64::max);
    const K: usize = 5;
    let mut out = Vec::new();
    for i in 0..K {
        let f = i as f64 / (K - 1) as f64;
        let (lo, hi) = (tmin + 1.0, (tmax - 1.0).max(tmin + 1.0));
        let tc = lo + (hi - lo) * f;
        let (mut smin, mut smax) = (f64::MAX, f64::MIN);
        for p in proj.iter().filter(|p| (p.0 - tc).abs() <= 1.5) {
            smin = smin.min(p.1);
            smax = smax.max(p.1);
        }
        if smin > smax {
            continue;
        }
        let along = (tmin - 0.5) + (tmax - tmin + 1.0) * f;
        let across = (smin + smax) / 2.0;
        out.push((
            cx + u.0 * along + v.0 * across,
            cy + u.1 * along + v.1 * across,
            smax - smin + 1.0,
        ));
    }
    out
}

/// Starting `mark.toml` text traced from `f`: the largest piece becomes S01 (outline + hole
/// polygons, vertices tagged `c` above 35 degrees of turn), every other piece a centerline stroke
/// ordered left column then right column, top to bottom.
pub fn trace_toml(f: &Field) -> Result<String, String> {
    let mask = Mask::from_field(f, 127.0);
    let (lab, n) = label(mask.width, mask.height, &|i| mask.data[i], true);
    if n == 0 {
        return Err("source has no ink".into());
    }
    let mut comps: Vec<Vec<Pt>> = vec![Vec::new(); n as usize];
    for (i, &l) in lab.iter().enumerate() {
        if l > 0 {
            comps[l as usize - 1]
                .push(((i % mask.width) as f64 + 0.5, (i / mask.width) as f64 + 0.5));
        }
    }
    let main = (0..comps.len())
        .max_by_key(|&i| comps[i].len())
        .unwrap_or(0);
    let contours: Vec<Vec<Pt>> = trace_contours(f, 127.5)
        .into_iter()
        .filter(|c| area(c).abs() >= MIN_CONTOUR_AREA)
        .collect();
    let first = comps[main][0];
    // The outer contour of the main piece: positive area, surrounding a pixel of that piece.
    let outer = contours
        .iter()
        .filter(|c| area(c) > 0.0 && point_in_poly(first, c))
        .max_by(|a, b| area(a).total_cmp(&area(b)))
        .ok_or("no outer contour for the main piece")?;
    let mut holes: Vec<&Vec<Pt>> = contours
        .iter()
        .filter(|c| area(c) < 0.0 && point_in_poly(c[0], outer))
        .collect();
    holes.sort_by(|a, b| area(a).total_cmp(&area(b)));
    let mut s = String::from(
        "# Traced starting point (icongen trace); refine by hand against the source.\n# Coordinates are source pixels, y down. Vertex tag: \"c\" sharp, \"s\" smooth.\n\n[s01]\noutline = [\n",
    );
    s.push_str(&format!(
        "  {},\n]\nholes = [\n",
        tagged(&simplify_closed(outer, SIMPLIFY_EPS))
    ));
    for h in holes {
        s.push_str(&format!(
            "  [{}],\n",
            tagged(&simplify_closed(h, SIMPLIFY_EPS))
        ));
    }
    s.push_str("]\n");
    let (mx, _) = {
        let c = &comps[main];
        (c.iter().map(|p| p.0).sum::<f64>() / c.len() as f64, 0.0)
    };
    let mut strokes: Vec<StrokeCand> = (0..comps.len())
        .filter(|&i| i != main && comps[i].len() >= 20)
        .map(|i| {
            let c = &comps[i];
            let (x, y) = (
                c.iter().map(|p| p.0).sum::<f64>() / c.len() as f64,
                c.iter().map(|p| p.1).sum::<f64>() / c.len() as f64,
            );
            (x >= mx, y, centerline(c))
        })
        .filter(|(_, _, line)| line.len() >= 2)
        .collect();
    strokes.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.total_cmp(&b.1)));
    for (i, (_, _, line)) in strokes.iter().enumerate() {
        let pts: Vec<String> = line
            .iter()
            .map(|p| format!("[{:.2}, {:.2}, {:.2}]", p.0, p.1, p.2))
            .collect();
        s.push_str(&format!(
            "\n[[stroke]]\nid = \"S{:02}\"\npoints = [{}]\ncap_start = {{ cut = 0.0, asym = 0.0 }}\ncap_end = {{ cut = 0.0, asym = 0.0 }}\n",
            i + 2,
            pts.join(", ")
        ));
    }
    Ok(s)
}

// ---------------------------------------------------------------- report

/// Readability of the mark at a small render size.
#[derive(Debug, Clone, PartialEq)]
pub struct SmallSize {
    /// Length of the mark's longer side in pixels.
    pub px: u32,
    pub pieces: usize,
    pub holes: usize,
    pub narrowest: f64,
}

fn small_size(glyph: &Glyph, weight: f64, px: u32) -> SmallSize {
    let m = rasterize_fit(glyph, weight, px);
    SmallSize {
        px,
        pieces: components(&m),
        holes: holes(&m),
        narrowest: min_stroke_width(&m),
    }
}

/// Thresholded render of the mark with its longer side `px` pixels: pieces, holes and the
/// narrowest stroke.
pub fn small_size_report(glyph: &Glyph, px: u32) -> SmallSize {
    small_size(glyph, 0.0, px)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub iou: f64,
    pub hausdorff: f64,
    pub corners_total: usize,
    pub corners_kept: f64,
    pub pieces: usize,
    pub holes: usize,
    pub model_holes: usize,
    pub model_strokes: usize,
    /// Renders at 120, 60 and 40 px.
    pub small: Vec<SmallSize>,
}

/// Measures `glyph` (at stroke `weight`) against the source field.
pub fn evaluate(glyph: &Glyph, weight: f64, source: &Field) -> Report {
    let src = Mask::from_field(source, 127.0);
    let g = rasterize(glyph, weight, src.width, src.height, 1.0);
    let corners = source_corners(source);
    Report {
        iou: iou(&src, &g),
        hausdorff: hausdorff(&src, &g),
        corners_total: corners.len(),
        corners_kept: corners_kept(&corners, glyph, weight),
        pieces: components(&g),
        holes: holes(&g),
        model_holes: glyph.holes.len(),
        model_strokes: glyph.strokes.len(),
        small: [120, 60, 40]
            .iter()
            .map(|&px| small_size(glyph, weight, px))
            .collect(),
    }
}

fn small_at(r: &Report, px: u32) -> Option<&SmallSize> {
    r.small.iter().find(|s| s.px == px)
}

/// Human-readable gate failures; empty when every gate passes.
pub fn failures(r: &Report) -> Vec<String> {
    let mut f = Vec::new();
    if r.iou < 0.88 {
        f.push(format!("IoU {:.3} < 0.88", r.iou));
    }
    if r.hausdorff > 3.0 {
        f.push(format!("Hausdorff {:.2} px > 3", r.hausdorff));
    }
    if r.corners_kept < 0.8 {
        f.push(format!("corners kept {:.2} < 0.80", r.corners_kept));
    }
    if (r.pieces, r.holes, r.model_holes, r.model_strokes) != (5, 2, 2, 4) {
        f.push(format!(
            "topology: {} pieces / {} holes rendered, S01 has {} holes and {} strokes (want 5 / 2 / 2 / 4)",
            r.pieces, r.holes, r.model_holes, r.model_strokes
        ));
    }
    match small_at(r, 60) {
        Some(s) if s.narrowest >= 2.0 => {}
        Some(s) => f.push(format!("60px narrowest stroke {:.2} px < 2", s.narrowest)),
        None => f.push("no 60px render".into()),
    }
    match small_at(r, 40) {
        Some(s) if s.holes >= 1 && s.pieces == 5 => {}
        Some(s) => f.push(format!(
            "40px keeps {} pieces / {} holes (want 5 pieces, >= 1 hole)",
            s.pieces, s.holes
        )),
        None => f.push("no 40px render".into()),
    }
    f
}

/// Report table as text.
pub fn format_report(r: &Report) -> String {
    let mut s = String::new();
    let mut row =
        |name: &str, v: String, gate: &str| s.push_str(&format!("{name:<26}{v:<14}{gate}\n"));
    row("metric", "value".into(), "gate");
    row("IoU", format!("{:.3}", r.iou), ">= 0.88");
    row("Hausdorff (px)", format!("{:.2}", r.hausdorff), "<= 3");
    row(
        "corners kept",
        format!("{:.2} of {}", r.corners_kept, r.corners_total),
        ">= 0.80",
    );
    row(
        "pieces / holes",
        format!("{} / {}", r.pieces, r.holes),
        "5 / 2",
    );
    row(
        "S01 holes / strokes",
        format!("{} / {}", r.model_holes, r.model_strokes),
        "2 / 4",
    );
    for z in &r.small {
        row(
            &format!("{} px render", z.px),
            format!("{}p {}h {:.1}w", z.pieces, z.holes, z.narrowest),
            match z.px {
                60 => "narrowest >= 2",
                40 => "5 pieces, >= 1 hole",
                _ => "",
            },
        );
    }
    s
}

// ---------------------------------------------------------------- themed mark

/// Icon sizes (px, whole canvas) the themed mark is checked at.
pub const THEME_SIZES: [u32; 4] = [1024, 120, 60, 40];
/// Smallest area (source px squared) a hole keeps at a theme's weight.
pub const MIN_HOLE_AREA: f64 = 12.0;

/// The mark as a theme draws it: its weight and scale, rendered at whole-icon sizes.
#[derive(Debug, Clone, PartialEq)]
pub struct ThemeCheck {
    pub name: String,
    pub weight: f64,
    /// One entry per [`THEME_SIZES`]; `px` is the icon size, the mark spans `scale * px`.
    pub sizes: Vec<SmallSize>,
    /// Areas of the S01 holes at the theme's weight, source px squared.
    pub hole_areas: Vec<f64>,
}

/// Renders the theme's mark (weight, small-size bonus, scale) at every [`THEME_SIZES`] icon size.
/// Pieces and holes come from the render at that size; the narrowest width comes from a render
/// supersampled to at least 640 px, so it reads in fractions of a pixel at that size.
pub fn check_theme(glyph: &Glyph, name: &str, mark: &MarkCfg) -> ThemeCheck {
    let sizes = THEME_SIZES
        .iter()
        .map(|&px| {
            let w = mark.weight_at(px);
            let mark_px = mark.scale * f64::from(px);
            let m = fit_mask(glyph, w, mark_px);
            let ss = (640 / px).max(1);
            let fine = fit_mask(glyph, w, mark_px * f64::from(ss));
            SmallSize {
                px,
                pieces: components(&m),
                holes: holes(&m),
                narrowest: min_stroke_width(&fine) / f64::from(ss),
            }
        })
        .collect();
    let hole_areas = glyph.pieces(mark.weight)[0].contours[1..]
        .iter()
        .map(|h| polygon_area(h))
        .collect();
    ThemeCheck {
        name: name.into(),
        weight: mark.weight,
        sizes,
        hole_areas,
    }
}

/// Themed gates: 5 pieces at every size, both holes at 1024 and 120 px, the narrowest piece at
/// least 2 px at 40 px, and every hole at least [`MIN_HOLE_AREA`].
pub fn theme_failures(c: &ThemeCheck) -> Vec<String> {
    let mut f = Vec::new();
    for s in &c.sizes {
        if s.pieces != 5 {
            f.push(format!(
                "{}: {} px icon has {} pieces (want 5)",
                c.name, s.px, s.pieces
            ));
        }
        if matches!(s.px, 1024 | 120) && s.holes != 2 {
            f.push(format!(
                "{}: {} px icon has {} holes (want 2)",
                c.name, s.px, s.holes
            ));
        }
        if s.px == 40 && s.narrowest < 2.0 {
            f.push(format!(
                "{}: 40 px icon narrowest stroke {:.2} px < 2",
                c.name, s.narrowest
            ));
        }
    }
    if c.hole_areas.len() != 2 || c.hole_areas.iter().any(|&a| a < MIN_HOLE_AREA) {
        f.push(format!(
            "{}: hole areas {:?} (want 2, each >= {MIN_HOLE_AREA} source px^2)",
            c.name, c.hole_areas
        ));
    }
    f
}

fn format_theme(c: &ThemeCheck) -> String {
    let sizes: Vec<String> = c
        .sizes
        .iter()
        .map(|z| format!("{}px {}p {}h {:.2}w", z.px, z.pieces, z.holes, z.narrowest))
        .collect();
    let areas: Vec<String> = c.hole_areas.iter().map(|a| format!("{a:.0}")).collect();
    format!(
        "theme {:<12}weight {:<5}{}  holes {}\n",
        c.name,
        c.weight,
        sizes.join("  "),
        areas.join("/")
    )
}

/// Reads `brand/source/oracle-rate.png`, `brand/mark/mark.toml` and `brand/themes/*.toml`;
/// returns the report text and whether every gate passed. The master gates measure the mark at
/// weight 0; the theme gates measure each theme's weighted mark.
pub fn run(brand: &Path) -> Result<(String, bool), String> {
    let rd = |rel: &str| std::fs::read(brand.join(rel)).map_err(|e| format!("{rel}: {e}"));
    let field = load_field_png(&rd("source/oracle-rate.png")?)?;
    let glyph = Glyph::from_toml(&String::from_utf8_lossy(&rd("mark/mark.toml")?))?;
    let r = evaluate(&glyph, 0.0, &field);
    let mut fails = failures(&r);
    let mut text = format_report(&r);
    let mut names: Vec<String> = std::fs::read_dir(brand.join("themes"))
        .map_err(|e| format!("themes: {e}"))?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".toml"))
        .collect();
    names.sort();
    for n in &names {
        let rel = format!("themes/{n}");
        let theme = ThemeCfg::from_toml(&String::from_utf8_lossy(&rd(&rel)?))?;
        let c = check_theme(&glyph, &theme.name, &theme.mark);
        text.push_str(&format_theme(&c));
        fails.extend(theme_failures(&c));
    }
    for f in &fails {
        text.push_str(&format!("FAIL {f}\n"));
    }
    text.push_str(if fails.is_empty() {
        "all fidelity gates pass\n"
    } else {
        "fidelity gates FAILED\n"
    });
    Ok((text, fails.is_empty()))
}
