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
    Ok(files)
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
    let mut buf = vec![0; rd.output_buffer_size()];
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

/// Compares regenerated output with the committed files; returns one message per mismatch.
/// SVG/JSON must match byte for byte, PNG within +-2 per channel.
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
            Ok(actual) if &actual != expected => problems.push(format!("{rel}: out of date")),
            Ok(_) => {}
        }
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}
