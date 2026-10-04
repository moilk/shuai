//! Oracle-bone rubbing texture: a mottled stone tone, grain, a branching crack network and
//! character-scale scratched figures in the side margins.
//!
//! Everything is drawn from the in-tree PCG32. Each element class (and each crack, motif or
//! stone patch) owns its own stream, derived from `cfg.seed`, so changing one count never
//! reshuffles the rest. Cracks and motifs keep clear of the mark's bounding box grown by
//! `cfg.keepout` (a fraction of the canvas); stone and grain are canvas-wide surface noise and
//! are only seen around the mark because the mark is painted over them.
//!
//! Every shape is a filled path in the single texture colour inside one group whose `opacity`
//! is `cfg.opacity`, so the ink never covers a pixel by more than that. Tone inside the group
//! comes from per-path `fill-opacity` (always at most 1), never from a higher group opacity.

use crate::config::TextureCfg;
use crate::glyph::MarkBounds;
use crate::rng::Pcg32;
use crate::svg::fmt;
use std::f64::consts::PI;
use std::fmt::Write;

const CLASS_GRAIN: u64 = 1;
const CLASS_CRACK: u64 = 2;
const CLASS_MOTIF: u64 = 3;
const CLASS_STONE: u64 = 4;

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
        "<g id=\"texture\" opacity=\"{}\" fill=\"{c}\">{}{}{}{}</g>",
        fmt(cfg.opacity),
        stone(cfg, s),
        grain(cfg, s),
        cracks(cfg, s, &keep),
        motifs(cfg, s, &keep),
        c = cfg.color,
    )
}

// ---- stone ----

/// Closed irregular blob around `c`: radius `r` modulated by one factor per vertex, scaled by `k`
/// so concentric rings share one outline.
fn blob(c: P, r: f64, radii: &[f64], rot: f64, k: f64, d: &mut String) {
    let n = radii.len();
    for (j, f) in radii.iter().enumerate() {
        let a = rot + 2.0 * PI * j as f64 / n as f64;
        let rr = r * f * k;
        let p = (c.0 + rr * a.cos(), c.1 + rr * a.sin() * 0.8);
        let _ = write!(d, "{}{}", if j == 0 { 'M' } else { 'L' }, pt(p));
    }
    d.push('Z');
}

