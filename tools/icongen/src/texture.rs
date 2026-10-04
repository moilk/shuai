//! Oracle-bone rubbing texture: grain, branching cracks and scratched margin motifs.
//!
//! Everything is drawn from the in-tree PCG32. Each element class (and each crack or motif)
//! owns its own stream, derived from `cfg.seed`, so changing one count never reshuffles the
//! rest. Cracks and motifs keep clear of the mark's bounding box grown by `cfg.keepout` (a
//! fraction of the canvas); grain is a canvas-wide surface noise and is only ever seen
//! around the mark because the mark is painted over it.
//!
//! Every shape is drawn in the single texture colour inside one group whose `opacity` is
//! `cfg.opacity`, so the ink never covers a pixel by more than that.

use crate::config::TextureCfg;
use crate::glyph::MarkBounds;
use crate::rng::Pcg32;
use crate::svg::fmt;
use std::f64::consts::PI;
use std::fmt::Write;

const CLASS_GRAIN: u64 = 1;
const CLASS_CRACK: u64 = 2;
const CLASS_MOTIF: u64 = 3;

/// Crack walks stay this far from the canvas edge so their width never leaves it.
const EDGE: f64 = 8.0;

type P = (f64, f64);

/// Stream for element `idx` of class `class`.
fn rng_for(cfg: &TextureCfg, class: u64, idx: u64) -> Pcg32 {
    Pcg32::new(cfg.seed, (class << 40) | idx)
}

#[derive(Clone, Copy)]
struct Rect {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
}

impl Rect {
    fn contains(&self, p: P) -> bool {
        p.0 > self.x0 && p.0 < self.x1 && p.1 > self.y0 && p.1 < self.y1
    }
    fn overlaps(&self, o: &Rect) -> bool {
        self.x0 < o.x1 && o.x0 < self.x1 && self.y0 < o.y1 && o.y0 < self.y1
    }
    fn grow(&self, d: f64) -> Rect {
        Rect {
            x0: self.x0 - d,
            y0: self.y0 - d,
            x1: self.x1 + d,
            y1: self.y1 + d,
        }
    }
}

fn pt(p: P) -> String {
    format!("{} {}", fmt(p.0), fmt(p.1))
}

/// SVG fragment (elements only, no `<svg>` wrapper) for the texture layer on a `size` px canvas.
/// Empty when the texture is disabled. Deterministic for a given config.
pub fn layer_svg(cfg: &TextureCfg, mark: &MarkBounds, size: u32) -> String {
    if !cfg.enabled {
        return String::new();
    }
    let s = f64::from(size);
    let keep = Rect {
        x0: mark.x0,
        y0: mark.y0,
        x1: mark.x1,
        y1: mark.y1,
    }
    .grow(cfg.keepout.max(0.0) * s);
    format!(
        "<g id=\"texture\" opacity=\"{}\" fill=\"{c}\">{}{}{}</g>",
        fmt(cfg.opacity),
        grain(cfg, s),
        cracks(cfg, s, &keep),
        motifs(cfg, s, &keep),
        c = cfg.color,
    )
}

// ---- grain ----

