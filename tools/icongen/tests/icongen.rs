use icongen::config::{BackgroundKind, IconCfg, ThemeCfg};
use icongen::fidelity::{components, holes, rasterize};
use icongen::glyph::{
    Cap, Glyph, MIN_HOLE_RADIUS, MITER_LIMIT, Tag, Vertex, inscribed_radius, offset_contour,
    polygon_area, segments, stroke_outline,
};
use icongen::rng::Pcg32;
use icongen::{pipeline, png_out, render, svg};
use std::path::PathBuf;

fn brand() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../brand")
}

fn read(rel: &str) -> String {
    std::fs::read_to_string(brand().join(rel)).unwrap()
}

#[test]
fn pcg32_known_values() {
    let mut r = Pcg32::new(42, 54);
    let got: Vec<u32> = (0..6).map(|_| r.next_u32()).collect();
    assert_eq!(
        got,
        [
            0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e
        ]
    );
}

#[test]
fn pcg32_f64_in_unit_range_and_repeatable() {
    let mut a = Pcg32::from_seed(7);
    let mut b = Pcg32::from_seed(7);
    for _ in 0..100 {
        let x = a.next_f64();
        assert!((0.0..1.0).contains(&x));
        assert_eq!(x, b.next_f64());
    }
}

#[test]
fn parses_theme_config() {
    let t = ThemeCfg::from_toml(&read("themes/matte.toml")).unwrap();
    assert_eq!(t.name, "matte");
    assert_eq!(t.background.kind, BackgroundKind::Solid);
    assert_eq!(t.background.color, "#0b0b0c");
    assert!(t.texture.enabled);
    assert_eq!(t.texture.seed, 20241004);
    assert_eq!(t.texture.cracks, 10);
    assert_eq!(t.texture.motifs, 12);
    assert_eq!(t.texture.color, "#f7f5f2");
    assert!((t.texture.opacity - 0.16).abs() < 1e-12);
    assert_eq!(t.mark.fill, "#f7f5f2");
    assert!((t.mark.scale - 0.75).abs() < 1e-12);
    assert!((t.mark.weight - 2.1).abs() < 1e-12);
    assert_eq!(t.mark.hole_weight, Some(1.0));
    assert_eq!(t.mark.small_size, None);
    assert_eq!(t.mark.offset, [0.0, 0.0]);
    assert!(!t.gloss.enabled);
    assert_eq!(t.container.kind, "none");
}

#[test]
fn rejects_bad_theme_config() {
    let good = read("themes/matte.toml");
    let bad = good.replace("#0b0b0c", "red");
    assert_ne!(bad, good);
    assert!(ThemeCfg::from_toml(&bad).is_err());
    let bad = read("themes/matte.toml").replace("\"solid\"", "\"radial\"");
    assert!(ThemeCfg::from_toml(&bad).is_err());
    for w in ["-1.0", "6.5"] {
        let bad = good.replace("\nweight = 2.1", &format!("\nweight = {w}"));
        assert_ne!(bad, good);
        assert!(ThemeCfg::from_toml(&bad).is_err(), "weight {w}");
    }
}

