use icongen::config::ThemeCfg;
use icongen::fidelity::{
    Field, GATE_AREA, GATE_CORNERS, GATE_HAUSDORFF, GATE_IOU, GATE_PIECE_IOU, ISO_LEVEL,
    MEASURE_SCALE, MIN_HOLE_AREA, MIN_HOLE_SHARE, Mask, THEME_SIZES, check_theme, components,
    corner_points, corners_kept, evaluate, failures, hausdorff, holes, iou, load_field_png,
    load_mask_png, min_stroke_width, rasterize, reference_mask, run, simplify_anchored,
    simplify_closed, small_size_report, smooth_along, theme_failures, trace_contours, trace_toml,
    upsample,
};
use icongen::glyph::Glyph;
use std::path::PathBuf;

fn blank(w: usize, h: usize) -> Mask {
    Mask {
        width: w,
        height: h,
        data: vec![false; w * h],
    }
}

fn fill(m: &mut Mask, x0: usize, y0: usize, x1: usize, y1: usize) {
    for y in y0..y1 {
        for x in x0..x1 {
            m.data[y * m.width + x] = true;
        }
    }
}

fn clear(m: &mut Mask, x0: usize, y0: usize, x1: usize, y1: usize) {
    for y in y0..y1 {
        for x in x0..x1 {
            m.data[y * m.width + x] = false;
        }
    }
}

fn png(color: png::ColorType, w: u32, h: u32, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(color);
        enc.set_depth(png::BitDepth::Eight);
        let mut wr = enc.write_header().unwrap();
        wr.write_image_data(data).unwrap();
    }
    out
}

#[test]
fn iou_of_shifted_squares() {
    let mut a = blank(30, 30);
    let mut b = blank(30, 30);
    fill(&mut a, 0, 0, 10, 10);
    fill(&mut b, 5, 0, 15, 10);
    assert!((iou(&a, &b) - 1.0 / 3.0).abs() < 1e-12);
    assert_eq!(iou(&a, &a), 1.0);
    assert_eq!(iou(&blank(4, 4), &blank(4, 4)), 1.0);
}

#[test]
fn png_loader_handles_color_types_and_threshold() {
    // Gray: 128 is ink, 127 is not.
    let m = load_mask_png(&png(png::ColorType::Grayscale, 2, 1, &[128, 127])).unwrap();
    assert_eq!(m.data, vec![true, false]);
    // RGB: white ink, black background.
    let m = load_mask_png(&png(png::ColorType::Rgb, 2, 1, &[255, 255, 255, 0, 0, 0])).unwrap();
    assert_eq!((m.width, m.height), (2, 1));
    assert_eq!(m.data, vec![true, false]);
    // RGBA: a transparent white pixel is composited over black.
    let m = load_mask_png(&png(
        png::ColorType::Rgba,
        2,
        1,
        &[255, 255, 255, 255, 255, 255, 255, 0],
    ))
    .unwrap();
    assert_eq!(m.data, vec![true, false]);
    // Gray + alpha.
    let m = load_mask_png(&png(
        png::ColorType::GrayscaleAlpha,
        2,
        1,
        &[200, 255, 200, 0],
    ))
    .unwrap();
    assert_eq!(m.data, vec![true, false]);
    assert!(load_mask_png(b"not a png").is_err());
    let f = load_field_png(&png(png::ColorType::Grayscale, 1, 1, &[200])).unwrap();
    assert_eq!(f.data, vec![200.0]);
}

#[test]
fn components_and_holes() {
    let mut ring = blank(30, 30);
    fill(&mut ring, 5, 5, 25, 25);
    clear(&mut ring, 10, 10, 20, 20);
    assert_eq!(components(&ring), 1);
    assert_eq!(holes(&ring), 1);

    let mut two = blank(30, 30);
    fill(&mut two, 2, 2, 8, 8);
    fill(&mut two, 15, 15, 20, 20);
    assert_eq!(components(&two), 2);
    assert_eq!(holes(&two), 0);

    // Diagonal contact joins ink (8-connectivity).
    let mut diag = blank(10, 10);
    fill(&mut diag, 1, 1, 3, 3);
    fill(&mut diag, 3, 3, 5, 5);
    assert_eq!(components(&diag), 1);

    // A notch open to the border is not a hole; a diagonal-only gap does not close a hole.
    let mut c = blank(20, 20);
    fill(&mut c, 2, 2, 18, 18);
    clear(&mut c, 8, 2, 12, 10);
    assert_eq!(holes(&c), 0);
    let mut gap = blank(10, 10);
    fill(&mut gap, 2, 2, 8, 8);
    clear(&mut gap, 4, 4, 6, 6);
    assert_eq!(holes(&gap), 1);
}

