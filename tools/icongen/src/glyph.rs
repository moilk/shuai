//! Master glyph model (`brand/mark/mark.toml`) and its conversion to SVG path data.
//!
//! S01 is an outline polygon plus hole polygons (even-odd). S02..S05 are outline polygons too;
//! a stroke may instead be written as a centerline with per-point widths and chisel end caps,
//! which is converted to its outline when parsed. Vertices are tagged sharp (`c`) or smooth (`s`).

use crate::svg::fmt;
use serde::Deserialize;

pub type Pt = (f64, f64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    Sharp,
    Smooth,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Vertex {
    pub x: f64,
    pub y: f64,
    pub tag: Tag,
}

/// Chisel end cap: `cut` is the cut angle in degrees (0 = square), `asym` shifts the width between
/// the two corners (-1..1).
#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Cap {
    #[serde(default)]
    pub cut: f64,
    #[serde(default)]
    pub asym: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub id: String,
    /// Closed outline of the stroke at weight 0.
    pub outline: Vec<Vertex>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Glyph {
    pub outline: Vec<Vertex>,
    pub holes: Vec<Vec<Vertex>>,
    pub strokes: Vec<Stroke>,
}

/// One logical piece: closed contours drawn as a single path.
#[derive(Debug, Clone, PartialEq)]
pub struct Piece {
    pub id: String,
    pub contours: Vec<Vec<Vertex>>,
    pub even_odd: bool,
}

/// Bounding box of the placed mark in output pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MarkBounds {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
}