#[test]
fn rejects_non_finite_and_absurd_numbers() {
    let good = read("themes/matte.toml");
    let cases = [
        ("\nangle = 90.0", "\nangle = nan"),
        ("\nangle = 90.0", "\nangle = inf"),
        ("\ngrain = 0.6", "\ngrain = nan"),
        ("\ngrain = 0.6", "\ngrain = 1.5"),
        ("\ngrain = 0.6", "\ngrain = -0.1"),
        ("\nopacity = 0.16", "\nopacity = nan"),
        ("\nkeepout = 0.04", "\nkeepout = nan"),
        ("\nkeepout = 0.04", "\nkeepout = inf"),
        ("\nkeepout = 0.04", "\nkeepout = 0.9"),
        ("\nkeepout = 0.04", "\nkeepout = -0.1"),
        ("\ncracks = 10", "\ncracks = 4000000000"),
        ("\ncracks = 10", "\ncracks = 201"),
        ("\nmotifs = 12", "\nmotifs = 65"),
        ("\nmotifs = 12", "\nmotifs = 4000000000"),
        ("\noffset = [0.0, 0.0]", "\noffset = [nan, 0.0]"),
        ("\noffset = [0.0, 0.0]", "\noffset = [0.0, inf]"),
        ("\noffset = [0.0, 0.0]", "\noffset = [0.9, 0.0]"),
        ("\nscale = 0.75", "\nscale = nan"),
        ("\nweight = 2.1", "\nweight = nan"),
    ];
    for (from, to) in cases {
        let bad = good.replace(from, to);
        assert_ne!(bad, good, "{from}");
        assert!(ThemeCfg::from_toml(&bad).is_err(), "{to}");
    }
    let ok = good
        .replace("\ncracks = 10", "\ncracks = 200")
        .replace("\nmotifs = 12", "\nmotifs = 64")
        .replace("\nseed = 20241004", "\nseed = 9223372036854775807");
    assert!(ThemeCfg::from_toml(&ok).is_ok());
}

#[test]
fn small_size_weight_bonus_applies_at_and_below_its_size() {
    let good = read("themes/matte.toml");
    let with = good.replace(
        "[gloss]",
        "small_size = { max_px = 64, weight = 1.0 }\n\n[gloss]",
    );
    assert_ne!(with, good);
    let t = ThemeCfg::from_toml(&with).unwrap();
    assert!((t.mark.weight_at(1024) - 2.1).abs() < 1e-12);
    assert!((t.mark.weight_at(65) - 2.1).abs() < 1e-12);
    assert!((t.mark.weight_at(64) - 3.1).abs() < 1e-12);
    assert!((t.mark.weight_at(16) - 3.1).abs() < 1e-12);
    assert!(
        (t.mark.hole_weight_at(64) - 2.0).abs() < 1e-12,
        "the bonus shrinks holes too"
    );
    let plain = ThemeCfg::from_toml(&good).unwrap();
    assert!((plain.mark.weight_at(16) - 2.1).abs() < 1e-12);
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    assert_eq!(
        svg::layers(&t, &g, 1024).mark,
        svg::layers(&plain, &g, 1024).mark
    );
    assert_ne!(
        svg::layers(&t, &g, 64).mark,
        svg::layers(&plain, &g, 64).mark
    );
    let too_much = good.replace(
        "[gloss]",
        "small_size = { max_px = 64, weight = 5.0 }\n\n[gloss]",
    );
    assert!(ThemeCfg::from_toml(&too_much).is_err());
}

#[test]
fn hole_weight_defaults_to_weight_and_stays_within_it() {
    let good = read("themes/matte.toml");
    let t = ThemeCfg::from_toml(&good).unwrap();
    assert!((t.mark.hole_weight_at(1024) - 1.0).abs() < 1e-12);
    let none = good.replace("\nhole_weight = 1.0", "\n");
    assert_ne!(none, good);
    let t = ThemeCfg::from_toml(&none).unwrap();
    assert_eq!(t.mark.hole_weight, None);
    assert!((t.mark.hole_weight_at(1024) - t.mark.weight).abs() < 1e-12);
    for bad in ["-0.5", "2.5"] {
        let bad = good.replace("\nhole_weight = 1.0", &format!("\nhole_weight = {bad}"));
        assert!(ThemeCfg::from_toml(&bad).is_err(), "{bad}");
    }
}

#[test]
fn parses_icon_config() {
    let c = IconCfg::from_toml(&read("icon.toml")).unwrap();
    assert_eq!(c.size, 1024);
    assert_eq!(c.appearances.light, "matte");
    assert_eq!(c.appearances.dark, "matte");
    assert_eq!(c.appearances.tinted, "tinted");
}