#[test]
fn hausdorff_of_shifted_rects() {
    let mut a = blank(50, 50);
    let mut b = blank(50, 50);
    fill(&mut a, 10, 10, 30, 30);
    fill(&mut b, 13, 10, 33, 30);
    assert!((hausdorff(&a, &b) - 3.0).abs() < 1e-9);
    assert_eq!(hausdorff(&a, &a), 0.0);
    assert!(hausdorff(&a, &blank(50, 50)).is_infinite());
    assert_eq!(hausdorff(&blank(5, 5), &blank(5, 5)), 0.0);
}

const GLYPH: &str = r##"
[s01]
outline = [[10.0, 10.0, "c"], [30.0, 10.0, "c"], [30.0, 30.0, "c"], [10.0, 30.0, "c"]]
holes = [[[16.0, 16.0, "c"], [24.0, 16.0, "c"], [24.0, 24.0, "c"], [16.0, 24.0, "c"]]]

[[stroke]]
id = "S02"
points = [[34.0, 20.0, 4.0], [48.0, 20.0, 4.0]]
"##;

#[test]
fn rasterize_glyph_in_source_pixels() {
    let g = Glyph::from_toml(GLYPH).unwrap();
    let m = rasterize(&g, 0.0, 60, 40, 1.0);
    assert_eq!((m.width, m.height), (60, 40));
    assert!(m.data[12 * 60 + 12]);
    assert!(!m.data[20 * 60 + 20], "hole is empty");
    assert!(!m.data[2 * 60 + 2]);
    assert!(m.data[20 * 60 + 40], "stroke is inked");
    assert_eq!(components(&m), 2);
    assert_eq!(holes(&m), 1);
    let big = rasterize(&g, 0.0, 60, 40, 2.0);
    assert_eq!((big.width, big.height), (120, 80));
    assert!(big.data[24 * 120 + 24]);
}

#[test]
fn small_size_report_counts_pieces_holes_and_width() {
    let g = Glyph::from_toml(GLYPH).unwrap();
    let r = small_size_report(&g, 100);
    assert_eq!(r.px, 100);
    assert_eq!(r.pieces, 2);
    assert_eq!(r.holes, 1);
    // The 4-unit stroke is about 4 * 100/38 = 10 px wide at this size; the bar is the narrowest.
    assert!(r.narrowest > 7.0 && r.narrowest < 12.0, "{}", r.narrowest);
    let tiny = small_size_report(&g, 6);
    assert!(tiny.narrowest < 2.0);
}

#[test]
fn stroke_width_estimate() {
    let mut m = blank(40, 20);
    fill(&mut m, 5, 8, 35, 11);
    assert!((min_stroke_width(&m) - 3.0).abs() < 0.5);
    let mut m = blank(40, 20);
    fill(&mut m, 5, 8, 35, 9);
    assert!((min_stroke_width(&m) - 1.0).abs() < 0.5);
    fill(&mut m, 5, 2, 25, 5);
    assert!((min_stroke_width(&m) - 1.0).abs() < 0.5, "narrowest wins");
    assert_eq!(min_stroke_width(&blank(5, 5)), 0.0);
}

fn field_of(m: &Mask) -> Field {
    Field {
        width: m.width,
        height: m.height,
        data: m
            .data
            .iter()
            .map(|&b| if b { 255.0 } else { 0.0 })
            .collect(),
    }
}

fn area(c: &[(f64, f64)]) -> f64 {
    let n = c.len();
    (0..n)
        .map(|i| c[i].0 * c[(i + 1) % n].1 - c[(i + 1) % n].0 * c[i].1)
        .sum::<f64>()
        / 2.0
}