/// Mottled tone: big soft washes, mid patches built from concentric rings (each ring its own
/// low-alpha path, so the centre reads brighter than the rim), clustered pitting and flecks.
fn stone(cfg: &TextureCfg, s: f64) -> String {
    let scale = s / 1024.0;
    // (ring scale, alpha) per tier; paths stack, so the tiers form a soft falloff.
    let wash_tiers = [
        (1.0, 0.035),
        (0.8, 0.035),
        (0.6, 0.035),
        (0.4, 0.035),
        (0.2, 0.035),
    ];
    let patch_tiers = [(1.0, 0.07), (0.75, 0.07), (0.5, 0.07), (0.25, 0.08)];
    let mut wash: [String; 5] = Default::default();
    let mut patch: [String; 4] = Default::default();
    let mut pits = String::new();
    let mut flecks = String::new();
    let mut idx = 0;
    for _ in 0..14 {
        let mut rng = rng_for(cfg, CLASS_STONE, idx);
        idx += 1;
        let c = (rng.range(0.0, s), rng.range(0.0, s));
        let r = rng.range(110.0, 240.0) * scale;
        let radii: Vec<f64> = (0..16).map(|_| rng.range(0.75, 1.2)).collect();
        let rot = rng.range(0.0, PI);
        for (t, (k, _)) in wash_tiers.iter().enumerate() {
            blob(c, r, &radii, rot, *k, &mut wash[t]);
        }
    }
    for _ in 0..230 {
        let mut rng = rng_for(cfg, CLASS_STONE, idx);
        idx += 1;
        let c = (rng.range(0.0, s), rng.range(0.0, s));
        let r = rng.range(14.0, 62.0) * scale;
        let radii: Vec<f64> = (0..12).map(|_| rng.range(0.65, 1.25)).collect();
        let rot = rng.range(0.0, PI);
        for (t, (k, _)) in patch_tiers.iter().enumerate() {
            blob(c, r, &radii, rot, *k, &mut patch[t]);
        }
        for _ in 0..(2 + rng.next_u32() % 4) {
            let q = (
                c.0 + rng.range(-1.3, 1.3) * r,
                c.1 + rng.range(-1.3, 1.3) * r,
            );
            let pr = rng.range(0.7, 2.6) * scale.max(0.25);
            let rot = rng.range(0.0, 2.0 * PI);
            for k in 0..4 {
                let a = rot + PI / 2.0 * f64::from(k) + rng.range(-0.4, 0.4);
                let rr = pr * rng.range(0.6, 1.2);
                let p = (q.0 + rr * a.cos(), q.1 + rr * a.sin());
                let _ = write!(pits, "{}{}", if k == 0 { 'M' } else { 'L' }, pt(p));
            }
            pits.push('Z');
        }
    }
    for _ in 0..90 {
        let mut rng = rng_for(cfg, CLASS_STONE, idx);
        idx += 1;
        let a = (rng.range(0.0, s), rng.range(0.0, s));
        let h = rng.range(0.0, PI);
        let len = rng.range(10.0, 46.0) * scale;
        let pts: Vec<P> = (0..4)
            .map(|k| {
                let t = f64::from(k) / 3.0 * len;
                let w = rng.range(-1.5, 1.5) * scale;
                (
                    a.0 + t * h.cos() - w * h.sin(),
                    a.1 + t * h.sin() + w * h.cos(),
                )
            })
            .collect();
        ribbon(
            &pts,
            2.2 * scale.max(0.4),
            |t| (PI * t).sin().max(0.2),
            s,
            &mut flecks,
        );
    }
    let mut out = String::from("<g id=\"stone\">");
    for (d, (_, a)) in wash.iter().zip(&wash_tiers) {
        let _ = write!(out, "<path fill-opacity=\"{}\" d=\"{d}\"/>", fmt(*a));
    }
    for (d, (_, a)) in patch.iter().zip(&patch_tiers) {
        let _ = write!(out, "<path fill-opacity=\"{}\" d=\"{d}\"/>", fmt(*a));
    }
    let _ = write!(out, "<path fill-opacity=\"0.35\" d=\"{pits}\"/>");
    let _ = write!(out, "<path fill-opacity=\"0.3\" d=\"{flecks}\"/>");
    out.push_str("</g>");
    out
}

// ---- grain ----

fn grain(cfg: &TextureCfg, s: f64) -> String {
    let mut rng = rng_for(cfg, CLASS_GRAIN, 0);
    let scale = s / 1024.0;
    let n = (cfg.grain.clamp(0.0, 1.0) * 14000.0 * scale * scale).round() as usize;
    // Three ink strengths, each its own path so the SVG stays small.
    let tiers = [0.2, 0.4, 0.75];
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
/// a closed subpath. Filled shapes only, so the SVG needs no stroke attributes. Coordinates are
/// clamped into the `0..=lim` canvas.
fn ribbon(pts: &[P], w0: f64, profile: fn(f64) -> f64, lim: f64, d: &mut String) {
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
        let q = (p.0.clamp(0.0, lim), p.1.clamp(0.0, lim));
        let _ = write!(d, "{}{}", if k == 0 { 'M' } else { 'L' }, pt(q));
    }
    d.push('Z');
}

/// Angular random walk from `start`: small jitter with occasional sharp kinks, like a fracture
/// in brittle stone. Stops on leaving the canvas or entering `keep`.
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
        heading += if rng.next_f64() < 0.1 {
            rng.range(-0.8, 0.8)
        } else {
            rng.range(-0.16, 0.16)
        };
        let len = step * rng.range(0.6, 1.4);
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

fn local_heading(pts: &[P], at: usize) -> f64 {
    let (a, b) = (pts[at], pts[(at + 1).min(pts.len() - 1)]);
    (b.1 - a.1).atan2(b.0 - a.0)
}