/// One closed-polygon edge, a line (`c1`/`c2` are `None`) or a cubic Bezier.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Seg {
    pub a: Pt,
    pub b: Pt,
    pub c1: Option<Pt>,
    pub c2: Option<Pt>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawGlyph {
    s01: RawS01,
    stroke: Vec<RawStroke>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawS01 {
    outline: Vec<(f64, f64, String)>,
    holes: Vec<Vec<(f64, f64, String)>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawStroke {
    id: String,
    /// Outline polygon, as the S01 outline.
    #[serde(default)]
    outline: Option<Vec<(f64, f64, String)>>,
    /// Centerline `(x, y, width)` points (alternative to `outline`).
    #[serde(default)]
    points: Option<Vec<(f64, f64, f64)>>,
    #[serde(default)]
    cap_start: Option<Cap>,
    #[serde(default)]
    cap_end: Option<Cap>,
}

fn contour(raw: &[(f64, f64, String)], what: &str) -> Result<Vec<Vertex>, String> {
    if raw.len() < 3 {
        return Err(format!("{what}: needs at least 3 vertices"));
    }
    raw.iter()
        .map(|(x, y, t)| {
            let tag = match t.as_str() {
                "c" => Tag::Sharp,
                "s" => Tag::Smooth,
                other => return Err(format!("{what}: bad vertex tag {other:?}")),
            };
            Ok(Vertex { x: *x, y: *y, tag })
        })
        .collect()
}

impl Glyph {
    pub fn from_toml(s: &str) -> Result<Self, String> {
        let raw: RawGlyph = toml::from_str(s).map_err(|e| e.to_string())?;
        let outline = contour(&raw.s01.outline, "S01 outline")?;
        let holes = raw
            .s01
            .holes
            .iter()
            .enumerate()
            .map(|(i, h)| contour(h, &format!("S01 hole {i}")))
            .collect::<Result<Vec<_>, _>>()?;
        let mut strokes = Vec::new();
        for r in raw.stroke {
            let outline = match (&r.outline, &r.points) {
                (Some(o), None) => {
                    if r.cap_start.is_some() || r.cap_end.is_some() {
                        return Err(format!("{}: caps only apply to centerline points", r.id));
                    }
                    contour(o, &r.id)?
                }
                (None, Some(points)) => {
                    if points.len() < 2 {
                        return Err(format!("{}: stroke needs at least 2 points", r.id));
                    }
                    if points.iter().any(|p| p.2 <= 0.0) {
                        return Err(format!("{}: widths must be positive", r.id));
                    }
                    stroke_outline(
                        points,
                        r.cap_start.unwrap_or_default(),
                        r.cap_end.unwrap_or_default(),
                    )
                }
                _ => {
                    return Err(format!(
                        "{}: stroke needs exactly one of `outline` or `points`",
                        r.id
                    ));
                }
            };
            strokes.push(Stroke { id: r.id, outline });
        }
        Ok(Glyph {
            outline,
            holes,
            strokes,
        })
    }

    /// All pieces in drawing order. `weight` is a uniform outline offset in source pixels: every
    /// edge of every piece (S01 included) moves outward by `weight`, holes shrink by the same
    /// amount but never below [`MIN_HOLE_RADIUS`]. Weight 0 is the master geometry, unchanged.
    pub fn pieces(&self, weight: f64) -> Vec<Piece> {
        self.pieces_with(weight, weight)
    }

    /// As [`Glyph::pieces`], with the holes shrunk by `hole_weight` instead of `weight` (still
    /// never below [`MIN_HOLE_RADIUS`]), so a heavier mark keeps its counters open.
    pub fn pieces_with(&self, weight: f64, hole_weight: f64) -> Vec<Piece> {
        let grow = |c: &[Vertex]| {
            if weight == 0.0 {
                c.to_vec()
            } else {
                offset_contour(c, weight)
            }
        };
        let shrink = |h: &[Vertex]| {
            if hole_weight <= 0.0 {
                // Nothing to shrink: skip the inscribed-radius grid scan.
                return h.to_vec();
            }
            let d = hole_weight.min((inscribed_radius(h) - MIN_HOLE_RADIUS).max(0.0));
            if d <= 0.0 {
                h.to_vec()
            } else {
                offset_contour(h, -d)
            }
        };
        let mut out = vec![Piece {
            id: "S01".into(),
            contours: std::iter::once(grow(&self.outline))
                .chain(self.holes.iter().map(|h| shrink(h)))
                .collect(),
            even_odd: true,
        }];
        for s in &self.strokes {
            out.push(Piece {
                id: s.id.clone(),
                contours: vec![grow(&s.outline)],
                even_odd: false,
            });
        }
        out
    }

    /// Ink bounding box in glyph units (vertex extents).
    pub fn bounds(&self, weight: f64) -> (f64, f64, f64, f64) {
        let mut b = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        // Holes lie inside the outline, so they never change the extents: leave them unshrunk
        // and skip the inscribed-radius scan.
        for v in self
            .pieces_with(weight, 0.0)
            .iter()
            .flat_map(|p| p.contours.iter().flatten())
        {
            b = (b.0.min(v.x), b.1.min(v.y), b.2.max(v.x), b.3.max(v.y));
        }
        b
    }
}

fn norm(v: Pt) -> Pt {
    let l = v.0.hypot(v.1);
    if l == 0.0 {
        (1.0, 0.0)
    } else {
        (v.0 / l, v.1 / l)
    }
}

/// Longest miter at a convex corner, as a multiple of the offset; sharper corners are clipped
/// there (two sharp vertices) so a chisel tip does not grow into a needle.
pub const MITER_LIMIT: f64 = 2.0;
/// Longest miter at a concave corner, where the miter is the exact offset but a needle-thin notch
/// would otherwise throw its vertex far away.
const CONCAVE_MITER_LIMIT: f64 = 4.0;
/// Smallest inscribed radius (source px) a hole keeps when the outline offset shrinks it.
pub const MIN_HOLE_RADIUS: f64 = 2.5;

fn signed_area(poly: &[Vertex]) -> f64 {
    let n = poly.len();
    (0..n)
        .map(|i| {
            let (a, b) = (poly[i], poly[(i + 1) % n]);
            a.x * b.y - b.x * a.y
        })
        .sum::<f64>()
        / 2.0
}

/// Area of a closed vertex polygon (straight edges), always non-negative.
pub fn polygon_area(poly: &[Vertex]) -> f64 {
    signed_area(poly).abs()
}

fn dot(a: Pt, b: Pt) -> f64 {
    a.0 * b.0 + a.1 * b.1
}

/// Offsets a closed contour by `d` source px along its normals: `d > 0` grows the region the
/// contour encloses, `d < 0` shrinks it (either winding). Each vertex keeps its tag. A convex
/// corner whose miter would exceed [`MITER_LIMIT`] is clipped: a sharp vertex becomes two sharp
/// vertices on the clip line, a smooth one is pulled in to the limit.
pub fn offset_contour(poly: &[Vertex], d: f64) -> Vec<Vertex> {
    let n = poly.len();
    if n < 3 || d == 0.0 {
        return poly.to_vec();
    }
    let sigma = signed_area(poly).signum();
    let at = |i: usize| (poly[i % n].x, poly[i % n].y);
    // Outward normal of a unit edge direction.
    let outward = |u: Pt| (sigma * u.1, -sigma * u.0);
    // Offset vertices with the range of source vertices each one stands for.
    let mut out: Vec<(Vertex, usize, usize)> = Vec::with_capacity(n + 4);
    for (i, vi) in poly.iter().enumerate() {
        let (p0, p, p1) = (at(i + n - 1), at(i), at(i + 1));
        let u0 = norm((p.0 - p0.0, p.1 - p0.1));
        let u1 = norm((p1.0 - p.0, p1.1 - p.1));
        let (n0, n1) = (outward(u0), outward(u1));
        let sum = (n0.0 + n1.0, n0.1 + n1.1);
        let tag = vi.tag;
        let vtx = |q: Pt, tag: Tag| {
            (
                Vertex {
                    x: q.0,
                    y: q.1,
                    tag,
                },
                i,
                i,
            )
        };
        if sum.0.hypot(sum.1) < 1e-9 {
            // Edge doubles back on itself: square it off.
            out.push(vtx((p.0 + n0.0 * d, p.1 + n0.1 * d), Tag::Sharp));
            out.push(vtx((p.0 + n1.0 * d, p.1 + n1.1 * d), Tag::Sharp));
            continue;
        }
        let m = norm(sum);
        let cos = dot(m, n0).max(1e-9);
        let k = 1.0 / cos;
        let turn = u0.0 * u1.1 - u0.1 * u1.0;
        let spiky = sigma * turn * d > 0.0;
        if spiky && k > MITER_LIMIT {
            let lim = MITER_LIMIT * d.abs();
            let dir = (m.0 * d.signum(), m.1 * d.signum());
            let clip = |nn: Pt, u: Pt| -> Option<Pt> {
                let q = (p.0 + nn.0 * d, p.1 + nn.1 * d);
                let ud = dot(u, dir);
                if ud.abs() < 1e-9 {
                    return None;
                }
                let t = (lim - dot((q.0 - p.0, q.1 - p.1), dir)) / ud;
                Some((q.0 + u.0 * t, q.1 + u.1 * t))
            };
            match (tag, clip(n0, u0), clip(n1, u1)) {
                (Tag::Sharp, Some(a), Some(b)) => {
                    out.push(vtx(a, Tag::Sharp));
                    out.push(vtx(b, Tag::Sharp));
                }
                _ => out.push(vtx((p.0 + dir.0 * lim, p.1 + dir.1 * lim), tag)),
            }
        } else {
            let k = if spiky { k } else { k.min(CONCAVE_MITER_LIMIT) };
            out.push(vtx((p.0 + m.0 * d * k, p.1 + m.1 * d * k), tag));
        }
    }
    collapse_reversed(&mut out, poly);
    remove_loops(out.into_iter().map(|e| e.0).collect(), sigma)
}

/// Proper crossing point of segments `ab` and `cd`, if any.
fn cross_point(a: Pt, b: Pt, c: Pt, d: Pt) -> Option<Pt> {
    let r = (b.0 - a.0, b.1 - a.1);
    let s = (d.0 - c.0, d.1 - c.1);
    let den = r.0 * s.1 - r.1 * s.0;
    if den.abs() < 1e-12 {
        return None;
    }
    let qp = (c.0 - a.0, c.1 - a.1);
    let t = (qp.0 * s.1 - qp.1 * s.0) / den;
    let u = (qp.0 * r.1 - qp.1 * r.0) / den;
    (t > 1e-9 && t < 1.0 - 1e-9 && u > 1e-9 && u < 1.0 - 1e-9)
        .then_some((a.0 + t * r.0, a.1 + t * r.1))
}

/// Cuts self-intersection loops out of an offset contour: where two edges cross (a part narrower
/// than twice the offset, such as a hole's thin tail), the contour splits at the crossing and the
/// larger part with the original winding `sigma` is kept, pinched to a sharp vertex there.
fn remove_loops(mut poly: Vec<Vertex>, sigma: f64) -> Vec<Vertex> {
    'outer: while poly.len() > 3 {
        let n = poly.len();
        let p = |i: usize| (poly[i % n].x, poly[i % n].y);
        for i in 0..n {
            for j in i + 2..n {
                if i == 0 && j == n - 1 {
                    continue;
                }
                let Some(x) = cross_point(p(i), p(i + 1), p(j), p(j + 1)) else {
                    continue;
                };
                let pin = Vertex {
                    x: x.0,
                    y: x.1,
                    tag: Tag::Sharp,
                };
                let a: Vec<Vertex> = std::iter::once(pin)
                    .chain(poly[i + 1..=j].iter().copied())
                    .collect();
                let b: Vec<Vertex> = std::iter::once(pin)
                    .chain(poly[j + 1..].iter().copied())
                    .chain(poly[..=i].iter().copied())
                    .collect();
                let score = |c: &[Vertex]| {
                    let s = signed_area(c);
                    if c.len() >= 3 && s * sigma > 0.0 {
                        s.abs()
                    } else {
                        -1.0
                    }
                };
                poly = if score(&a) >= score(&b) { a } else { b };
                continue 'outer;
            }
        }
        break;
    }
    poly
}

/// Merges offset edges that flipped direction (an edge shorter than the offset shrinks past
/// zero) into one vertex at their midpoint, sharp if either end was, until none is left.
fn collapse_reversed(out: &mut Vec<(Vertex, usize, usize)>, poly: &[Vertex]) {
    while out.len() > 3 {
        let m = out.len();
        let flipped = (0..m).find(|&j| {
            let (a, b) = (&out[j], &out[(j + 1) % m]);
            if a.2 == b.1 {
                return false;
            }
            let (s, e) = (poly[a.2], poly[b.1]);
            dot((b.0.x - a.0.x, b.0.y - a.0.y), (e.x - s.x, e.y - s.y)) < 0.0
        });
        let Some(j) = flipped else { return };
        let k = (j + 1) % m;
        let (a, b) = (out[j], out[k]);
        let tag = if a.0.tag == Tag::Sharp || b.0.tag == Tag::Sharp {
            Tag::Sharp
        } else {
            Tag::Smooth
        };
        let merged = (
            Vertex {
                x: (a.0.x + b.0.x) / 2.0,
                y: (a.0.y + b.0.y) / 2.0,
                tag,
            },
            a.1,
            b.2,
        );
        out[j] = merged;
        out.remove(k);
    }
}

fn point_in(p: Pt, poly: &[Vertex]) -> bool {
    let n = poly.len();
    let mut inside = false;
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        if (a.y > p.1) != (b.y > p.1) && p.0 < (b.x - a.x) * (p.1 - a.y) / (b.y - a.y) + a.x {
            inside = !inside;
        }
    }
    inside
}

