//! Brand directory -> generated files, plus the `generate` / `check` drivers.

use crate::config::{IconCfg, ThemeCfg, parse_hex};
use crate::glyph::Glyph;
use crate::{png_out, render, svg};
use std::path::Path;

/// Generated files as `(path relative to the brand dir, bytes)`.
pub type Files = Vec<(String, Vec<u8>)>;

fn read(brand: &Path, rel: &str) -> Result<String, String> {
    std::fs::read_to_string(brand.join(rel)).map_err(|e| format!("{rel}: {e}"))
}

/// Regenerates every output in memory (no filesystem writes).
pub fn build(brand: &Path) -> Result<Files, String> {
    let icon = IconCfg::from_toml(&read(brand, "icon.toml")?)?;
    let glyph = Glyph::from_toml(&read(brand, "mark/mark.toml")?)?;
    let mut files: Files = Vec::new();
    let mut manifest = format!("{{\n  \"size\": {},\n  \"appearances\": [\n", icon.size);
    let apps = [
        ("light", &icon.appearances.light),
        ("dark", &icon.appearances.dark),
        ("tinted", &icon.appearances.tinted),
    ];
    for (i, (appearance, theme_name)) in apps.iter().enumerate() {
        if theme_name.is_empty()
            || !theme_name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            return Err(format!("bad theme name {theme_name:?}"));
        }
        let theme = ThemeCfg::from_toml(&read(brand, &format!("themes/{theme_name}.toml"))?)?;
        let l = svg::layers(&theme, &glyph, icon.size);
        let dir = format!("out/{appearance}");
        for (name, text) in [
            ("base", &l.base),
            ("texture", &l.texture),
            ("mark", &l.mark),
            ("gloss", &l.gloss),
            ("container", &l.container),
            ("composite", &l.composite),
        ] {
            files.push((format!("{dir}/{name}.svg"), text.clone().into_bytes()));
        }
        let pix = render::render(&l.composite, icon.size)?;
        let bg = parse_hex(&theme.background.color).ok_or("bad background color")?;
        files.push((format!("{dir}/icon.png"), png_out::encode_rgb(&pix, bg)));
        let b = l.bounds;
        manifest.push_str(&format!(
            "    {{ \"appearance\": \"{appearance}\", \"theme\": \"{theme_name}\", \"mark_bounds\": [{}, {}, {}, {}] }}{}\n",
            svg::fmt(b.x0),
            svg::fmt(b.y0),
            svg::fmt(b.x1),
            svg::fmt(b.y1),
            if i + 1 < apps.len() { "," } else { "" }
        ));
    }
    manifest.push_str("  ]\n}\n");
    files.push(("out/manifest.json".into(), manifest.into_bytes()));
    catalog(&icon, &mut files);
    exports(brand, &glyph, &mut files)?;
    Ok(files)
}