#[test]
fn parses_glyph_topology() {
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    let pieces = g.pieces(0.0);
    assert_eq!(pieces.len(), 5);
    assert_eq!(pieces[0].id, "S01");
    assert_eq!(pieces[0].contours.len(), 3); // outline + 2 holes
    assert!(pieces[0].even_odd);
    assert!(pieces[1..].iter().all(|p| p.contours.len() == 1));
}

#[test]
fn rejects_bad_vertex_tag() {
    let good = read("mark/mark.toml");
    let bad = good.replacen(", \"s\"]", ", \"x\"]", 1);
    assert_ne!(bad, good);
    assert!(Glyph::from_toml(&bad).is_err());
}

fn v(x: f64, y: f64, t: Tag) -> Vertex {
    Vertex { x, y, tag: t }
}

const STROKES: &str = r##"
[s01]
outline = [[10.0, 10.0, "c"], [30.0, 10.0, "c"], [30.0, 30.0, "c"], [10.0, 30.0, "c"]]
holes = []

[[stroke]]
id = "S02"
outline = [[40.0, 10.0, "c"], [44.0, 10.0, "c"], [45.0, 20.0, "s"], [44.0, 30.0, "c"], [40.0, 30.0, "c"], [39.0, 20.0, "s"]]

[[stroke]]
id = "S03"
points = [[0.0, 0.0, 4.0], [10.0, 0.0, 4.0]]
"##;

#[test]
fn strokes_take_an_outline_or_a_centerline() {
    let g = Glyph::from_toml(STROKES).unwrap();
    assert_eq!(g.strokes.len(), 2);
    let o = &g.strokes[0].outline;
    assert_eq!(o.len(), 6);
    assert_eq!((o[2].x, o[2].y, o[2].tag), (45.0, 20.0, Tag::Smooth));
    assert_eq!(o[3].tag, Tag::Sharp);
    let flat = Cap::default();
    assert_eq!(
        g.strokes[1].outline,
        stroke_outline(&[(0.0, 0.0, 4.0), (10.0, 0.0, 4.0)], flat, flat, 0.0),
        "a centerline becomes its outline"
    );
    let pieces = g.pieces(0.0);
    assert_eq!(pieces[1].id, "S02");
    assert_eq!(
        pieces[1].contours,
        vec![o.clone()],
        "weight 0 is the outline"
    );
    let both = STROKES.replace(
        "id = \"S03\"\n",
        "id = \"S03\"\noutline = [[0.0, 0.0, \"c\"], [1.0, 0.0, \"c\"], [1.0, 1.0, \"c\"]]\n",
    );
    assert!(Glyph::from_toml(&both).is_err(), "outline and points");
    let neither = STROKES.replace("points = [[0.0, 0.0, 4.0], [10.0, 0.0, 4.0]]\n", "");
    assert!(Glyph::from_toml(&neither).is_err(), "no shape");
    let caps = STROKES.replace("id = \"S02\"\n", "id = \"S02\"\ncap_end = { cut = 10.0 }\n");
    assert!(Glyph::from_toml(&caps).is_err(), "caps on an outline");
    let tag = STROKES.replace("[45.0, 20.0, \"s\"]", "[45.0, 20.0, \"q\"]");
    assert!(Glyph::from_toml(&tag).is_err(), "bad tag");
}

#[test]
fn shipped_strokes_are_dense_outlines() {
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    assert!(
        g.outline.len() >= 100,
        "S01 keeps its wobble: {}",
        g.outline.len()
    );
    for s in &g.strokes {
        assert!(
            s.outline.len() >= 20,
            "{} keeps its shape: {}",
            s.id,
            s.outline.len()
        );
        assert!(
            s.outline.iter().any(|v| v.tag == Tag::Sharp),
            "{} has carved corners",
            s.id
        );
    }
}