fn taper(t: f64) -> f64 {
    1.0 - 0.9 * t
}

fn cracks(cfg: &TextureCfg, s: f64, keep: &Rect) -> String {
    let base_w = s * 0.005;
    // The walk checks centre points; pad so the offset polygon edges also stay clear.
    let keep = keep.grow(base_w * 1.5);
    let step = s * 0.012;
    let left_ok = keep.x0 - EDGE > 20.0;
    let right_ok = s - keep.x1 - EDGE > 20.0;
    let mut out = String::from("<g id=\"cracks\">");
    for i in 0..u64::from(cfg.cracks) {
        let mut rng = rng_for(cfg, CLASS_CRACK, i);
        let mut d = String::new();
        let wf = rng.range(0.55, 1.35);
        let alpha = rng.range(0.65, 1.0);
        // Start in the side columns outside the keep-out box, alternating left and right.
        let side_left = i % 2 == 0;
        let mut start = (rng.range(EDGE, s - EDGE), rng.range(EDGE, s - EDGE));
        for _ in 0..50 {
            start = if side_left && left_ok {
                (rng.range(EDGE, keep.x0), rng.range(EDGE, s - EDGE))
            } else if !side_left && right_ok {
                (rng.range(keep.x1, s - EDGE), rng.range(EDGE, s - EDGE))
            } else {
                (rng.range(EDGE, s - EDGE), rng.range(EDGE, s - EDGE))
            };
            if !keep.contains(start) {
                break;
            }
        }
        // Mostly vertical, so the network climbs the margin columns.
        let heading = if rng.next_f64() < 0.65 {
            let up = if rng.next_f64() < 0.5 {
                PI / 2.0
            } else {
                -PI / 2.0
            };
            up + rng.range(-0.7, 0.7)
        } else {
            rng.range(0.0, 2.0 * PI)
        };
        let steps = 60 + (rng.next_u32() % 45) as usize;
        let main = walk(&mut rng, start, heading, steps, step, s, &keep);
        ribbon(&main, base_w * wf, taper, s, &mut d);
        // Branches, some of them hairlines, and the odd twig off a branch.
        let branches = 3 + rng.next_u32() % 4;
        for _ in 0..branches {
            if main.len() < 6 {
                break;
            }
            let at = 1 + (rng.next_u32() as usize) % (main.len() - 3);
            let sign = if rng.next_f64() < 0.5 { -1.0 } else { 1.0 };
            let h = local_heading(&main, at) + sign * rng.range(0.45, 1.3);
            let bsteps = steps / 2 + (rng.next_u32() % 12) as usize;
            let sub = walk(&mut rng, main[at], h, bsteps, step * 0.9, s, &keep);
            let hair = rng.next_f64() < 0.4;
            let bw = if hair { 0.22 } else { rng.range(0.4, 0.7) };
            ribbon(&sub, base_w * wf * bw, taper, s, &mut d);
            if sub.len() > 8 && rng.next_f64() < 0.5 {
                let at2 = 2 + (rng.next_u32() as usize) % (sub.len() - 4);
                let sign = if rng.next_f64() < 0.5 { -1.0 } else { 1.0 };
                let h2 = local_heading(&sub, at2) + sign * rng.range(0.5, 1.2);
                let twig = walk(&mut rng, sub[at2], h2, bsteps / 2, step * 0.8, s, &keep);
                ribbon(&twig, base_w * wf * 0.25, taper, s, &mut d);
            }
        }
        let _ = write!(out, "<path fill-opacity=\"{}\" d=\"{d}\"/>", fmt(alpha));
    }
    out.push_str("</g>");
    out
}

// ---- motifs ----

type Template = &'static [&'static [P]];