#[test]
fn marching_squares_traces_outer_and_holes() {
    let mut ring = blank(30, 30);
    fill(&mut ring, 5, 5, 25, 25);
    clear(&mut ring, 10, 10, 20, 20);
    let cs = trace_contours(&field_of(&ring), 127.5);
    assert_eq!(cs.len(), 2);
    let mut areas: Vec<f64> = cs.iter().map(|c| area(c)).collect();
    areas.sort_by(|a, b| b.partial_cmp(a).unwrap());
    // Outer is positive, hole negative, in source-pixel coordinates (pixel edges at +/-0.5).
    assert!((areas[0] - 400.0).abs() < 1.0, "{areas:?}");
    assert!((areas[1] + 100.0).abs() < 1.0, "{areas:?}");
    let all: Vec<_> = cs.iter().flatten().collect();
    assert!(all.iter().all(|p| p.0 >= 4.5 && p.0 <= 25.5));
}

#[test]
fn upsampling_keeps_levels_and_puts_a_binary_edge_on_the_pixel_boundary() {
    let mut m = blank(20, 10);
    fill(&mut m, 0, 0, 8, 10);
    let up = upsample(&field_of(&m), 4);
    assert_eq!((up.width, up.height), (80, 40));
    let at = |x: usize, y: usize| up.data[y * up.width + x];
    assert!((at(8, 20) - 255.0).abs() < 1e-3, "{}", at(8, 20));
    assert!(at(70, 20).abs() < 1e-3);
    assert!(up.data.iter().all(|v| (0.0..=255.0).contains(v)), "clamped");
    // The 50% iso-line of the upsampled step sits on the pixel boundary x = 8.
    let cs = trace_contours(&up, ISO_LEVEL);
    let mid: Vec<f64> = cs[0]
        .iter()
        .filter(|p| (p.1 - 20.0).abs() < 4.0 && p.0 > 16.0)
        .map(|p| p.0 / 4.0)
        .collect();
    assert!(!mid.is_empty());
    assert!(mid.iter().all(|x| (x - 8.0).abs() < 0.05), "{mid:?}");
    // The reference mask is that iso-level at the measuring scale.
    let r = reference_mask(&field_of(&m), MEASURE_SCALE);
    assert_eq!((r.width, r.height), (80, 40));
    // 32 x 40 ink pixels, less a few at the raster's corners (outside counts as background).
    let ink = r.data.iter().filter(|&&b| b).count();
    assert!((1270..=1280).contains(&ink), "{ink}");
}

/// A closed loop whose long side is a pixel staircase (3 px across, 1 px down, 8 times, sampled
/// every 0.25 px) from (0, 0) to (24, 8), closed through the corner (0, 8). Returns the points
/// and the indices of the three corners.
fn staircase() -> (Vec<(f64, f64)>, [usize; 3]) {
    let mut pts = Vec::new();
    for k in 0..8 {
        let (x0, y0) = (3.0 * k as f64, k as f64);
        pts.extend((0..12).map(|i| (x0 + 0.25 * i as f64, y0)));
        pts.extend((0..4).map(|i| (x0 + 3.0, y0 + 0.25 * i as f64)));
    }
    pts.push((24.0, 8.0));
    pts.push((0.0, 8.0));
    let n = pts.len();
    (pts, [0, n - 2, n - 1])
}

#[test]
fn smoothing_along_a_contour_straightens_steps_and_keeps_anchors() {
    let (pts, anchors) = staircase();
    let s = smooth_along(&pts, &anchors, 1.0);
    assert_eq!(s.len(), pts.len());
    for &i in &anchors {
        assert_eq!(s[i], pts[i], "anchor {i} kept");
    }
    // Largest distance from the line through the step middles, y = (x - 1.5) / 3, over the
    // middle of the staircase (away from the pinned ends).
    let off = |p: &(f64, f64)| (p.1 - (p.0 - 1.5) / 3.0).abs() / (1.0f64 + 1.0 / 9.0).sqrt();
    let worst = |v: &[(f64, f64)]| {
        v.iter()
            .filter(|p| p.0 > 6.0 && p.0 < 18.0 && p.1 < 7.9)
            .map(off)
            .fold(0.0f64, f64::max)
    };
    assert!(worst(&pts) > 0.45, "the raw staircase: {}", worst(&pts));
    assert!(worst(&s) < 0.2, "smoothed: {}", worst(&s));
    assert_eq!(smooth_along(&pts, &anchors, 0.0), pts, "sigma 0 is a no-op");
}