#[test]
fn curve_handles_stay_within_a_third_of_their_edge() {
    use Tag::Smooth as S;
    // Unevenly spaced smooth vertices: long edges next to very short ones.
    let poly = [
        v(0.0, 0.0, S),
        v(20.0, 0.0, S),
        v(20.3, 0.2, S),
        v(20.5, 0.6, S),
        v(20.0, 20.0, S),
        v(0.0, 20.0, S),
    ];
    for s in segments(&poly) {
        let len = (s.b.0 - s.a.0).hypot(s.b.1 - s.a.1);
        let (c1, c2) = (s.c1.unwrap(), s.c2.unwrap());
        assert!(
            (c1.0 - s.a.0).hypot(c1.1 - s.a.1) <= len / 3.0 + 1e-9,
            "{s:?}"
        );
        assert!(
            (c2.0 - s.b.0).hypot(c2.1 - s.b.1) <= len / 3.0 + 1e-9,
            "{s:?}"
        );
    }
}

#[test]
fn hole_weight_shrinks_the_holes_only() {
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    let full = g.pieces(2.0);
    let light = g.pieces_with(2.0, 0.5);
    assert_eq!(
        full[0].contours[0], light[0].contours[0],
        "outline unchanged"
    );
    assert_eq!(full[1..], light[1..], "strokes unchanged");
    for (a, b) in full[0].contours[1..].iter().zip(&light[0].contours[1..]) {
        assert!(polygon_area(b) >= polygon_area(a));
    }
    assert!(polygon_area(&light[0].contours[2]) > polygon_area(&full[0].contours[2]) + 10.0);
    assert_eq!(g.pieces_with(2.0, 2.0), g.pieces(2.0));
}

#[test]
fn smoothing_never_curves_across_sharp_vertices() {
    use Tag::{Sharp as C, Smooth as S};
    let poly = [
        v(0.0, 0.0, C),
        v(10.0, 0.0, S),
        v(20.0, 5.0, S),
        v(30.0, 0.0, C),
        v(30.0, 20.0, C),
        v(10.0, 25.0, S),
    ];
    let segs = segments(&poly);
    assert_eq!(segs.len(), poly.len());
    for (i, s) in segs.iter().enumerate() {
        let a = &poly[i];
        let b = &poly[(i + 1) % poly.len()];
        assert_eq!((s.a, s.b), ((a.x, a.y), (b.x, b.y)));
        match (a.tag, b.tag) {
            (C, C) => assert!(s.c1.is_none() && s.c2.is_none(), "line between corners"),
            _ => {
                assert!(s.c1.is_some() && s.c2.is_some(), "curve segment");
                if a.tag == C {
                    assert_eq!(s.c1, Some(s.a), "no handle at a sharp start");
                }
                if b.tag == C {
                    assert_eq!(s.c2, Some(s.b), "no handle at a sharp end");
                }
            }
        }
    }
    // A smooth vertex between two smooth neighbours has real handles.
    assert_ne!(segs[1].c1, Some(segs[1].a));
    assert_ne!(segs[1].c2, Some(segs[1].b));
}

#[test]
fn chisel_cap_geometry_flat() {
    let flat = Cap {
        cut: 0.0,
        asym: 0.0,
    };
    let o = stroke_outline(&[(0.0, 0.0, 4.0), (10.0, 0.0, 4.0)], flat, flat, 0.0);
    let pts: Vec<(f64, f64)> = o.iter().map(|p| (p.x, p.y)).collect();
    assert_eq!(pts, [(0.0, 2.0), (10.0, 2.0), (10.0, -2.0), (0.0, -2.0)]);
    assert!(o.iter().all(|p| p.tag == Tag::Sharp));
}

#[test]
fn chisel_cap_geometry_cut_and_asym() {
    let cut = Cap {
        cut: 45.0,
        asym: 0.0,
    };
    let flat = Cap {
        cut: 0.0,
        asym: 0.0,
    };
    let o = stroke_outline(&[(0.0, 0.0, 4.0), (10.0, 0.0, 4.0)], flat, cut, 0.0);
    let near = |p: &Vertex, x: f64, y: f64| (p.x - x).abs() < 1e-9 && (p.y - y).abs() < 1e-9;
    assert!(near(&o[1], 12.0, 2.0));
    assert!(near(&o[2], 8.0, -2.0));
    let asym = Cap {
        cut: 0.0,
        asym: 0.5,
    };
    let o = stroke_outline(&[(0.0, 0.0, 4.0), (10.0, 0.0, 4.0)], flat, asym, 0.0);
    assert!(near(&o[1], 10.0, 3.0));
    assert!(near(&o[2], 10.0, -1.0));
}