/// Original stroke templates in a [-1, 1] box, scaled tall and narrow like a carved character.
/// Each is a set of polylines; none reproduces a real oracle-bone character, they only borrow the
/// angular, branching stroke vocabulary.
const TEMPLATES: [Template; 22] = [
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
    // tree: leaning trunk, drooping crown, one root
    &[
        &[(0.0, -1.0), (0.05, 1.0)],
        &[(-0.9, -0.3), (0.0, -0.5), (0.8, -0.15)],
        &[(0.1, 0.35), (-0.6, 0.9)],
        &[(-0.3, -0.75), (0.5, -0.92)],
    ],
    // walker: head tick, shoulders, striding legs, a carried bar
    &[
        &[(0.15, -1.0), (0.0, -0.6)],
        &[(-0.8, -0.5), (0.0, -0.35), (0.9, -0.6)],
        &[(0.0, -0.35), (0.05, 0.2)],
        &[(0.05, 0.2), (-0.7, 1.0)],
        &[(0.05, 0.2), (0.8, 0.95)],
        &[(-0.9, 0.5), (-0.3, 0.45)],
    ],
    // antler: stem with two forked tines
    &[
        &[(0.0, 1.0), (0.0, -0.2)],
        &[(0.0, 0.3), (-0.8, -0.2), (-0.9, -1.0)],
        &[(0.0, 0.3), (0.8, -0.1), (0.9, -0.9)],
        &[(-0.8, -0.2), (-0.4, -0.8)],
    ],
    // lattice: crossed bars in an uneven grid
    &[
        &[(-1.0, -0.6), (1.0, -0.65)],
        &[(-1.0, 0.2), (1.0, 0.15)],
        &[(-1.0, 0.85), (0.9, 0.9)],
        &[(-0.5, -1.0), (-0.55, 1.0)],
        &[(0.4, -1.0), (0.45, 0.95)],
    ],
    // sheaf: three leaning strokes cut by a crossbar
    &[
        &[(-0.8, -1.0), (-0.5, 1.0)],
        &[(0.0, -1.0), (0.1, 1.0)],
        &[(0.7, -0.9), (0.8, 1.0)],
        &[(-1.0, 0.1), (1.0, -0.1)],
    ],
    // frame: open box with inner bars and a standing foot
    &[
        &[(-0.8, -1.0), (-0.8, 0.2), (0.8, 0.25), (0.8, -0.95)],
        &[(-0.8, -1.0), (0.4, -1.0)],
        &[(-0.8, -0.4), (0.8, -0.35)],
        &[(0.0, 0.25), (0.05, 1.0)],
        &[(-0.5, 0.85), (0.5, 0.8)],
    ],
    // zigzag: switchback stroke on a spine
    &[
        &[
            (-0.8, -1.0),
            (0.8, -0.55),
            (-0.8, -0.05),
            (0.8, 0.45),
            (-0.8, 0.95),
        ],
        &[(0.0, -1.0), (0.0, 1.0)],
    ],
    // feather: stem with paired diagonal barbs
    &[
        &[(0.0, -1.0), (0.0, 1.0)],
        &[(-0.8, -0.3), (0.0, -0.7)],
        &[(0.8, -0.3), (0.0, -0.7)],
        &[(-0.8, 0.2), (0.0, -0.2)],
        &[(0.8, 0.2), (0.0, -0.2)],
        &[(-0.7, 0.7), (0.0, 0.3)],
    ],
    // hook and dots: a hooked stem with three seeds
    &[
        &[(-0.2, -1.0), (0.0, 0.6), (-0.6, 1.0)],
        &[(0.5, -0.8), (0.6, -0.7)],
        &[(0.5, -0.2), (0.6, -0.1)],
        &[(0.4, 0.4), (0.5, 0.5)],
        &[(-0.9, -0.3), (0.9, -0.4)],
    ],
    // asterisk: a wedge of crossing strokes
    &[
        &[(-0.9, -1.0), (0.9, 1.0)],
        &[(0.9, -1.0), (-0.9, 1.0)],
        &[(0.0, -1.0), (0.0, 0.0)],
    ],
    // steps: a stair stroke with a loose tick
    &[
        &[
            (-0.9, -1.0),
            (-0.9, -0.3),
            (0.0, -0.3),
            (0.0, 0.4),
            (0.9, 0.4),
            (0.9, 1.0),
        ],
        &[(-0.2, -0.9), (0.7, -0.8)],
    ],
    // tines: bone with a split foot
    &[
        &[(0.0, -1.0), (0.0, 0.3)],
        &[(0.0, 0.3), (-0.9, 1.0)],
        &[(0.0, 0.3), (0.9, 1.0)],
        &[(0.0, 0.3), (0.1, 1.0)],
        &[(-0.7, -0.5), (0.7, -0.6)],
    ],
    // sun on a stalk: ringed box over a short stem
    &[
        &[
            (-0.7, -0.9),
            (0.7, -0.9),
            (0.7, 0.0),
            (-0.7, 0.0),
            (-0.7, -0.9),
        ],
        &[(-0.7, -0.45), (0.7, -0.45)],
        &[(0.0, 0.0), (0.0, 1.0)],
        &[(-0.5, 0.8), (0.5, 0.75)],
    ],
    // gate: two posts, a lintel and a tick between
    &[
        &[(-0.8, -1.0), (-0.85, 1.0)],
        &[(0.8, -1.0), (0.85, 0.95)],
        &[(-0.9, -0.9), (0.9, -0.95)],
        &[(0.0, -0.9), (0.05, 0.3)],
    ],
];