#[test]
fn anchored_simplification_keeps_its_anchors() {
    let pts: Vec<(f64, f64)> = (0..40)
        .map(|i| (i as f64, 0.0))
        .chain((0..40).map(|i| (40.0 - i as f64, 10.0)))
        .collect();
    let keep = simplify_anchored(&pts, 0.1, &[0, 17, 55]);
    for a in [0, 17, 55] {
        assert!(keep.contains(&a), "{keep:?}");
    }
    assert!(
        keep.contains(&39) && keep.contains(&40),
        "the real corners: {keep:?}"
    );
    assert!(keep.len() <= 7, "collinear vertices go: {keep:?}");
    assert!(keep.windows(2).all(|w| w[0] < w[1]), "in order");
}

#[test]
fn douglas_peucker_and_corners() {
    let mut r = blank(30, 30);
    fill(&mut r, 5, 5, 25, 15);
    let cs = trace_contours(&field_of(&r), 127.5);
    assert_eq!(cs.len(), 1);
    let s = simplify_closed(&cs[0], 1.0);
    assert_eq!(s.len(), 4, "{s:?}");
    assert_eq!(corner_points(&s, 35.0).len(), 4);
    // Collinear points vanish and a shallow bend is not a corner.
    let flat: Vec<(f64, f64)> = vec![(0.0, 0.0), (5.0, 0.0), (10.0, 0.0), (10.0, 5.0), (0.0, 5.0)];
    assert_eq!(simplify_closed(&flat, 0.1).len(), 4);
    let bend = vec![
        (0.0, 0.0),
        (10.0, 0.0),
        (20.0, 3.0),
        (20.0, 20.0),
        (0.0, 20.0),
    ];
    let c = corner_points(&bend, 35.0);
    assert_eq!(c, vec![0, 2, 3, 4]);
    assert!(!c.contains(&1));
}

#[test]
fn corners_kept_counts_sharp_vertices_within_tolerance() {
    let g = Glyph::from_toml(GLYPH).unwrap();
    let corners = [(10.0, 10.0), (30.0, 30.0), (12.0, 12.0)];
    // Third corner is 2.8 px from the (10,10) vertex but is within 3 px.
    assert!((corners_kept(&corners, &g, 0.0) - 1.0).abs() < 1e-12);
    let far = [(10.0, 10.0), (100.0, 100.0)];
    assert!((corners_kept(&far, &g, 0.0) - 0.5).abs() < 1e-12);
    assert_eq!(corners_kept(&[], &g, 0.0), 1.0);
    // Smooth-tagged vertices do not count.
    let smooth = GLYPH.replace("\"c\"", "\"s\"");
    let gs = Glyph::from_toml(&smooth).unwrap();
    assert_eq!(corners_kept(&[(10.0, 10.0)], &gs, 0.0), 0.0);
}

/// Body with two holes plus four slanted side bars, in a 120x140 field.
fn synthetic_source() -> Mask {
    let mut m = blank(120, 140);
    fill(&mut m, 45, 10, 75, 130);
    clear(&mut m, 52, 25, 68, 40);
    clear(&mut m, 52, 70, 68, 95);
    fill(&mut m, 5, 30, 40, 38);
    fill(&mut m, 5, 80, 40, 88);
    fill(&mut m, 80, 30, 115, 38);
    fill(&mut m, 80, 80, 115, 88);
    m
}