fn grain(cfg: &TextureCfg, s: f64) -> String {
    let mut rng = rng_for(cfg, CLASS_GRAIN, 0);
    let scale = s / 1024.0;
    let n = (cfg.grain.clamp(0.0, 1.0) * 9000.0 * scale * scale).round() as usize;
    // Three ink strengths, each its own path so the SVG stays small.
    let tiers = [0.22, 0.45, 0.8];
    let mut d = [String::new(), String::new(), String::new()];
    for _ in 0..n {
        let tier = match rng.next_f64() {
            v if v < 0.6 => 0,
            v if v < 0.9 => 1,
            _ => 2,
        };
        let (cx, cy) = (rng.range(0.0, s), rng.range(0.0, s));
        let r = rng.range(0.35, 1.5) * scale.max(0.25);
        let sides = 3 + (rng.next_u32() % 2) as usize;
        let rot = rng.range(0.0, 2.0 * PI);
        for k in 0..sides {
            let a = rot + 2.0 * PI * k as f64 / sides as f64 + rng.range(-0.4, 0.4);
            let rr = r * rng.range(0.6, 1.2);
            let p = (cx + rr * a.cos(), cy + rr * a.sin());
            let _ = write!(d[tier], "{}{}", if k == 0 { 'M' } else { 'L' }, pt(p));
        }
        d[tier].push('Z');
    }
    let mut out = String::from("<g id=\"grain\">");
    for (o, path) in tiers.iter().zip(&d) {
        if !path.is_empty() {
            let _ = write!(out, "<path fill-opacity=\"{}\" d=\"{path}\"/>", fmt(*o));
        }
    }
    out.push_str("</g>");
    out
}

// ---- cracks ----

/// Filled ribbon along `pts` of width `w0 * profile(t)` (t runs 0..1 along the line), appended as
/// a closed subpath. Filled shapes only, so the SVG needs no stroke attributes.
fn ribbon(pts: &[P], w0: f64, profile: fn(f64) -> f64, d: &mut String) {
    let n = pts.len();
    if n < 2 {
        return;
    }
    let (mut left, mut right) = (Vec::new(), Vec::new());
    for i in 0..n {
        let a = pts[i.saturating_sub(1)];
        let b = pts[(i + 1).min(n - 1)];
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let len = dx.hypot(dy).max(1e-9);
        let w = w0 * profile(i as f64 / (n - 1) as f64) / 2.0;
        let (nx, ny) = (-dy / len * w, dx / len * w);
        left.push((pts[i].0 + nx, pts[i].1 + ny));
        right.push((pts[i].0 - nx, pts[i].1 - ny));
    }
    for (k, p) in left.iter().chain(right.iter().rev()).enumerate() {
        let _ = write!(d, "{}{}", if k == 0 { 'M' } else { 'L' }, pt(*p));
    }
    d.push('Z');
}

/// Random-walk polyline from `start`; stops on leaving the canvas or entering `keep`.
fn walk(
    rng: &mut Pcg32,
    start: P,
    mut heading: f64,
    steps: usize,
    step: f64,
    s: f64,
    keep: &Rect,
) -> Vec<P> {
    let mut pts = vec![start];
    let mut cur = start;
    for _ in 0..steps {
        heading += rng.range(-0.4, 0.4);
        let len = step * rng.range(0.6, 1.3);
        let next = (cur.0 + len * heading.cos(), cur.1 + len * heading.sin());
        if next.0 < EDGE
            || next.1 < EDGE
            || next.0 > s - EDGE
            || next.1 > s - EDGE
            || keep.contains(next)
        {
            break;
        }
        pts.push(next);
        cur = next;
    }
    pts
}

fn cracks(cfg: &TextureCfg, s: f64, keep: &Rect) -> String {
    let w0 = s * 0.0035;
    // The walk checks centre points; pad so the offset polygon edges also stay clear.
    let keep = keep.grow(w0);
    let mut out = String::from("<g id=\"cracks\">");
    for i in 0..u64::from(cfg.cracks) {
        let mut rng = rng_for(cfg, CLASS_CRACK, i);
        let mut d = String::new();
        // Start in the margin band outside the keep-out box.
        let mut start = (rng.range(EDGE, s - EDGE), rng.range(EDGE, s - EDGE));
        for _ in 0..50 {
            if !keep.contains(start) {
                break;
            }
            start = (rng.range(EDGE, s - EDGE), rng.range(EDGE, s - EDGE));
        }
        let heading = rng.range(0.0, 2.0 * PI);
        let steps = 28 + (rng.next_u32() % 20) as usize;
        let step = s * 0.011;
        let main = walk(&mut rng, start, heading, steps, step, s, &keep);
        ribbon(&main, w0, |t| 1.0 - t, &mut d);
        // Branches from random points of the main crack.
        let branches = 1 + rng.next_u32() % 3;
        for _ in 0..branches {
            if main.len() < 6 {
                break;
            }
            let at = 1 + (rng.next_u32() as usize) % (main.len() - 3);
            let h = rng.range(-1.1, 1.1) + heading;
            let sub = walk(&mut rng, main[at], h, steps / 2, step * 0.8, s, &keep);
            ribbon(&sub, w0 * 0.6, |t| 1.0 - t, &mut d);
        }
        let _ = write!(out, "<path d=\"{d}\"/>");
    }
    out.push_str("</g>");
    out
}

