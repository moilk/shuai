//! Asset catalog and export outputs written by `generate` and verified by `check`.

use icongen::pipeline;
use std::path::{Path, PathBuf};

const SET: &str = "../apple/App/Resources/Assets.xcassets/AppIcon.appiconset";

fn brand() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../brand")
}

fn file<'a>(files: &'a pipeline::Files, rel: &str) -> &'a [u8] {
    files
        .iter()
        .find(|(n, _)| n == rel)
        .unwrap_or_else(|| panic!("missing {rel}"))
        .1
        .as_slice()
}

fn decode(bytes: &[u8]) -> (png::Info<'static>, Vec<u8>) {
    let mut rd = png::Decoder::new(std::io::Cursor::new(bytes))
        .read_info()
        .unwrap();
    let mut buf = vec![0; rd.output_buffer_size()];
    let fr = rd.next_frame(&mut buf).unwrap();
    buf.truncate(fr.buffer_size());
    (rd.info().clone(), buf)
}

#[test]
fn appiconset_pngs_are_opaque_srgb_rgb_1024() {
    let files = pipeline::build(&brand()).unwrap();
    for name in ["light", "dark", "tinted"] {
        let bytes = file(&files, &format!("{SET}/AppIcon-{name}.png"));
        let (info, _) = decode(bytes);
        assert_eq!(info.color_type, png::ColorType::Rgb, "{name}");
        assert_eq!(info.bit_depth, png::BitDepth::Eight, "{name}");
        assert_eq!((info.width, info.height), (1024, 1024), "{name}");
        assert!(info.srgb.is_some(), "{name}: sRGB chunk");
        assert!(info.trns.is_none() && info.icc_profile.is_none(), "{name}");
        // The catalog image is the rendered icon.
        assert_eq!(bytes, file(&files, &format!("out/{name}/icon.png")));
    }
}

#[test]
fn appiconset_contents_json_declares_dark_and_tinted() {
    let files = pipeline::build(&brand()).unwrap();
    let json = String::from_utf8(file(&files, &format!("{SET}/Contents.json")).to_vec()).unwrap();
    for want in [
        "\"filename\" : \"AppIcon-light.png\"",
        "\"filename\" : \"AppIcon-dark.png\"",
        "\"filename\" : \"AppIcon-tinted.png\"",
        "\"appearance\" : \"luminosity\"",
        "\"value\" : \"dark\"",
        "\"value\" : \"tinted\"",
        "\"size\" : \"1024x1024\"",
        "\"platform\" : \"ios\"",
    ] {
        assert!(json.contains(want), "missing {want}");
    }
    assert!(json.ends_with("}\n"));
}

#[test]
fn exports_are_mono_marks_favicons_and_readme_icon() {
    let files = pipeline::build(&brand()).unwrap();
    let mark = String::from_utf8(file(&files, "out/exports/mark.svg").to_vec()).unwrap();
    assert!(mark.contains("fill=\"#000000\"") && !mark.contains("id=\"base\""));
    let light = String::from_utf8(file(&files, "out/exports/mark-light.svg").to_vec()).unwrap();
    assert!(light.contains("fill=\"#f7f5f2\"") && !light.contains("id=\"base\""));
    for px in [16u32, 32, 48] {
        let (info, _) = decode(file(&files, &format!("out/exports/favicon-{px}.png")));
        assert_eq!((info.width, info.height), (px, px));
    }
    let (info, px) = decode(file(&files, "out/exports/readme-256.png"));
    assert_eq!((info.width, info.height), (256, 256));
    assert_eq!(info.color_type, png::ColorType::Rgba);
    assert_eq!(px[3], 0, "squircle corner is transparent");
    let mid = (128 * 256 + 4) * 4;
    assert_eq!(px[mid + 3], 255, "container body is opaque");
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let dst = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &dst);
        } else {
            std::fs::copy(e.path(), dst).unwrap();
        }
    }
}

/// A scratch repo root holding `brand/` (configs only) so appiconset paths resolve beside it.
fn scratch(name: &str) -> PathBuf {
    let root = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = std::fs::remove_dir_all(&root);
    for d in ["mark", "themes"] {
        copy_dir(&brand().join(d), &root.join("brand").join(d));
    }
    std::fs::copy(brand().join("icon.toml"), root.join("brand/icon.toml")).unwrap();
    root
}

#[test]
fn appiconset_path_must_stay_inside_the_repo() {
    let base = std::fs::read_to_string(brand().join("icon.toml")).unwrap();
    assert!(icongen::config::IconCfg::from_toml(&base).is_ok());
    for bad in ["/abs/path", "../outside", "a/../b", ""] {
        let t = base.replace(
            "apple/App/Resources/Assets.xcassets/AppIcon.appiconset",
            bad,
        );
        assert!(
            icongen::config::IconCfg::from_toml(&t).is_err(),
            "{bad:?} accepted"
        );
    }
}

#[test]
fn check_fails_when_catalog_or_export_files_are_stale() {
    let root = scratch("export-stale");
    let b = root.join("brand");
    pipeline::write(&b).unwrap();
    pipeline::check(&b).unwrap();
    let set = root.join("apple/App/Resources/Assets.xcassets/AppIcon.appiconset");
    assert!(set.join("AppIcon-dark.png").exists());

    // Stale catalog PNG (a different image).
    let keep = std::fs::read(set.join("AppIcon-dark.png")).unwrap();
    std::fs::copy(set.join("AppIcon-tinted.png"), set.join("AppIcon-dark.png")).unwrap();
    let errs = pipeline::check(&b).unwrap_err();
    assert!(
        errs.iter().any(|e| e.contains("AppIcon-dark.png")),
        "{errs:?}"
    );
    std::fs::write(set.join("AppIcon-dark.png"), keep).unwrap();
    pipeline::check(&b).unwrap();

    // Contents.json is byte-exact.
    let json = std::fs::read_to_string(set.join("Contents.json")).unwrap();
    std::fs::write(set.join("Contents.json"), json.replace("dark", "Dark")).unwrap();
    let errs = pipeline::check(&b).unwrap_err();
    assert!(errs.iter().any(|e| e.contains("Contents.json")), "{errs:?}");
    std::fs::write(set.join("Contents.json"), json).unwrap();

    // Exports.
    std::fs::remove_file(b.join("out/exports/favicon-16.png")).unwrap();
    std::fs::write(b.join("out/exports/mark.svg"), "<svg/>").unwrap();
    let errs = pipeline::check(&b).unwrap_err();
    assert!(
        errs.iter().any(|e| e.contains("favicon-16.png")),
        "{errs:?}"
    );
    assert!(
        errs.iter().any(|e| e.contains("exports/mark.svg")),
        "{errs:?}"
    );
}