#[test]
fn weight_widens_strokes() {
    let flat = Cap {
        cut: 0.0,
        asym: 0.0,
    };
    let o = stroke_outline(&[(0.0, 0.0, 4.0), (10.0, 0.0, 4.0)], flat, flat, 2.0);
    assert!((o[0].y - 3.0).abs() < 1e-9);
    assert!((o[2].y + 3.0).abs() < 1e-9);
}

fn pts(c: &[Vertex]) -> Vec<(f64, f64)> {
    c.iter().map(|v| (v.x, v.y)).collect()
}

fn close(a: &[(f64, f64)], b: &[(f64, f64)]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b)
            .all(|(p, q)| (p.0 - q.0).abs() < 1e-9 && (p.1 - q.1).abs() < 1e-9)
}

fn square(clockwise: bool) -> Vec<Vertex> {
    use Tag::Sharp as C;
    let mut s = vec![
        v(0.0, 0.0, C),
        v(10.0, 0.0, C),
        v(10.0, 10.0, C),
        v(0.0, 10.0, C),
    ];
    if !clockwise {
        s.reverse();
    }
    s
}

#[test]
fn offset_moves_every_edge_by_the_weight_either_winding() {
    let grown = offset_contour(&square(true), 1.0);
    assert!(close(
        &pts(&grown),
        &[(-1.0, -1.0), (11.0, -1.0), (11.0, 11.0), (-1.0, 11.0)]
    ));
    assert!(
        grown.iter().all(|p| p.tag == Tag::Sharp),
        "corners stay sharp"
    );
    let grown = offset_contour(&square(false), 1.0);
    assert!(close(
        &pts(&grown),
        &[(-1.0, 11.0), (11.0, 11.0), (11.0, -1.0), (-1.0, -1.0)]
    ));
    let shrunk = offset_contour(&square(true), -2.0);
    assert!(close(
        &pts(&shrunk),
        &[(2.0, 2.0), (8.0, 2.0), (8.0, 8.0), (2.0, 8.0)]
    ));
    assert_eq!(offset_contour(&square(true), 0.0), square(true));
}

#[test]
fn offset_keeps_smooth_vertices_smooth() {
    use Tag::{Sharp as C, Smooth as S};
    let poly = [
        v(0.0, 0.0, C),
        v(10.0, -1.0, S),
        v(20.0, 0.0, C),
        v(20.0, 10.0, C),
        v(0.0, 10.0, C),
    ];
    let o = offset_contour(&poly, 1.0);
    assert_eq!(o.len(), poly.len());
    let tags: Vec<Tag> = o.iter().map(|p| p.tag).collect();
    assert_eq!(tags, [C, S, C, C, C]);
    assert!(o[1].y < -1.9 && o[1].y > -2.1, "{:?}", o[1]);
}

#[test]
fn offset_clips_acute_sharp_corners_at_the_miter_limit() {
    use Tag::Sharp as C;
    // A 20-unit chisel tip on a 4-unit-wide wedge: the plain miter would reach far past the tip.
    let wedge = [v(0.0, -2.0, C), v(20.0, 0.0, C), v(0.0, 2.0, C)];
    let o = offset_contour(&wedge, 1.0);
    assert_eq!(o.len(), 4, "the tip splits into two sharp vertices: {o:?}");
    assert!(o.iter().all(|p| p.tag == Tag::Sharp));
    // The wedge is symmetric about y = 0, so the miter runs along +x.
    let tip = o.iter().map(|p| p.x - 20.0).fold(f64::MIN, f64::max);
    assert!(
        (tip - MITER_LIMIT * 1.0).abs() < 1e-9,
        "clipped at the limit: {tip}"
    );
    assert!(
        o.iter().any(|p| p.x > 21.5),
        "but still past the tip: {o:?}"
    );
}

