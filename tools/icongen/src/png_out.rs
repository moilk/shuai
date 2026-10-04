//! PNG writer: RGB 8-bit, sRGB chunk, no alpha / tRNS / iCCP, flattened over a background colour.

use resvg::tiny_skia::Pixmap;

/// Encodes the (premultiplied RGBA) pixmap as an RGBA PNG with straight alpha and an sRGB chunk.
pub fn encode_rgba(pix: &Pixmap) -> Vec<u8> {
    let mut rgba = Vec::with_capacity(pix.width() as usize * pix.height() as usize * 4);
    for p in pix.pixels() {
        let c = p.demultiply();
        rgba.extend_from_slice(&[c.red(), c.green(), c.blue(), c.alpha()]);
    }
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, pix.width(), pix.height());
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_source_srgb(png::SrgbRenderingIntent::Perceptual);
    let mut w = enc.write_header().expect("png header");
    w.write_image_data(&rgba).expect("png data");
    w.finish().expect("png finish");
    out
}

/// Flattens the (premultiplied RGBA) pixmap over `bg` and encodes an opaque RGB PNG.
pub fn encode_rgb(pix: &Pixmap, bg: [u8; 3]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(pix.width() as usize * pix.height() as usize * 3);
    for p in pix.pixels() {
        let inv = 255 - u32::from(p.alpha());
        for (c, b) in [p.red(), p.green(), p.blue()].into_iter().zip(bg) {
            // Premultiplied source over opaque background.
            let v = u32::from(c) + (u32::from(b) * inv + 127) / 255;
            rgb.push(v.min(255) as u8);
        }
    }
    let mut out = Vec::new();
    let mut enc = png::Encoder::new(&mut out, pix.width(), pix.height());
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_source_srgb(png::SrgbRenderingIntent::Perceptual);
    let mut w = enc.write_header().expect("png header");
    w.write_image_data(&rgb).expect("png data");
    w.finish().expect("png finish");
    out
}
