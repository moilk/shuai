//! Fidelity metrics of the vector mark against the source raster, plus the tracer that produces a
//! starting `mark.toml` from that raster.
//!
//! All coordinates are source-pixel space: pixel `(i, j)` covers `[i, i+1] x [j, j+1]`, so its
//! centre is `(i + 0.5, j + 0.5)`. `mark.toml` uses the same space, so a glyph rasterised at
//! scale 1 overlays the source mask directly.

use crate::config::{MarkCfg, ThemeCfg};
use crate::glyph::{Glyph, Piece, Pt, Tag, contour_path, polygon_area};
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

/// Catmull-Rom (bicubic, a = -0.5) kernel.
fn cubic(t: f64) -> f64 {
    let t = t.abs();
    if t < 1.0 {
        1.5 * t * t * t - 2.5 * t * t + 1.0
    } else if t < 2.0 {
        -0.5 * t * t * t + 2.5 * t * t - 4.0 * t + 2.0
    } else {
        0.0
    }
}

/// Resamples one line of `n` samples (outside counts as 0) to `n * k` samples whose centres sit
/// at `(i + 0.5) / k` in source-pixel coordinates.
fn upsample_line(line: &[f64], k: usize) -> Vec<f64> {
    let n = line.len() as isize;
    (0..line.len() * k)
        .map(|i| {
            let u = (i as f64 + 0.5) / k as f64 - 0.5;
            let base = u.floor() as isize;
            (base - 1..=base + 2)
                .filter(|j| (0..n).contains(j))
                .map(|j| line[j as usize] * cubic(u - j as f64))
                .sum()
        })
        .collect()
}

/// The field resampled `k` times finer with a bicubic (Catmull-Rom) kernel, clamped to 0..255:
/// a smooth reconstruction of the anti-aliased source whose 50% iso-line is the true edge.
pub fn upsample(f: &Field, k: usize) -> Field {
    let (w, h) = (f.width, f.height);
    let rows: Vec<Vec<f64>> = (0..h)
        .map(|y| {
            let line: Vec<f64> = f.data[y * w..(y + 1) * w]
                .iter()
                .map(|&v| f64::from(v))
                .collect();
            upsample_line(&line, k)
        })
        .collect();
    let (ow, oh) = (w * k, h * k);
    let mut data = vec![0.0f32; ow * oh];
    for x in 0..ow {
        let col: Vec<f64> = rows.iter().map(|r| r[x]).collect();
        for (y, v) in upsample_line(&col, k).into_iter().enumerate() {
            data[y * ow + x] = v.clamp(0.0, 255.0) as f32;
        }
    }
    Field {
        width: ow,
        height: oh,
        data,
    }
}

/// Iso-level of the source that counts as its edge (50%).
pub const ISO_LEVEL: f32 = 127.5;
/// Supersampling factor of the reference mask the master is measured against.
pub const MEASURE_SCALE: usize = 4;