#[test]
fn shrinking_a_pinched_contour_cuts_its_thin_tail_to_a_point() {
    use Tag::{Sharp as C, Smooth as S};
    // A lens with a long thin tail: shrinking by 2 must not fold the tail into a loop.
    let lens = [
        v(0.0, 0.0, C),
        v(4.0, 4.0, S),
        v(4.0, 12.0, S),
        v(1.0, 20.0, S),
        v(0.5, 30.0, C),
        v(0.0, 20.0, S),
        v(-3.0, 12.0, S),
        v(-3.0, 4.0, S),
    ];
    let o = offset_contour(&lens, -2.0);
    assert!(is_simple(&o), "{o:?}");
    assert!(polygon_area(&o) > 0.0 && polygon_area(&o) < polygon_area(&lens));
    assert!(o.iter().all(|p| p.y < 20.0), "the tail is gone: {o:?}");
}

/// No two non-adjacent edges cross.
fn is_simple(c: &[Vertex]) -> bool {
    let n = c.len();
    let p = |i: usize| (c[i % n].x, c[i % n].y);
    let cross = |a: (f64, f64), b: (f64, f64), q: (f64, f64)| {
        (b.0 - a.0) * (q.1 - a.1) - (b.1 - a.1) * (q.0 - a.0)
    };
    for i in 0..n {
        for j in i + 2..n {
            if i == 0 && j == n - 1 {
                continue;
            }
            let (a, b, q, r) = (p(i), p(i + 1), p(j), p(j + 1));
            let (d1, d2) = (cross(a, b, q), cross(a, b, r));
            let (d3, d4) = (cross(q, r, a), cross(q, r, b));
            if d1 * d2 < 0.0 && d3 * d4 < 0.0 {
                return false;
            }
        }
    }
    true
}

fn bbox(c: &[Vertex]) -> (f64, f64, f64, f64) {
    c.iter()
        .fold((f64::MAX, f64::MAX, f64::MIN, f64::MIN), |b, p| {
            (b.0.min(p.x), b.1.min(p.y), b.2.max(p.x), b.3.max(p.y))
        })
}

#[test]
fn weight_offsets_every_piece_and_keeps_the_topology() {
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    let master = g.pieces(0.0);
    assert_eq!(
        pts(&master[0].contours[0]),
        pts(&g.outline),
        "weight 0 is the master"
    );
    for w in [1.0, 2.25, 4.0, 6.0] {
        let p = g.pieces(w);
        assert_eq!(p.len(), 5);
        assert_eq!(p[0].contours.len(), 3, "S01 keeps both holes at weight {w}");
        for (a, b) in master.iter().zip(&p) {
            let (o, n) = (bbox(&a.contours[0]), bbox(&b.contours[0]));
            for grow in [o.0 - n.0, o.1 - n.1, n.2 - o.2, n.3 - o.3] {
                assert!(
                    grow >= 0.9 * w && grow <= MITER_LIMIT * w + 1e-9,
                    "{} at weight {w}: side grew {grow}",
                    a.id
                );
            }
            for c in &b.contours {
                assert!(is_simple(c), "{} at weight {w} self-intersects", a.id);
            }
        }
        for (h0, h) in g.holes.iter().zip(&p[0].contours[1..]) {
            assert!(polygon_area(h) < polygon_area(h0), "holes shrink");
            let r = inscribed_radius(h);
            let want = inscribed_radius(h0).min(MIN_HOLE_RADIUS);
            assert!(r >= want - 0.15, "hole kept open: r {r} < {want}");
        }
        let m = rasterize(&g, w, 201, 251, 2.0);
        assert_eq!(components(&m), 5, "no side stroke merges at weight {w}");
        assert_eq!(holes(&m), 2, "both holes open at weight {w}");
    }
}