/// Number of stroke templates the margin figures draw from.
pub fn template_count() -> usize {
    TEMPLATES.len()
}

/// Clip the segment `a`-`b` to the square `[lo, hi]²` (Liang-Barsky); `None` when fully outside.
fn clip(a: P, b: P, lo: f64, hi: f64) -> Option<(P, P)> {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, q) in [
        (-dx, a.0 - lo),
        (dx, hi - a.0),
        (-dy, a.1 - lo),
        (dy, hi - a.1),
    ] {
        if p.abs() < 1e-12 {
            if q < 0.0 {
                return None;
            }
        } else {
            let r = q / p;
            if p < 0.0 {
                t0 = t0.max(r);
            } else {
                t1 = t1.min(r);
            }
        }
    }
    let ends = (
        (a.0 + dx * t0, a.1 + dy * t0),
        (a.0 + dx * t1, a.1 + dy * t1),
    );
    (t0 < t1).then_some(ends)
}

/// Breaks a stroke into irregular dashes with a hand-wobble, as if scratched with a point; a
/// thin parallel echo line follows some strokes, like the doubled edge of a rubbed carving.
fn scratch(rng: &mut Pcg32, a: P, b: P, jitter: f64, width: f64, s: f64, d: &mut String) {
    let Some((a, b)) = clip(a, b, width * 1.5, s - width * 1.5) else {
        return;
    };
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = dx.hypot(dy);
    if len < width {
        return;
    }
    let piece = (s * 0.011).min(len);
    let n = ((len / piece).ceil() as usize).max(1);
    let (nx, ny) = (-dy / len.max(1e-9), dx / len.max(1e-9));
    let echo = rng.next_f64() < 0.55;
    let echo_off = rng.range(-1.0, 1.0) * width * 1.6;
    let mut i = 0;
    while i < n {
        let run = 1 + (rng.next_u32() % 5) as usize;
        let end = (i + run).min(n);
        let mut dash = Vec::new();
        let mut twin = Vec::new();
        for k in i..=end {
            let t = k as f64 / n as f64;
            let w = rng.range(-jitter, jitter);
            let p = (a.0 + dx * t + nx * w, a.1 + dy * t + ny * w);
            dash.push(p);
            twin.push((p.0 + nx * echo_off, p.1 + ny * echo_off));
        }
        // Pointed at both ends, like a scratch that lifts off.
        ribbon(&dash, width, |t| (PI * t).sin().max(0.3), s, d);
        if echo && end > i + 1 && rng.next_f64() < 0.7 {
            ribbon(&twin, width * 0.35, |t| (PI * t).sin().max(0.3), s, d);
        }
        // Gap before the next dash, often one piece, sometimes none (a continuous scratch).
        i = end + usize::from(rng.next_f64() < 0.6);
    }
}

/// Rotated, mirrored and aspect-scaled placement of a template.
#[derive(Clone, Copy)]
struct Pose {
    half_h: f64,
    aspect: f64,
    mirror: f64,
    sin: f64,
    cos: f64,
}

