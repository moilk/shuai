use icongen::config::TextureCfg;
use icongen::glyph::MarkBounds;
use icongen::{render, texture};

const SIZE: u32 = 1024;

fn cfg() -> TextureCfg {
    TextureCfg {
        enabled: true,
        seed: 20241004,
        grain: 0.35,
        cracks: 5,
        motifs: 6,
        color: "#000000".into(),
        opacity: 0.18,
        keepout: 0.04,
    }
}

fn bounds() -> MarkBounds {
    MarkBounds {
        x0: 128.0,
        y0: 128.0,
        x1: 896.0,
        y1: 896.0,
    }
}

fn tex(c: &TextureCfg) -> String {
    texture::layer_svg(c, &bounds(), SIZE)
}

/// Content of the `<g id="NAME" ...>...</g>` group (groups are not nested).
fn group(svg: &str, name: &str) -> String {
    let start = svg
        .find(&format!("<g id=\"{name}\""))
        .unwrap_or_else(|| panic!("group {name} missing"));
    let rest = &svg[start..];
    let end = rest.find("</g>").unwrap();
    rest[..end].to_string()
}

/// All coordinate pairs of the `d="..."` attributes in a fragment (absolute M/L/Z paths only).
fn points(frag: &str) -> Vec<(f64, f64)> {
    let mut out = Vec::new();
    let mut rest = frag;
    while let Some(i) = rest.find(" d=\"") {
        rest = &rest[i + 4..];
        let end = rest.find('"').unwrap();
        let nums: Vec<f64> = rest[..end]
            .split(|c: char| c.is_ascii_alphabetic() || c.is_whitespace() || c == ',')
            .filter(|t| !t.is_empty())
            .map(|t| t.parse().unwrap())
            .collect();
        assert_eq!(nums.len() % 2, 0);
        out.extend(nums.chunks(2).map(|c| (c[0], c[1])));
        rest = &rest[end..];
    }
    out
}

fn fnv1a(s: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

#[test]
fn disabled_is_empty() {
    let mut c = cfg();
    c.enabled = false;
    assert_eq!(tex(&c), "");
}

#[test]
fn same_seed_is_byte_identical() {
    assert_eq!(tex(&cfg()), tex(&cfg()));
}

#[test]
fn different_seed_differs() {
    let mut c = cfg();
    c.seed += 1;
    let (a, b) = (tex(&cfg()), tex(&c));
    assert_ne!(a, b);
    assert_ne!(group(&a, "grain"), group(&b, "grain"));
    assert_ne!(group(&a, "cracks"), group(&b, "cracks"));
    assert_ne!(group(&a, "motifs"), group(&b, "motifs"));
}

#[test]
fn element_classes_are_independent() {
    let base = tex(&cfg());
    let mut c = cfg();
    c.motifs = 11;
    let m = tex(&c);
    assert_eq!(group(&base, "grain"), group(&m, "grain"));
    assert_eq!(group(&base, "cracks"), group(&m, "cracks"));
    assert_ne!(group(&base, "motifs"), group(&m, "motifs"));
    let mut c = cfg();
    c.cracks = 9;
    let k = tex(&c);
    assert_eq!(group(&base, "grain"), group(&k, "grain"));
    assert_eq!(group(&base, "motifs"), group(&k, "motifs"));
    assert_ne!(group(&base, "cracks"), group(&k, "cracks"));
}

#[test]
fn counts_are_honoured() {
    let svg = tex(&cfg());
    assert_eq!(group(&svg, "cracks").matches("<path").count(), 5);
    assert_eq!(group(&svg, "motifs").matches("<path").count(), 6);
}

#[test]
fn cracks_and_motifs_stay_out_of_keepout() {
    for seed in [1u64, 2, 3, 20241004] {
        let mut c = cfg();
        c.seed = seed;
        c.cracks = 12;
        c.motifs = 12;
        let svg = tex(&c);
        let k = c.keepout * f64::from(SIZE);
        let b = bounds();
        let (x0, y0, x1, y1) = (b.x0 - k, b.y0 - k, b.x1 + k, b.y1 + k);
        for name in ["cracks", "motifs"] {
            let pts = points(&group(&svg, name));
            assert!(!pts.is_empty(), "{name} empty for seed {seed}");
            for (x, y) in pts {
                assert!(
                    !(x > x0 && x < x1 && y > y0 && y < y1),
                    "{name} point ({x},{y}) inside keep-out, seed {seed}"
                );
                assert!(
                    (0.0..=f64::from(SIZE)).contains(&x) && (0.0..=f64::from(SIZE)).contains(&y),
                    "{name} point outside canvas"
                );
            }
        }
    }
}

#[test]
fn size_and_render_time_are_reasonable() {
    let svg = tex(&cfg());
    assert!(svg.len() < 1_500_000, "svg is {} bytes", svg.len());
    let doc = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">{svg}</svg>"
    );
    let t = std::time::Instant::now();
    render::render(&doc, 1024).unwrap();
    assert!(t.elapsed().as_secs_f64() < 2.0);
}

fn lin(c: u8) -> f64 {
    let v = f64::from(c) / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

fn lum(r: u8, g: u8, b: u8) -> f64 {
    0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

/// Brightest pixel of the texture over `bg`, as relative luminance.
fn max_bg_luminance(c: &TextureCfg, bg: &str) -> f64 {
    let doc = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\" fill=\"{bg}\"/>{}</svg>",
        tex(c)
    );
    let pix = render::render(&doc, 1024).unwrap();
    pix.data()
        .chunks(4)
        .map(|p| lum(p[0], p[1], p[2]))
        .fold(0.0, f64::max)
}

#[test]
fn mark_keeps_7_to_1_contrast_over_texture() {
    let mark = lum(0xf1, 0xe6, 0xd0);
    // The matte theme as shipped.
    let l = max_bg_luminance(&cfg(), "#7a1f1a");
    assert!(
        (mark + 0.05) / (l + 0.05) >= 7.0,
        "contrast {}",
        (mark + 0.05) / (l + 0.05)
    );
    // Faint ivory scratches at a capped opacity.
    let mut c = cfg();
    c.color = "#f1e6d0".into();
    c.opacity = 0.05;
    let l = max_bg_luminance(&c, "#7a1f1a");
    assert!(
        (mark + 0.05) / (l + 0.05) >= 7.0,
        "contrast {}",
        (mark + 0.05) / (l + 0.05)
    );
}

#[test]
fn opacity_caps_ink_coverage() {
    let mut c = cfg();
    c.color = "#ffffff".into();
    c.opacity = 0.2;
    // Pure white over black: 0.2 coverage is at most sRGB 51 (+1 rounding).
    let doc = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\" fill=\"#000000\"/>{}</svg>",
        tex(&c)
    );
    let pix = render::render(&doc, 1024).unwrap();
    let max = pix.data().chunks(4).map(|p| p[0]).max().unwrap();
    assert!(max <= 52, "max channel {max}");
    assert!(max > 0);
}

#[test]
fn known_output_snapshot() {
    let svg = tex(&cfg());
    assert_eq!(svg.len(), 0, "len");
    assert_eq!(fnv1a(&svg), 0, "hash");
}
