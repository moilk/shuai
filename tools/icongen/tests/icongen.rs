use icongen::config::{BackgroundKind, IconCfg, ThemeCfg};
use icongen::glyph::{Cap, Glyph, Tag, Vertex, segments, stroke_outline};
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
    assert_eq!(t.background.color, "#7a1f1a");
    assert!(t.texture.enabled);
    assert_eq!(t.texture.seed, 20241004);
    assert_eq!(t.texture.cracks, 5);
    assert_eq!(t.texture.motifs, 6);
    assert!((t.texture.opacity - 0.18).abs() < 1e-12);
    assert_eq!(t.mark.fill, "#f1e6d0");
    assert!((t.mark.scale - 0.75).abs() < 1e-12);
    assert_eq!(t.mark.offset, [0.0, 0.0]);
    assert!(!t.gloss.enabled);
    assert_eq!(t.container.kind, "none");
}

#[test]
fn rejects_bad_theme_config() {
    let bad = read("themes/matte.toml").replace("#7a1f1a", "red");
    assert!(ThemeCfg::from_toml(&bad).is_err());
    let bad = read("themes/matte.toml").replace("\"solid\"", "\"radial\"");
    assert!(ThemeCfg::from_toml(&bad).is_err());
}

#[test]
fn parses_icon_config() {
    let c = IconCfg::from_toml(&read("icon.toml")).unwrap();
    assert_eq!(c.size, 1024);
    assert_eq!(c.appearances.light, "matte");
    assert_eq!(c.appearances.tinted, "matte");
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
    let bad = read("mark/mark.toml").replacen("60.0, 40.0, \"s\"", "60.0, 40.0, \"x\"", 1);
    assert!(Glyph::from_toml(&bad).is_err());
}

fn v(x: f64, y: f64, t: Tag) -> Vertex {
    Vertex { x, y, tag: t }
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