fn theme_and_glyph() -> (ThemeCfg, Glyph) {
    (
        ThemeCfg::from_toml(&read("themes/matte.toml")).unwrap(),
        Glyph::from_toml(&read("mark/mark.toml")).unwrap(),
    )
}

#[test]
fn svg_is_deterministic_and_layered() {
    let (t, g) = theme_and_glyph();
    let a = svg::layers(&t, &g, 1024);
    let b = svg::layers(&t, &g, 1024);
    assert_eq!(a.composite, b.composite);
    assert_eq!(a.mark, b.mark);
    for s in [
        &a.base,
        &a.texture,
        &a.mark,
        &a.gloss,
        &a.container,
        &a.composite,
    ] {
        assert!(s.starts_with("<svg"), "{s}");
        assert!(!s.contains("e-") && !s.contains("NaN"));
    }
    assert!(a.mark.contains("evenodd"));
}

#[test]
fn number_format_is_fixed_precision() {
    assert_eq!(svg::fmt(1.0), "1");
    assert_eq!(svg::fmt(1.23456), "1.235");
    assert_eq!(svg::fmt(-0.0001), "0");
    assert_eq!(svg::fmt(0.5), "0.5");
}

#[test]
fn png_writer_properties() {
    let (t, g) = theme_and_glyph();
    let l = svg::layers(&t, &g, 1024);
    let pix = render::render(&l.composite, 1024).unwrap();
    let bytes = png_out::encode_rgb(&pix, [0x7a, 0x1f, 0x1a]);
    let dec = png::Decoder::new(std::io::Cursor::new(&bytes));
    let mut rd = dec.read_info().unwrap();
    let info = rd.info();
    assert_eq!(info.color_type, png::ColorType::Rgb);
    assert_eq!(info.bit_depth, png::BitDepth::Eight);
    assert_eq!((info.width, info.height), (1024, 1024));
    assert!(info.srgb.is_some());
    assert!(info.trns.is_none());
    assert!(info.icc_profile.is_none());
    let mut buf = vec![0; rd.output_buffer_size()];
    let fr = rd.next_frame(&mut buf).unwrap();
    assert_eq!(fr.buffer_size(), 1024 * 1024 * 3);
}

#[test]
fn png_flattens_transparency_over_background() {
    let (t, g) = theme_and_glyph();
    let l = svg::layers(&t, &g, 256);
    let pix = render::render(&l.mark, 256).unwrap(); // transparent corners
    let bytes = png_out::encode_rgb(&pix, [10, 20, 30]);
    let mut rd = png::Decoder::new(std::io::Cursor::new(&bytes))
        .read_info()
        .unwrap();
    let mut buf = vec![0; rd.output_buffer_size()];
    rd.next_frame(&mut buf).unwrap();
    assert_eq!(&buf[0..3], &[10, 20, 30]);
}

#[test]
fn pipeline_is_deterministic() {
    let a = pipeline::build(&brand()).unwrap();
    let b = pipeline::build(&brand()).unwrap();
    assert_eq!(a, b);
    let names: Vec<&str> = a.iter().map(|(n, _)| n.as_str()).collect();
    for want in [
        "out/light/composite.svg",
        "out/light/mark.svg",
        "out/light/icon.png",
        "out/manifest.json",
    ] {
        assert!(names.contains(&want), "missing {want}");
    }
}

#[test]
fn png_tolerance_compare() {
    let (t, g) = theme_and_glyph();
    let pix = render::render(&svg::layers(&t, &g, 64).composite, 64).unwrap();
    let a = png_out::encode_rgb(&pix, [0, 0, 0]);
    assert!(pipeline::png_close(&a, &a, 2).unwrap());
    let mut p2 = pix.clone();
    p2.data_mut()[0] = p2.data()[0].saturating_add(5);
    let b = png_out::encode_rgb(&p2, [0, 0, 0]);
    assert!(!pipeline::png_close(&a, &b, 2).unwrap());
}