/// Reference mask: the source upsampled `k` times, ink above the 50% iso-level.
pub fn reference_mask(f: &Field, k: usize) -> Mask {
    Mask::from_field(&upsample(f, k), ISO_LEVEL)
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

fn glyph_mask(
    glyph: &Glyph,
    (weight, hole_weight): (f64, f64),
    (w, h): (usize, usize),
    map: &dyn Fn(Pt) -> Pt,
) -> Mask {
    pieces_mask(&glyph.pieces_with(weight, hole_weight), (w, h), map)
}

fn pieces_mask(pieces: &[Piece], (w, h): (usize, usize), map: &dyn Fn(Pt) -> Pt) -> Mask {
    let mut body = String::from("<g fill=\"#000\">");
    for piece in pieces {
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
    // A broken render must never read as "no ink": that would make two empty masks agree.
    render_mask(&svg, w, h).unwrap_or_else(|e| panic!("render of {w}x{h} mask failed: {e}"))
}

/// Glyph as a mask of `ceil(width*scale) x ceil(height*scale)`; glyph coordinates are source
/// pixels, so scale 1 overlays a `width x height` source mask.
pub fn rasterize(glyph: &Glyph, weight: f64, width: usize, height: usize, scale: f64) -> Mask {
    let size = (
        (width as f64 * scale).ceil() as usize,
        (height as f64 * scale).ceil() as usize,
    );
    glyph_mask(glyph, (weight, weight), size, &|p| {
        (p.0 * scale, p.1 * scale)
    })
}

/// Glyph fitted so its ink bounding box's longer side is `px` pixels.
pub fn rasterize_fit(glyph: &Glyph, weight: f64, px: u32) -> Mask {
    fit_mask(glyph, (weight, weight), f64::from(px))
}

fn fit_mask(glyph: &Glyph, weight: (f64, f64), px: f64) -> Mask {
    let (x0, y0, x1, y1) = glyph.bounds(weight.0);
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

/// Douglas-Peucker on a closed polygon that always keeps the `anchors` (vertex indices). Returns
/// the indices of the kept vertices in order.
pub fn simplify_anchored(pts: &[Pt], eps: f64, anchors: &[usize]) -> Vec<usize> {
    let n = pts.len();
    if n < 4 {
        return (0..n).collect();
    }
    let mut a: Vec<usize> = anchors.iter().copied().filter(|&i| i < n).collect();
    if a.is_empty() {
        a.push(0);
    }
    if a.len() == 1 {
        let o = pts[a[0]];
        let far = (0..n)
            .max_by(|&i, &j| {
                let di = (pts[i].0 - o.0).hypot(pts[i].1 - o.1);
                let dj = (pts[j].0 - o.0).hypot(pts[j].1 - o.1);
                di.total_cmp(&dj)
            })
            .unwrap_or(0);
        a.push(far);
    }
    a.sort_unstable();
    a.dedup();
    let mut keep = vec![false; n];
    for &i in &a {
        keep[i] = true;
    }
    for k in 0..a.len() {
        let (s, e) = (a[k], a[(k + 1) % a.len()]);
        let len = (e + n - s) % n;
        let len = if len == 0 { n } else { len };
        let ring: Vec<Pt> = (0..=len).map(|j| pts[(s + j) % n]).collect();
        let mut kr = vec![false; ring.len()];
        dp_open(&ring, 0, len, eps, &mut kr);
        for (j, &kept) in kr.iter().enumerate().take(len).skip(1) {
            if kept {
                keep[(s + j) % n] = true;
            }
        }
    }
    (0..n).filter(|&i| keep[i]).collect()
}

/// Smoothing along the traced contours, source px (see [`smooth_along`]). The source is a
/// binary (aliased) raster, so its 50% iso-line is a pixel staircase; a Gaussian of 1 px along
/// the contour removes steps of 1-2 px period (to under 1% of their size) while bulges and necks
/// of 8 px or more keep at least 73% of theirs. Measured against the source at 4x, 0.75 leaves
/// visible steps and 1.5 drops IoU below 0.975.
pub const TRACE_SMOOTH: f64 = 1.0;
/// Supersampling of the source field before tracing.
pub const TRACE_SCALE: usize = 4;
/// Douglas-Peucker tolerance of the smoothed outline, source px. It only drops vertices that sit
/// on a straight run; 0.1 keeps IoU within 0.002 of the unsimplified contour, while 0.2 and up
/// raise the Hausdorff distance.
pub const TRACE_EPS: f64 = 0.1;
/// A source corner tags the nearest traced vertex sharp when it is at most this far, source px.
const CORNER_SNAP: f64 = 1.5;
/// Smallest side-stroke area, source px squared (smaller pieces are specks).
const MIN_STROKE_AREA: f64 = 20.0;

fn centroid(c: &[Pt]) -> Pt {
    let n = c.len() as f64;
    (
        c.iter().map(|p| p.0).sum::<f64>() / n,
        c.iter().map(|p| p.1).sum::<f64>() / n,
    )
}

/// Smooths a closed contour along its arc length with a Gaussian of `sigma` source px, keeping
/// the `anchors` (vertex indices) fixed. Each stretch between two anchors is smoothed as an open
/// curve, extended past its ends by point reflection through the anchor, so a straight run
/// through an anchor stays straight and the anchor is not rounded off. Without anchors the
/// contour wraps around.
pub fn smooth_along(pts: &[Pt], anchors: &[usize], sigma: f64) -> Vec<Pt> {
    let n = pts.len();
    if sigma <= 0.0 || n < 4 {
        return pts.to_vec();
    }
    let reach = 3.0 * sigma;
    let dist = |a: Pt, b: Pt| (a.0 - b.0).hypot(a.1 - b.1);
    let avg = |ext: &[(f64, Pt)], s0: f64| {
        let (mut w, mut x, mut y) = (0.0, 0.0, 0.0);
        for &(s, p) in ext {
            let d = s - s0;
            if d.abs() <= reach {
                let k = (-d * d / (2.0 * sigma * sigma)).exp();
                (w, x, y) = (w + k, x + k * p.0, y + k * p.1);
            }
        }
        (x / w, y / w)
    };
    let mut out = pts.to_vec();
    let mut a: Vec<usize> = anchors.iter().copied().filter(|&i| i < n).collect();
    a.sort_unstable();
    a.dedup();
    if a.is_empty() {
        // Closed loop: arc lengths with one copy of the loop on either side.
        let mut arc = vec![0.0; n];
        for i in 1..n {
            arc[i] = arc[i - 1] + dist(pts[i - 1], pts[i]);
        }
        let total = arc[n - 1] + dist(pts[n - 1], pts[0]);
        let arc_ref = &arc;
        let ext: Vec<(f64, Pt)> = [-total, 0.0, total]
            .iter()
            .flat_map(|off| (0..n).map(move |i| (arc_ref[i] + off, pts[i])))
            .collect();
        for (o, s0) in out.iter_mut().zip(&arc) {
            *o = avg(&ext, *s0);
        }
        return out;
    }
    for k in 0..a.len() {
        let (s, e) = (a[k], a[(k + 1) % a.len()]);
        let len = match (e + n - s) % n {
            0 => n,
            l => l,
        };
        let seg: Vec<Pt> = (0..=len).map(|j| pts[(s + j) % n]).collect();
        let mut arc = vec![0.0; seg.len()];
        for j in 1..seg.len() {
            arc[j] = arc[j - 1] + dist(seg[j - 1], seg[j]);
        }
        let (p0, pm, sm) = (seg[0], seg[len], arc[len]);
        let mut ext: Vec<(f64, Pt)> = Vec::new();
        for j in (1..=len).rev() {
            ext.push((-arc[j], (2.0 * p0.0 - seg[j].0, 2.0 * p0.1 - seg[j].1)));
        }
        ext.extend(arc.iter().copied().zip(seg.iter().copied()));
        for j in (0..len).rev() {
            ext.push((
                2.0 * sm - arc[j],
                (2.0 * pm.0 - seg[j].0, 2.0 * pm.1 - seg[j].1),
            ));
        }
        for j in 1..len {
            out[(s + j) % n] = avg(&ext, arc[j]);
        }
    }
    out
}

/// Tracing parameters, all in source px.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TraceParams {
    /// Gaussian smoothing along each contour between its corners (see [`smooth_along`]).
    pub smooth: f64,
    /// Douglas-Peucker tolerance.
    pub eps: f64,
}

/// The tracer defaults, chosen by measurement against the source.
pub const TRACE: TraceParams = TraceParams {
    smooth: TRACE_SMOOTH,
    eps: TRACE_EPS,
};

/// The traced contours as TOML vertex lists, smoothed, simplified and tagged. Each source corner
/// anchors the nearest vertex of whichever contour passes closest to it; that vertex is kept
/// exactly and tagged `c`.
fn tagged_contours(contours: &[&Vec<Pt>], p: &TraceParams, corners: &[Pt]) -> Vec<String> {
    let mut anchors: Vec<Vec<usize>> = vec![Vec::new(); contours.len()];
    for q in corners {
        let best = contours
            .iter()
            .enumerate()
            .flat_map(|(ci, c)| c.iter().enumerate().map(move |(vi, p)| (ci, vi, *p)))
            .map(|(ci, vi, p)| (ci, vi, (p.0 - q.0).hypot(p.1 - q.1)))
            .min_by(|a, b| a.2.total_cmp(&b.2));
        if let Some((ci, vi, d)) = best
            && d <= CORNER_SNAP
        {
            anchors[ci].push(vi);
        }
    }
    contours
        .iter()
        .zip(&anchors)
        .map(|(c, a)| {
            let c = smooth_along(c, a, p.smooth);
            let items: Vec<String> = simplify_anchored(&c, p.eps, a)
                .into_iter()
                .map(|i| {
                    let t = if a.contains(&i) { "c" } else { "s" };
                    format!("[{:.2}, {:.2}, \"{t}\"]", c[i].0, c[i].1)
                })
                .collect();
            items
                .chunks(4)
                .map(|ch| format!("  {},\n", ch.join(", ")))
                .collect()
        })
        .collect()
}

/// `mark.toml` text traced from `f` with the [`TRACE`] defaults (see [`trace_toml_with`]).
pub fn trace_toml(f: &Field) -> Result<String, String> {
    trace_toml_with(f, &TRACE)
}

/// `mark.toml` text traced from `f` at sub-pixel accuracy: the field is upsampled
/// [`TRACE_SCALE`] times (bicubic) and contoured at its 50% iso-level; the
/// source's corners are pinned, each contour is smoothed along its length (`p.smooth`) so the
/// pixel staircase of an aliased source becomes the edge it samples, and simplified with
/// Douglas-Peucker (`p.eps`). The largest piece becomes S01 (outline and holes, upper hole
/// first), every other piece an outline stroke, upper row then lower row, left to right.
pub fn trace_toml_with(f: &Field, p: &TraceParams) -> Result<String, String> {
    let k = TRACE_SCALE as f64;
    let field = upsample(f, TRACE_SCALE);
    let contours: Vec<Vec<Pt>> = trace_contours(&field, ISO_LEVEL)
        .into_iter()
        .map(|c| {
            c.into_iter()
                .map(|p| (p.0 / k, p.1 / k))
                .collect::<Vec<Pt>>()
        })
        .filter(|c| area(c).abs() >= MIN_CONTOUR_AREA)
        .collect();
    let main = contours
        .iter()
        .filter(|c| area(c) > 0.0)
        .max_by(|a, b| area(a).total_cmp(&area(b)))
        .ok_or("source has no ink")?;
    let top = |c: &[Pt]| c.iter().map(|p| p.1).fold(f64::MAX, f64::min);
    let mut holes: Vec<&Vec<Pt>> = contours
        .iter()
        .filter(|c| area(c) < 0.0 && point_in_poly(c[0], main))
        .collect();
    holes.sort_by(|a, b| top(a).total_cmp(&top(b)));
    let my = centroid(main).1;
    let mut strokes: Vec<&Vec<Pt>> = contours
        .iter()
        .filter(|c| !std::ptr::eq(*c, main) && area(c) >= MIN_STROKE_AREA)
        .collect();
    strokes.sort_by(|a, b| {
        let (ca, cb) = (centroid(a), centroid(b));
        (ca.1 > my).cmp(&(cb.1 > my)).then(ca.0.total_cmp(&cb.0))
    });
    let all: Vec<&Vec<Pt>> = std::iter::once(main)
        .chain(holes.iter().copied())
        .chain(strokes.iter().copied())
        .collect();
    let text = tagged_contours(&all, p, &source_corners(f));
    let mut s = String::from(
        "# Master glyph: the oracle-bone character \u{7387}, traced by `icongen trace` from\n# brand/source/oracle-rate.png: upsampled 4x (bicubic), contoured at the 50% iso-level, smoothed\n# along each contour between the carved corners (pixel staircase removed) and simplified.\n# Coordinates are source pixels (y down), so weight 0 overlays the source 1:1.\n# Vertex tag: \"c\" sharp (a carved corner, kept exactly), \"s\" smooth.\n\n[s01]\noutline = [\n",
    );
    s.push_str(&text[0]);
    s.push_str("]\nholes = [\n");
    for h in &text[1..=holes.len()] {
        s.push_str(&format!("  [\n{h}  ],\n"));
    }
    s.push_str("]\n");
    for (i, t) in text[1 + holes.len()..].iter().enumerate() {
        s.push_str(&format!(
            "\n[[stroke]]\nid = \"S{:02}\"\noutline = [\n{t}]\n",
            i + 2
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

/// Master gates: IoU, Hausdorff (source px), area difference and per-piece IoU are measured
/// against [`reference_mask`] at [`MEASURE_SCALE`].
pub const GATE_IOU: f64 = 0.975;
pub const GATE_HAUSDORFF: f64 = 1.0;
pub const GATE_CORNERS: f64 = 0.9;
pub const GATE_PIECE_IOU: f64 = 0.96;
pub const GATE_AREA: f64 = 0.01;

#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub iou: f64,
    pub hausdorff: f64,
    /// Ink area of the glyph relative to the source: `(glyph - source) / source`.
    pub area_diff: f64,
    /// IoU of each piece against the source piece it overlaps most, in drawing order.
    pub piece_iou: Vec<(String, f64)>,
    pub corners_total: usize,
    pub corners_kept: f64,
    pub pieces: usize,
    pub holes: usize,
    pub model_holes: usize,
    pub model_strokes: usize,
    /// Ink pixels of the source and of the glyph render; either being 0 is a failed evaluation
    /// (the IoU of two empty masks is 1.0, which must not pass).
    pub src_ink: usize,
    pub glyph_ink: usize,
    /// Renders at 120, 60 and 40 px.
    pub small: Vec<SmallSize>,
}

fn ink(m: &Mask) -> usize {
    m.data.iter().filter(|&&b| b).count()
}

/// Measures `glyph` (at stroke `weight`) against the source field: the master is rendered at
/// [`MEASURE_SCALE`] and compared with the source's 50% iso-level at the same scale.
pub fn evaluate(glyph: &Glyph, weight: f64, source: &Field) -> Report {
    let k = MEASURE_SCALE;
    let src = reference_mask(source, k);
    let g = rasterize(glyph, weight, source.width, source.height, k as f64);
    let corners = source_corners(source);
    let (lab, n) = label(src.width, src.height, &|i| src.data[i], true);
    let map = |p: Pt| (p.0 * k as f64, p.1 * k as f64);
    let piece_iou = glyph
        .pieces(weight)
        .into_iter()
        .map(|p| {
            let m = pieces_mask(std::slice::from_ref(&p), (src.width, src.height), &map);
            let mut overlap = vec![0usize; n as usize + 1];
            for (&l, &on) in lab.iter().zip(&m.data) {
                if on {
                    overlap[l as usize] += 1;
                }
            }
            let best = (1..overlap.len()).max_by_key(|&l| overlap[l]).unwrap_or(0);
            let comp = Mask {
                width: src.width,
                height: src.height,
                data: lab
                    .iter()
                    .map(|&l| l as usize == best && best > 0)
                    .collect(),
            };
            (p.id, iou(&m, &comp))
        })
        .collect();
    let src_ink = ink(&src).max(1) as f64;
    Report {
        iou: iou(&src, &g),
        hausdorff: hausdorff(&src, &g) / k as f64,
        area_diff: (ink(&g) as f64 - src_ink) / src_ink,
        piece_iou,
        corners_total: corners.len(),
        corners_kept: corners_kept(&corners, glyph, weight),
        pieces: components(&g),
        holes: holes(&g),
        model_holes: glyph.holes.len(),
        model_strokes: glyph.strokes.len(),
        src_ink: ink(&src),
        glyph_ink: ink(&g),
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
    if r.src_ink == 0 || r.glyph_ink == 0 {
        f.push(format!(
            "empty render: source ink {} px, glyph ink {} px",
            r.src_ink, r.glyph_ink
        ));
    }
    if r.iou < GATE_IOU {
        f.push(format!("IoU {:.4} < {GATE_IOU}", r.iou));
    }
    if r.hausdorff > GATE_HAUSDORFF {
        f.push(format!(
            "Hausdorff {:.2} px > {GATE_HAUSDORFF}",
            r.hausdorff
        ));
    }
    if r.area_diff.abs() > GATE_AREA {
        f.push(format!(
            "area difference {:+.2}% beyond +-{}%",
            r.area_diff * 100.0,
            GATE_AREA * 100.0
        ));
    }
    for (id, v) in &r.piece_iou {
        if *v < GATE_PIECE_IOU {
            f.push(format!("per-piece IoU {id} {v:.4} < {GATE_PIECE_IOU}"));
        }
    }
    if r.corners_kept < GATE_CORNERS {
        f.push(format!(
            "corners kept {:.2} < {GATE_CORNERS:.2}",
            r.corners_kept
        ));
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
    row(
        &format!("IoU ({MEASURE_SCALE}x)"),
        format!("{:.4}", r.iou),
        &format!(">= {GATE_IOU}"),
    );
    row(
        "Hausdorff (source px)",
        format!("{:.2}", r.hausdorff),
        &format!("<= {GATE_HAUSDORFF}"),
    );
    row(
        "area difference",
        format!("{:+.2}%", r.area_diff * 100.0),
        &format!("within +-{}%", GATE_AREA * 100.0),
    );
    for (id, v) in &r.piece_iou {
        row(
            &format!("IoU {id}"),
            format!("{v:.4}"),
            &format!(">= {GATE_PIECE_IOU}"),
        );
    }
    row(
        "corners kept",
        format!("{:.2} of {}", r.corners_kept, r.corners_total),
        &format!(">= {GATE_CORNERS:.2}"),
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
/// Smallest share of its master area a hole keeps at a theme's weight, so the counters still read
/// as the source's (a full-weight shrink leaves the lower hole about half its size).
pub const MIN_HOLE_SHARE: f64 = 0.6;

/// The mark as a theme draws it: its weight and scale, rendered at whole-icon sizes.
#[derive(Debug, Clone, PartialEq)]
pub struct ThemeCheck {
    pub name: String,
    pub weight: f64,
    /// One entry per [`THEME_SIZES`]; `px` is the icon size, the mark spans `scale * px`.
    pub sizes: Vec<SmallSize>,
    /// Areas of the S01 holes at the theme's weight, source px squared.
    pub hole_areas: Vec<f64>,
    /// Each hole's area as a share of its area in the master.
    pub hole_shares: Vec<f64>,
}

/// Renders the theme's mark (weight, small-size bonus, scale) at every [`THEME_SIZES`] icon size.
/// Pieces and holes come from the render at that size; the narrowest width comes from a render
/// supersampled to at least 640 px, so it reads in fractions of a pixel at that size.
pub fn check_theme(glyph: &Glyph, name: &str, mark: &MarkCfg) -> ThemeCheck {
    let sizes = THEME_SIZES
        .iter()
        .map(|&px| {
            let w = (mark.weight_at(px), mark.hole_weight_at(px));
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
    let hole_weight = mark.hole_weight.unwrap_or(mark.weight);
    let hole_areas: Vec<f64> = glyph.pieces_with(mark.weight, hole_weight)[0].contours[1..]
        .iter()
        .map(|h| polygon_area(h))
        .collect();
    let hole_shares = hole_areas
        .iter()
        .zip(&glyph.holes)
        .map(|(a, h)| a / polygon_area(h).max(1e-9))
        .collect();
    ThemeCheck {
        name: name.into(),
        weight: mark.weight,
        sizes,
        hole_areas,
        hole_shares,
    }
}

/// Themed gates: 5 pieces at every size, both holes at 1024 and 120 px, the narrowest piece at
/// least 2 px at 40 px, and every hole at least [`MIN_HOLE_AREA`] and [`MIN_HOLE_SHARE`] of its
/// master area.
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
    if c.hole_shares.iter().any(|&a| a < MIN_HOLE_SHARE) {
        f.push(format!(
            "{}: hole shares {:?} of the master (want each >= {MIN_HOLE_SHARE})",
            c.name, c.hole_shares
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
    let areas: Vec<String> = c
        .hole_areas
        .iter()
        .zip(&c.hole_shares)
        .map(|(a, s)| format!("{a:.0} ({:.0}%)", s * 100.0))
        .collect();
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