impl Pose {
    fn at(&self, c: P, p: P) -> P {
        let (x, y) = (
            p.0 * self.mirror * self.half_h * self.aspect,
            p.1 * self.half_h,
        );
        (
            c.0 + x * self.cos - y * self.sin,
            c.1 + x * self.sin + y * self.cos,
        )
    }
}

/// Bounding box of the template around the origin.
fn bbox_of(tpl: Template, pose: &Pose) -> Rect {
    let mut bb = Rect {
        x0: f64::MAX,
        y0: f64::MAX,
        x1: f64::MIN,
        y1: f64::MIN,
    };
    for stroke in tpl {
        for &p in *stroke {
            let q = pose.at((0.0, 0.0), p);
            bb.x0 = bb.x0.min(q.0);
            bb.y0 = bb.y0.min(q.1);
            bb.x1 = bb.x1.max(q.0);
            bb.y1 = bb.y1.max(q.1);
        }
    }
    bb
}

fn motifs(cfg: &TextureCfg, s: f64, keep: &Rect) -> String {
    let stroke_w = s * 0.0058;
    let mut placed: Vec<Rect> = Vec::new();
    let mut out = String::from("<g id=\"motifs\">");
    for i in 0..u64::from(cfg.motifs) {
        let mut rng = rng_for(cfg, CLASS_MOTIF, i);
        let tpl = TEMPLATES[(rng.next_u32() as usize) % TEMPLATES.len()];
        let height = s * rng.range(0.18, 0.30);
        let aspect = rng.range(0.4, 0.72);
        let rot = rng.range(-0.14, 0.14);
        let mirror = if rng.next_f64() < 0.5 { -1.0 } else { 1.0 };
        let sw = stroke_w * rng.range(0.85, 1.2);
        let alpha = rng.range(0.75, 1.0);
        let first_left = i % 2 == 0;
        let (sin, cos) = rot.sin_cos();
        let mut found = None;
        // Alternate columns; shrink the figure until it fits a free slot.
        'search: for factor in [1.0, 0.85, 0.7, 0.58, 0.48, 0.38, 0.3, 0.24] {
            for side_left in [first_left, !first_left] {
                let pose = Pose {
                    half_h: height * factor / 2.0,
                    aspect,
                    mirror,
                    sin,
                    cos,
                };
                let slack = pose.half_h * 0.07 + sw * 3.0;
                let ob = bbox_of(tpl, &pose).grow(slack);
                let (bw, bh) = (ob.x1 - ob.x0, ob.y1 - ob.y0);
                // The figure may run up to a fifth of its width past the canvas edge.
                let (lo, hi) = if side_left {
                    (-0.2 * bw, keep.x0 - bw)
                } else {
                    (keep.x1, s - 0.8 * bw)
                };
                if hi <= lo {
                    continue;
                }
                for _ in 0..120 {
                    let (x, y) = (rng.range(lo, hi), rng.range(-0.1 * bh, s - 0.9 * bh));
                    let bb = Rect {
                        x0: x,
                        y0: y,
                        x1: x + bw,
                        y1: y + bh,
                    };
                    if !bb.overlaps(keep) && !placed.iter().any(|r| r.grow(-0.1 * bw).overlaps(&bb))
                    {
                        found = Some((pose, (x - ob.x0, y - ob.y0), bb));
                        break 'search;
                    }
                }
            }
        }
        let Some((pose, c, bb)) = found else { continue };
        placed.push(bb);
        let mut d = String::new();
        let jitter = pose.half_h * 0.012;
        for stroke in tpl {
            for w in stroke.windows(2) {
                scratch(
                    &mut rng,
                    pose.at(c, w[0]),
                    pose.at(c, w[1]),
                    jitter,
                    sw,
                    s,
                    &mut d,
                );
            }
        }
        let _ = write!(out, "<path fill-opacity=\"{}\" d=\"{d}\"/>", fmt(alpha));
    }
    out.push_str("</g>");
    out
}