// ---- motifs ----

type Template = &'static [&'static [P]];

/// Original stroke templates in a [-1, 1] box. Each is a set of polylines; none reproduces a
/// real oracle-bone character, they only borrow the angular, branching stroke vocabulary.
const TEMPLATES: [Template; 8] = [
    // sapling: trunk with three alternating twigs
    &[
        &[(0.0, 1.0), (0.0, -1.0)],
        &[(0.0, 0.4), (0.7, 0.0)],
        &[(0.0, 0.0), (-0.7, -0.4)],
        &[(0.0, -0.5), (0.6, -0.9)],
    ],
    // figure: head tick, arms, legs
    &[
        &[(0.0, -1.0), (0.0, 0.2)],
        &[(-0.8, -0.4), (0.0, -0.1), (0.8, -0.5)],
        &[(0.0, 0.2), (-0.6, 1.0)],
        &[(0.0, 0.2), (0.7, 0.9)],
    ],
    // comb: spine with four teeth
    &[
        &[(-0.9, -0.8), (-0.9, 0.8)],
        &[(-0.9, -0.6), (0.8, -0.6)],
        &[(-0.9, -0.2), (0.6, -0.2)],
        &[(-0.9, 0.2), (0.8, 0.2)],
        &[(-0.9, 0.6), (0.5, 0.6)],
    ],
    // fork: three-pronged stem
    &[
        &[(0.0, 1.0), (0.0, 0.0)],
        &[(-0.8, -1.0), (-0.7, -0.3), (0.0, 0.0)],
        &[(0.8, -0.9), (0.7, -0.3), (0.0, 0.0)],
        &[(0.0, -1.0), (0.0, 0.0)],
    ],
    // ladder: two rails, uneven rungs
    &[
        &[(-0.5, -1.0), (-0.6, 1.0)],
        &[(0.5, -1.0), (0.6, 1.0)],
        &[(-0.55, -0.6), (0.52, -0.5)],
        &[(-0.57, 0.0), (0.55, 0.1)],
        &[(-0.6, 0.6), (0.58, 0.55)],
    ],
    // chevrons: stacked down-pointing wedges
    &[
        &[(-0.9, -0.8), (0.0, -0.2), (0.9, -0.8)],
        &[(-0.9, -0.1), (0.0, 0.5), (0.9, -0.1)],
        &[(0.0, 0.5), (0.0, 1.0)],
    ],
    // hand: stem with a splayed five-way head
    &[
        &[(0.0, 1.0), (0.0, 0.1)],
        &[(0.0, 0.1), (-0.9, -0.5)],
        &[(0.0, 0.1), (-0.4, -0.95)],
        &[(0.0, 0.1), (0.2, -1.0)],
        &[(0.0, 0.1), (0.9, -0.4)],
    ],
    // cross-bar with ticks and a dotted base
    &[
        &[(-1.0, -0.2), (1.0, 0.0)],
        &[(0.1, -1.0), (-0.1, 0.8)],
        &[(-0.6, -0.2), (-0.7, -0.7)],
        &[(0.6, 0.0), (0.7, 0.5)],
        &[(-0.4, 0.95), (-0.3, 1.0)],
        &[(0.4, 0.95), (0.5, 1.0)],
    ],
];