#[test]
fn trace_produces_a_parsable_close_glyph() {
    let src = synthetic_source();
    let toml = trace_toml(&field_of(&src)).unwrap();
    let g = Glyph::from_toml(&toml).unwrap();
    assert_eq!(g.holes.len(), 2);
    assert_eq!(g.strokes.len(), 4);
    assert!(!toml.contains("points ="), "strokes are traced as outlines");
    // Upper row then lower row, left to right.
    let cx = |o: &[icongen::glyph::Vertex]| o.iter().map(|v| v.x).sum::<f64>() / o.len() as f64;
    let cy = |o: &[icongen::glyph::Vertex]| o.iter().map(|v| v.y).sum::<f64>() / o.len() as f64;
    let c: Vec<(f64, f64)> = g
        .strokes
        .iter()
        .map(|s| (cx(&s.outline), cy(&s.outline)))
        .collect();
    assert!(c[0].0 < 45.0 && c[0].1 < 60.0, "{c:?}");
    assert!(c[1].0 > 75.0 && c[1].1 < 60.0, "{c:?}");
    assert!(c[2].0 < 45.0 && c[2].1 > 60.0, "{c:?}");
    assert!(c[3].0 > 75.0 && c[3].1 > 60.0, "{c:?}");
    // Upper hole first.
    assert!(cy(&g.holes[0]) < cy(&g.holes[1]));
    let r = evaluate(&g, 0.0, &field_of(&src));
    assert!(r.iou >= GATE_IOU, "iou {}", r.iou);
    assert!(r.hausdorff <= GATE_HAUSDORFF, "hausdorff {}", r.hausdorff);
    assert_eq!((r.pieces, r.holes), (5, 2));
    assert!(r.corners_kept >= GATE_CORNERS, "corners {}", r.corners_kept);
    assert_eq!(trace_toml(&field_of(&src)).unwrap(), toml, "deterministic");
}

#[test]
fn gates_pass_for_a_good_mark_and_fail_for_a_bad_one() {
    let src = synthetic_source();
    let good = Glyph::from_toml(&trace_toml(&field_of(&src)).unwrap()).unwrap();
    let r = evaluate(&good, 0.0, &field_of(&src));
    assert_eq!(
        r.small.iter().map(|s| s.px).collect::<Vec<_>>(),
        [120, 60, 40]
    );
    assert!(failures(&r).is_empty(), "{:?}", failures(&r));

    let bad = Glyph::from_toml(GLYPH).unwrap();
    let r = evaluate(&bad, 0.0, &field_of(&src));
    let f = failures(&r);
    assert!(f.iter().any(|m| m.contains("IoU")), "{f:?}");
    assert!(f.iter().any(|m| m.contains("topology")), "{f:?}");
}

#[test]
fn per_piece_iou_and_area_catch_one_misplaced_piece() {
    let src = synthetic_source();
    let toml = trace_toml(&field_of(&src)).unwrap();
    let good = Glyph::from_toml(&toml).unwrap();
    let r = evaluate(&good, 0.0, &field_of(&src));
    let ids: Vec<&str> = r.piece_iou.iter().map(|p| p.0.as_str()).collect();
    assert_eq!(ids, ["S01", "S02", "S03", "S04", "S05"]);
    assert!(r.piece_iou.iter().all(|p| p.1 >= GATE_PIECE_IOU), "{r:?}");
    assert!(r.area_diff.abs() <= GATE_AREA, "{}", r.area_diff);
    // Shift one side stroke by 2 px: the whole-mark IoU barely moves, its own IoU drops.
    let mut moved = good.clone();
    for v in &mut moved.strokes[3].outline {
        v.y += 2.0;
    }
    let r = evaluate(&moved, 0.0, &field_of(&src));
    let f = failures(&r);
    assert!(f.iter().any(|m| m.contains("per-piece IoU S05")), "{f:?}");
    assert!(!f.iter().any(|m| m.contains("per-piece IoU S02")), "{f:?}");
    // Growing every piece by 1 px changes the ink area well past the gate.
    let r = evaluate(&good, 1.0, &field_of(&src));
    assert!(failures(&r).iter().any(|m| m.contains("area")), "{r:?}");
}