fn lin(c: u8) -> f64 {
    let v = f64::from(c) / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

fn lum(p: &[u8]) -> f64 {
    0.2126 * lin(p[0]) + 0.7152 * lin(p[1]) + 0.0722 * lin(p[2])
}

#[test]
fn shipped_themes_keep_7_to_1_mark_contrast() {
    let g = Glyph::from_toml(&read("mark/mark.toml")).unwrap();
    let mut names: Vec<String> = std::fs::read_dir(brand().join("themes"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".toml"))
        .collect();
    names.sort();
    for want in ["matte", "mono-dark", "mono-light", "tinted"] {
        assert!(names.contains(&format!("{want}.toml")), "missing {want}");
    }
    for n in &names {
        let t = ThemeCfg::from_toml(&read(&format!("themes/{n}"))).unwrap();
        let fill = icongen::config::parse_hex(&t.mark.fill).unwrap();
        let mark = lum(&fill);
        // Everything under the mark: base colour plus texture, without the mark itself.
        let l = svg::layers(&t, &g, 512);
        let under = format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"512\" height=\"512\" viewBox=\"0 0 512 512\">{}{}</svg>",
            l.base
                .split_once('>')
                .unwrap()
                .1
                .trim_end()
                .trim_end_matches("</svg>"),
            l.texture
                .split_once('>')
                .unwrap()
                .1
                .trim_end()
                .trim_end_matches("</svg>"),
        );
        let pix = render::render(&under, 512).unwrap();
        let worst = pix
            .data()
            .chunks(4)
            .map(|p| {
                let b = lum(p);
                (mark.max(b) + 0.05) / (mark.min(b) + 0.05)
            })
            .fold(f64::MAX, f64::min);
        assert!(worst >= 7.0, "{n}: contrast {worst:.2}");
    }
}

fn ids(svg: &str) -> Vec<String> {
    svg.split("id=\"")
        .skip(1)
        .map(|s| s.split('"').next().unwrap().to_string())
        .collect()
}

#[test]
fn enabled_gloss_draws_and_has_unique_ids() {
    let (plain, g) = theme_and_glyph();
    let mut glossy = plain.clone();
    glossy.gloss.enabled = true;
    let (a, b) = (svg::layers(&plain, &g, 128), svg::layers(&glossy, &g, 128));
    for svg_text in [&b.composite, &b.gloss] {
        let mut all = ids(svg_text);
        let n = all.len();
        all.sort();
        all.dedup();
        assert_eq!(all.len(), n, "duplicate ids in {svg_text}");
    }
    let (pa, pb) = (
        render::render(&a.composite, 128).unwrap(),
        render::render(&b.composite, 128).unwrap(),
    );
    assert_ne!(pa.data(), pb.data(), "the gloss must change some pixel");
    let gloss_only = render::render(&b.gloss, 128).unwrap();
    assert!(gloss_only.pixels().iter().any(|p| p.alpha() > 0));
}

#[test]
fn container_border_scales_with_the_canvas() {
    let (mut t, g) = theme_and_glyph();
    t.container.kind = "squircle".into();
    for px in [16u32, 32, 48, 256, 1024] {
        let doc = svg::layers(&t, &g, px).container;
        let c = doc.split("<rect").nth(1).unwrap().to_string();
        let attr = |name: &str| -> f64 {
            let key = format!(" {name}=\"");
            let rest = c.split(&key).nth(1).unwrap_or_else(|| panic!("{name}"));
            rest.split('"').next().unwrap().parse().unwrap()
        };
        let s = f64::from(px);
        let sw = attr("stroke-width");
        assert!((sw - s * 2.0 / 1024.0).abs() < 1e-3, "{px}: stroke {sw}");
        assert!((attr("x") - sw / 2.0).abs() < 1e-3, "{px}: x inset");
        assert!((attr("y") - sw / 2.0).abs() < 1e-3, "{px}: y inset");
        assert!((attr("width") - (s - sw)).abs() < 1e-3, "{px}: width");
    }
}