/// Breaks a stroke into irregular dashes with a hand-wobble, as if scratched with a point.
fn scratch(rng: &mut Pcg32, a: P, b: P, jitter: f64, width: f64, d: &mut String) {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = dx.hypot(dy);
    let piece = (len / 6.0).max(1.0);
    let n = ((len / piece).ceil() as usize).max(1);
    let (nx, ny) = (-dy / len.max(1e-9), dx / len.max(1e-9));
    let mut i = 0;
    while i < n {
        let run = 2 + (rng.next_u32() % 4) as usize;
        let end = (i + run).min(n);
        let mut dash = Vec::new();
        for k in i..=end {
            let t = k as f64 / n as f64;
            let w = rng.range(-jitter, jitter);
            let p = (a.0 + dx * t + nx * w, a.1 + dy * t + ny * w);
            dash.push(p);
        }
        // Pointed at both ends, like a scratch that lifts off.
        ribbon(&dash, width, |t| (PI * t).sin().max(0.25), d);
        // Gap before the next dash, sometimes none (a continuous scratch).
        i = end + usize::from(rng.next_f64() < 0.4);
    }
}

fn motifs(cfg: &TextureCfg, s: f64, keep: &Rect) -> String {
    let stroke_w = s * 0.0055;
    let pad = stroke_w * 2.0;
    let mut placed: Vec<Rect> = Vec::new();
    let mut out = String::from("<g id=\"motifs\">");
    for i in 0..u64::from(cfg.motifs) {
        let mut rng = rng_for(cfg, CLASS_MOTIF, i);
        let tpl = TEMPLATES[(rng.next_u32() as usize) % TEMPLATES.len()];
        let half = s * rng.range(0.018, 0.03);
        let rot = rng.range(-0.6, 0.6) + if rng.next_f64() < 0.3 { PI / 2.0 } else { 0.0 };
        let (sin, cos) = rot.sin_cos();
        let aspect = (rng.range(0.8, 1.2), rng.range(0.8, 1.2));
        let mirror = if rng.next_f64() < 0.5 { -1.0 } else { 1.0 };
        let sw = stroke_w * rng.range(0.8, 1.25);
        let mut found = None;
        for _ in 0..600 {
            let c = (rng.range(0.0, s), rng.range(0.0, s));
            let place = move |p: P| {
                let (x, y) = (p.0 * mirror * half * aspect.0, p.1 * half * aspect.1);
                (c.0 + x * cos - y * sin, c.1 + x * sin + y * cos)
            };
            // Bound with the template's extreme corners plus the wobble allowance.
            let slack = half * 0.12 + pad;
            let mut bb = Rect {
                x0: f64::MAX,
                y0: f64::MAX,
                x1: f64::MIN,
                y1: f64::MIN,
            };
            for stroke in tpl {
                for &p in *stroke {
                    let q = place(p);
                    bb.x0 = bb.x0.min(q.0);
                    bb.y0 = bb.y0.min(q.1);
                    bb.x1 = bb.x1.max(q.0);
                    bb.y1 = bb.y1.max(q.1);
                }
            }
            let bb = bb.grow(slack);
            let inside = bb.x0 >= 0.0 && bb.y0 >= 0.0 && bb.x1 <= s && bb.y1 <= s;
            if inside && !bb.overlaps(keep) && !placed.iter().any(|r| r.overlaps(&bb)) {
                found = Some((place, bb));
                break;
            }
        }
        let Some((place, bb)) = found else { continue };
        placed.push(bb);
        let mut d = String::new();
        for stroke in tpl {
            for w in stroke.windows(2) {
                scratch(&mut rng, place(w[0]), place(w[1]), half * 0.05, sw, &mut d);
            }
        }
        let _ = write!(out, "<path d=\"{d}\"/>");
    }
    out.push_str("</g>");
    out
}