fn seg_dist(p: Pt, a: Pt, b: Pt) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0.0 {
        0.0
    } else {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0)
    };
    (p.0 - a.0 - t * dx).hypot(p.1 - a.1 - t * dy)
}

/// Radius of the largest circle inside a closed vertex polygon (straight edges), sampled on a
/// 0.1 px grid.
pub fn inscribed_radius(poly: &[Vertex]) -> f64 {
    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for v in poly {
        (x0, y0, x1, y1) = (x0.min(v.x), y0.min(v.y), x1.max(v.x), y1.max(v.y));
    }
    const STEP: f64 = 0.1;
    let n = poly.len();
    let mut best = 0.0f64;
    let mut y = y0;
    while y <= y1 {
        let mut x = x0;
        while x <= x1 {
            if point_in((x, y), poly) {
                let d = (0..n)
                    .map(|i| {
                        let (a, b) = (poly[i], poly[(i + 1) % n]);
                        seg_dist((x, y), (a.x, a.y), (b.x, b.y))
                    })
                    .fold(f64::MAX, f64::min);
                best = best.max(d);
            }
            x += STEP;
        }
        y += STEP;
    }
    best
}

/// Closed outline of a stroke: chisel caps are sharp vertices, side vertices are smooth. The
/// outline is the master carving; extra weight is applied afterwards by [`Glyph::pieces`] as a
/// uniform outward offset like every other piece. Bends sharper than about 60 degrees are not
/// cleaned of self-intersection loops (see docs/development/icon.md).
pub fn stroke_outline(points: &[(f64, f64, f64)], cap_start: Cap, cap_end: Cap) -> Vec<Vertex> {
    let n = points.len();
    let half = |i: usize| (points[i].2 / 2.0).max(0.05);
    let dir = |i: usize| norm((points[i + 1].0 - points[i].0, points[i + 1].1 - points[i].1));
    let left_normal = |d: Pt| (-d.1, d.0);
    let sharp = |p: Pt| Vertex {
        x: p.0,
        y: p.1,
        tag: Tag::Sharp,
    };
    // Cap corners: (on the left of travel, on the right of travel).
    let cap = |i: usize, d_out: Pt, nl: Pt, c: Cap| -> (Vertex, Vertex) {
        let h = half(i);
        let t = h * c.cut.to_radians().tan();
        let (px, py) = (points[i].0, points[i].1);
        let l = (
            px + nl.0 * h * (1.0 + c.asym) + d_out.0 * t,
            py + nl.1 * h * (1.0 + c.asym) + d_out.1 * t,
        );
        let r = (
            px - nl.0 * h * (1.0 - c.asym) - d_out.0 * t,
            py - nl.1 * h * (1.0 - c.asym) - d_out.1 * t,
        );
        (sharp(l), sharp(r))
    };
    let d_first = dir(0);
    let d_last = dir(n - 2);
    let (sa, sb) = cap(0, (-d_first.0, -d_first.1), left_normal(d_first), cap_start);
    let (ea, eb) = cap(n - 1, d_last, left_normal(d_last), cap_end);

    let mut left = Vec::new();
    let mut right = Vec::new();
    #[allow(clippy::needless_range_loop)]
    for i in 1..n - 1 {
        let n0 = left_normal(dir(i - 1));
        let n1 = left_normal(dir(i));
        let m = norm((n0.0 + n1.0, n0.1 + n1.1));
        let cos = (m.0 * n0.0 + m.1 * n0.1).max(0.5);
        let k = half(i) / cos;
        left.push(Vertex {
            x: points[i].0 + m.0 * k,
            y: points[i].1 + m.1 * k,
            tag: Tag::Smooth,
        });
        right.push(Vertex {
            x: points[i].0 - m.0 * k,
            y: points[i].1 - m.1 * k,
            tag: Tag::Smooth,
        });
    }
    let mut out = vec![sa];
    out.extend(left);
    out.push(ea);
    out.push(eb);
    out.extend(right.into_iter().rev());
    out.push(sb);
    out
}