const CONTENTS_JSON: &str = r#"{
  "images" : [
    {
      "filename" : "AppIcon-light.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"#;

/// The AppIcon asset catalog: the three rendered icons plus the iOS 18 single-size manifest.
/// Paths are relative to the brand dir (the catalog lives beside it in the repo).
fn catalog(icon: &IconCfg, files: &mut Files) {
    let dir = format!("../{}", icon.appiconset);
    let mut extra: Files = Vec::new();
    for a in ["light", "dark", "tinted"] {
        let want = format!("out/{a}/icon.png");
        let png = files
            .iter()
            .find(|(n, _)| *n == want)
            .expect("icon rendered above")
            .1
            .clone();
        extra.push((format!("{dir}/AppIcon-{a}.png"), png));
    }
    extra.push((
        format!("{dir}/Contents.json"),
        CONTENTS_JSON.as_bytes().to_vec(),
    ));
    files.extend(extra);
}

/// Pixel sizes of the squircle favicon exports.
const FAVICONS: [u32; 3] = [16, 32, 48];
const README_PX: u32 = 256;

/// Brand exports from the mono themes: transparent marks, favicons and a README icon.
fn exports(brand: &Path, glyph: &Glyph, files: &mut Files) -> Result<(), String> {
    let theme = |name: &str| ThemeCfg::from_toml(&read(brand, &format!("themes/{name}.toml"))?);
    let dark = theme("mono-dark")?; // ivory mark on near-black
    let light = theme("mono-light")?; // black mark on warm white
    let size = 1024;
    // Mark-only SVGs: black for light backgrounds, ivory for dark ones.
    files.push((
        "out/exports/mark.svg".into(),
        svg::layers(&light, glyph, size).mark.into_bytes(),
    ));
    files.push((
        "out/exports/mark-light.svg".into(),
        svg::layers(&dark, glyph, size).mark.into_bytes(),
    ));
    for px in FAVICONS {
        let pix = render::render(&svg::layers(&dark, glyph, px).composite, px)?;
        files.push((
            format!("out/exports/favicon-{px}.png"),
            png_out::encode_rgba(&pix),
        ));
    }
    let pix = render::render(&svg::layers(&dark, glyph, README_PX).composite, README_PX)?;
    files.push((
        "out/exports/readme-256.png".into(),
        png_out::encode_rgba(&pix),
    ));
    Ok(())
}

/// Writes all generated files under the brand dir.
pub fn write(brand: &Path) -> Result<usize, String> {
    let files = build(brand)?;
    for (rel, bytes) in &files {
        let path = brand.join(rel);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{rel}: {e}"))?;
        }
        std::fs::write(&path, bytes).map_err(|e| format!("{rel}: {e}"))?;
    }
    Ok(files.len())
}

fn decode(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    let mut rd = png::Decoder::new(std::io::Cursor::new(bytes))
        .read_info()
        .map_err(|e| e.to_string())?;
    let mut buf = vec![0; rd.output_buffer_size().ok_or("PNG too large")?];
    let fr = rd.next_frame(&mut buf).map_err(|e| e.to_string())?;
    buf.truncate(fr.buffer_size());
    Ok((fr.width, fr.height, buf))
}

/// True when two PNGs have equal size and every channel differs by at most `tol`.
pub fn png_close(a: &[u8], b: &[u8], tol: u8) -> Result<bool, String> {
    let (wa, ha, da) = decode(a)?;
    let (wb, hb, db) = decode(b)?;
    Ok((wa, ha, da.len()) == (wb, hb, db.len())
        && da.iter().zip(&db).all(|(x, y)| x.abs_diff(*y) <= tol))
}

/// Numeric tolerance for SVG/JSON comparison, in user units.
pub const TEXT_TOL: f64 = 1e-3;

enum Tok<'a> {
    Text(&'a str),
    Num(f64),
}

/// Splits text into numbers (`-?digits(.digits)?`) and everything else. Hex colours (`#` plus
/// its alphanumeric run) stay text; an identifier such as `S01` yields a small number, which
/// still differs from `S02` by far more than any tolerance.
fn tokens(s: &str) -> Vec<Tok<'_>> {
    let b = s.as_bytes();
    let (mut out, mut start, mut i) = (Vec::new(), 0, 0);
    while i < b.len() {
        if b[i] == b'#' {
            i += 1;
            while i < b.len() && b[i].is_ascii_alphanumeric() {
                i += 1;
            }
            continue;
        }
        let starts =
            b[i].is_ascii_digit() || (b[i] == b'-' && b.get(i + 1).is_some_and(u8::is_ascii_digit));
        if !starts {
            i += 1;
            continue;
        }
        let mut j = i + 1;
        while j < b.len() && b[j].is_ascii_digit() {
            j += 1;
        }
        if j + 1 < b.len() && b[j] == b'.' && b[j + 1].is_ascii_digit() {
            j += 1;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
        }
        match s[i..j].parse::<f64>() {
            Ok(v) => {
                if start < i {
                    out.push(Tok::Text(&s[start..i]));
                }
                out.push(Tok::Num(v));
                (start, i) = (j, j);
            }
            Err(_) => i = j,
        }
    }
    if start < b.len() {
        out.push(Tok::Text(&s[start..]));
    }
    out
}

/// True when two SVG/JSON texts have identical non-numeric text and every number differs by at
/// most `tol`, so float formatting differences between platforms do not fail `check`. Content
/// that is not UTF-8 must match byte for byte.
pub fn text_close(a: &[u8], b: &[u8], tol: f64) -> bool {
    let (Ok(a), Ok(b)) = (std::str::from_utf8(a), std::str::from_utf8(b)) else {
        return a == b;
    };
    let (ta, tb) = (tokens(a), tokens(b));
    ta.len() == tb.len()
        && ta.iter().zip(&tb).all(|pair| match pair {
            (Tok::Text(x), Tok::Text(y)) => x == y,
            (Tok::Num(x), Tok::Num(y)) => (x - y).abs() <= tol,
            _ => false,
        })
}

/// Compares regenerated output with the committed files; returns one message per mismatch.
/// SVG/JSON must match up to [`TEXT_TOL`] on numbers (other text exactly), PNG within +-2 per
/// channel.
pub fn check(brand: &Path) -> Result<(), Vec<String>> {
    let files = build(brand).map_err(|e| vec![e])?;
    let mut problems = Vec::new();
    for (rel, expected) in &files {
        match std::fs::read(brand.join(rel)) {
            Err(_) => problems.push(format!("{rel}: missing")),
            Ok(actual) if rel.ends_with(".png") => match png_close(expected, &actual, 2) {
                Ok(true) => {}
                Ok(false) => problems.push(format!("{rel}: pixels differ")),
                Err(e) => problems.push(format!("{rel}: {e}")),
            },
            Ok(actual) if !text_close(expected, &actual, TEXT_TOL) => {
                problems.push(format!("{rel}: out of date"));
            }
            Ok(_) => {}
        }
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}