#[test]
fn master_gates_are_tight() {
    assert_eq!(MEASURE_SCALE, 4);
    assert_eq!(GATE_IOU, 0.975);
    assert_eq!(GATE_HAUSDORFF, 1.0);
    assert_eq!(GATE_CORNERS, 0.9);
    assert_eq!(GATE_PIECE_IOU, 0.96);
    assert_eq!(GATE_AREA, 0.01);
}

fn brand() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../brand")
}

fn brand_text(rel: &str) -> String {
    std::fs::read_to_string(brand().join(rel)).unwrap()
}

#[test]
fn master_at_weight_0_and_every_shipped_theme_pass_their_gates() {
    let (text, ok) = run(&brand()).unwrap();
    assert!(ok, "{text}");
    for name in ["matte", "mono-dark", "mono-light", "tinted"] {
        assert!(text.contains(&format!("theme {name}")), "{text}");
    }
}

#[test]
fn shipped_themes_keep_topology_hole_area_and_40px_width() {
    let g = Glyph::from_toml(&brand_text("mark/mark.toml")).unwrap();
    for name in ["matte", "tinted", "mono-dark", "mono-light"] {
        let t = ThemeCfg::from_toml(&brand_text(&format!("themes/{name}.toml"))).unwrap();
        assert!(t.mark.weight > 0.0, "{name}: themes thicken the mark");
        let c = check_theme(&g, name, &t.mark);
        assert_eq!(
            c.sizes.iter().map(|s| s.px).collect::<Vec<_>>(),
            THEME_SIZES
        );
        assert!(c.sizes.iter().all(|s| s.pieces == 5), "{c:?}");
        assert_eq!(c.sizes[0].holes, 2, "{c:?}");
        let at40 = c.sizes.iter().find(|s| s.px == 40).unwrap();
        assert!(at40.narrowest >= 2.0, "{name}: {at40:?}");
        assert_eq!(c.hole_areas.len(), 2);
        assert!(c.hole_areas.iter().all(|&a| a >= MIN_HOLE_AREA), "{c:?}");
        assert!(c.hole_shares.iter().all(|&s| s >= MIN_HOLE_SHARE), "{c:?}");
        assert!(t.mark.scale <= 0.75, "{name}: 1x safe margin");
        assert!(theme_failures(&c).is_empty(), "{:?}", theme_failures(&c));
    }
}

#[test]
fn shipped_theme_weight_is_the_smallest_that_holds_40px() {
    let g = Glyph::from_toml(&brand_text("mark/mark.toml")).unwrap();
    for name in ["matte", "tinted", "mono-dark", "mono-light"] {
        let t = ThemeCfg::from_toml(&brand_text(&format!("themes/{name}.toml"))).unwrap();
        let mut lighter = t.mark.clone();
        lighter.weight -= 0.1;
        let c = check_theme(&g, name, &lighter);
        let f = theme_failures(&c);
        assert!(f.iter().any(|m| m.contains("40 px")), "{name}: {f:?}");
    }
}

#[test]
fn theme_gates_reject_holes_closed_by_the_weight() {
    let g = Glyph::from_toml(&brand_text("mark/mark.toml")).unwrap();
    let mut t = ThemeCfg::from_toml(&brand_text("themes/matte.toml")).unwrap();
    t.mark.hole_weight = None;
    let c = check_theme(&g, "closed", &t.mark);
    assert!(c.hole_shares[1] < MIN_HOLE_SHARE, "{c:?}");
    let f = theme_failures(&c);
    assert!(f.iter().any(|m| m.contains("hole")), "{f:?}");
}

#[test]
fn theme_gates_reject_the_unweighted_small_mark() {
    let g = Glyph::from_toml(&brand_text("mark/mark.toml")).unwrap();
    let mut t = ThemeCfg::from_toml(&brand_text("themes/matte.toml")).unwrap();
    t.mark.weight = 0.0;
    t.mark.scale = 0.64;
    let c = check_theme(&g, "thin", &t.mark);
    let at40 = c.sizes.iter().find(|s| s.px == 40).unwrap();
    assert!(at40.narrowest < 2.0, "{at40:?}");
    let f = theme_failures(&c);
    assert!(f.iter().any(|m| m.contains("40 px")), "{f:?}");
}