/// Edges of a closed polygon. A sharp vertex has no Bezier handle, so no curve ever bends across
/// it; an edge between two sharp vertices is a straight line. Smooth vertices get Catmull-Rom
/// tangents with handles a third of the edge length, so curves through dense vertices never
/// overshoot into loops.
pub fn segments(poly: &[Vertex]) -> Vec<Seg> {
    let n = poly.len();
    let p = |i: usize| (poly[i % n].x, poly[i % n].y);
    (0..n)
        .map(|i| {
            let (prev, a, b, next) = (p(i + n - 1), p(i), p(i + 1), p(i + 2));
            let (ta, tb) = (poly[i].tag, poly[(i + 1) % n].tag);
            if ta == Tag::Sharp && tb == Tag::Sharp {
                return Seg {
                    a,
                    b,
                    c1: None,
                    c2: None,
                };
            }
            // Catmull-Rom tangent direction, but each handle is a third of its own edge: on
            // unevenly spaced vertices a long neighbour cannot push a short edge into a loop.
            let h = (b.0 - a.0).hypot(b.1 - a.1) / 3.0;
            let c1 = if ta == Tag::Sharp {
                a
            } else {
                let t = norm((b.0 - prev.0, b.1 - prev.1));
                (a.0 + t.0 * h, a.1 + t.1 * h)
            };
            let c2 = if tb == Tag::Sharp {
                b
            } else {
                let t = norm((next.0 - a.0, next.1 - a.1));
                (b.0 - t.0 * h, b.1 - t.1 * h)
            };
            Seg {
                a,
                b,
                c1: Some(c1),
                c2: Some(c2),
            }
        })
        .collect()
}

/// SVG path data of a closed contour, mapping glyph units through `map`.
pub fn contour_path(poly: &[Vertex], map: &dyn Fn(Pt) -> Pt) -> String {
    let segs = segments(poly);
    let f = |p: Pt| {
        let q = map(p);
        format!("{} {}", fmt(q.0), fmt(q.1))
    };
    let mut d = format!("M{}", f(segs[0].a));
    for s in &segs {
        match (s.c1, s.c2) {
            (Some(c1), Some(c2)) => d.push_str(&format!("C{} {} {}", f(c1), f(c2), f(s.b))),
            _ => d.push_str(&format!("L{}", f(s.b))),
        }
    }
    d.push('Z');
    d
}
