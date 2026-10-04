//! Master glyph model (`brand/mark/mark.toml`) and its conversion to SVG path data.
//!
//! S01 is an outline polygon plus hole polygons (even-odd). S02..S05 are centerline strokes with
//! per-point widths and chisel end caps. Vertices are tagged sharp (`c`) or smooth (`s`).

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
    /// Centerline points `(x, y, width)`.
    pub points: Vec<(f64, f64, f64)>,
    pub cap_start: Cap,
    pub cap_end: Cap,
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
    points: Vec<(f64, f64, f64)>,
    #[serde(default)]
    cap_start: Cap,
    #[serde(default)]
    cap_end: Cap,
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
            if r.points.len() < 2 {
                return Err(format!("{}: stroke needs at least 2 points", r.id));
            }
            if r.points.iter().any(|p| p.2 <= 0.0) {
                return Err(format!("{}: widths must be positive", r.id));
            }
            strokes.push(Stroke {
                id: r.id,
                points: r.points,
                cap_start: r.cap_start,
                cap_end: r.cap_end,
            });
        }
        Ok(Glyph {
            outline,
            holes,
            strokes,
        })
    }

    /// All pieces in drawing order; `weight` (glyph units) widens every stroke.
    pub fn pieces(&self, weight: f64) -> Vec<Piece> {
        let mut out = vec![Piece {
            id: "S01".into(),
            contours: std::iter::once(self.outline.clone())
                .chain(self.holes.iter().cloned())
                .collect(),
            even_odd: true,
        }];
        for s in &self.strokes {
            out.push(Piece {
                id: s.id.clone(),
                contours: vec![stroke_outline(&s.points, s.cap_start, s.cap_end, weight)],
                even_odd: false,
            });
        }
        out
    }

    /// Ink bounding box in glyph units (vertex extents).
    pub fn bounds(&self, weight: f64) -> (f64, f64, f64, f64) {
        let mut b = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for v in self
            .pieces(weight)
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

/// Closed outline of a stroke: chisel caps are sharp vertices, side vertices are smooth.
pub fn stroke_outline(
    points: &[(f64, f64, f64)],
    cap_start: Cap,
    cap_end: Cap,
    weight: f64,
) -> Vec<Vertex> {
    let n = points.len();
    let half = |i: usize| ((points[i].2 + weight) / 2.0).max(0.05);
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
/// it; an edge between two sharp vertices is a straight line.
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
            let c1 = if ta == Tag::Sharp {
                a
            } else {
                (a.0 + (b.0 - prev.0) / 6.0, a.1 + (b.1 - prev.1) / 6.0)
            };
            let c2 = if tb == Tag::Sharp {
                b
            } else {
                (b.0 - (next.0 - a.0) / 6.0, b.1 - (next.1 - a.1) / 6.0)
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
