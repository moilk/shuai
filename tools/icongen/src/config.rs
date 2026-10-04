//! Parsing of `brand/icon.toml` and `brand/themes/*.toml`.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct IconCfg {
    pub size: u32,
    pub appearances: Appearances,
    /// Asset catalog directory, relative to the repository root (the brand dir's parent).
    #[serde(default = "default_appiconset")]
    pub appiconset: String,
}

fn default_appiconset() -> String {
    "apple/App/Resources/Assets.xcassets/AppIcon.appiconset".into()
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Appearances {
    pub light: String,
    pub dark: String,
    pub tinted: String,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum BackgroundKind {
    Solid,
    Linear,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct BackgroundCfg {
    pub kind: BackgroundKind,
    pub color: String,
    /// Second stop, only used by `linear`.
    #[serde(default)]
    pub color2: Option<String>,
    /// Gradient direction in degrees (0 = left to right, 90 = top to bottom).
    #[serde(default)]
    pub angle: f64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TextureCfg {
    pub enabled: bool,
    pub seed: u64,
    pub grain: f64,
    pub cracks: u32,
    pub motifs: u32,
    pub color: String,
    pub opacity: f64,
    pub keepout: f64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MarkCfg {
    pub fill: String,
    /// Uniform outline offset in source pixels (0 = the master carving).
    #[serde(default)]
    pub weight: f64,
    /// How far the S01 holes shrink, source pixels (default: `weight`). Lower keeps the counters
    /// open on a heavier mark.
    #[serde(default)]
    pub hole_weight: Option<f64>,
    pub scale: f64,
    #[serde(default)]
    pub offset: [f64; 2],
    /// Extra weight for renders at or below a size (favicons and other tiny exports).
    #[serde(default)]
    pub small_size: Option<SmallSizeCfg>,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SmallSizeCfg {
    /// Output sizes (px) at or below this get the bonus.
    pub max_px: u32,
    /// Weight added on top of `mark.weight`, source pixels.
    pub weight: f64,
}

/// Largest accepted outline offset, source pixels.
pub const MAX_WEIGHT: f64 = 6.0;

impl MarkCfg {
    /// Outline offset for a render whose canvas is `size` pixels.
    pub fn weight_at(&self, size: u32) -> f64 {
        match self.small_size {
            Some(s) if size <= s.max_px => self.weight + s.weight,
            _ => self.weight,
        }
    }

    /// Hole shrink for a render whose canvas is `size` pixels: `hole_weight` (default `weight`)
    /// plus the small-size bonus.
    pub fn hole_weight_at(&self, size: u32) -> f64 {
        self.hole_weight.unwrap_or(self.weight) + (self.weight_at(size) - self.weight)
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct GlossCfg {
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ContainerCfg {
    /// `none` or `squircle`.
    pub kind: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ThemeCfg {
    pub name: String,
    pub background: BackgroundCfg,
    pub texture: TextureCfg,
    pub mark: MarkCfg,
    pub gloss: GlossCfg,
    pub container: ContainerCfg,
}

/// Parses `#rrggbb`.
pub fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let h = s.strip_prefix('#')?;
    if h.len() != 6 || !h.is_ascii() {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some([p(0)?, p(2)?, p(4)?])
}

fn check_color(what: &str, s: &str) -> Result<(), String> {
    parse_hex(s)
        .map(|_| ())
        .ok_or_else(|| format!("{what}: expected #rrggbb, got {s:?}"))
}

impl IconCfg {
    pub fn from_toml(s: &str) -> Result<Self, String> {
        let c: IconCfg = toml::from_str(s).map_err(|e| e.to_string())?;
        if !(16..=4096).contains(&c.size) {
            return Err(format!("size out of range: {}", c.size));
        }
        let p = std::path::Path::new(&c.appiconset);
        if c.appiconset.is_empty()
            || !p
                .components()
                .all(|k| matches!(k, std::path::Component::Normal(_)))
        {
            return Err(format!(
                "appiconset must be a relative path inside the repo: {:?}",
                c.appiconset
            ));
        }
        Ok(c)
    }
}

impl ThemeCfg {
    pub fn from_toml(s: &str) -> Result<Self, String> {
        let t: ThemeCfg = toml::from_str(s).map_err(|e| e.to_string())?;
        check_color("background.color", &t.background.color)?;
        match (&t.background.kind, &t.background.color2) {
            (BackgroundKind::Linear, None) => return Err("linear background needs color2".into()),
            (_, Some(c2)) => check_color("background.color2", c2)?,
            _ => {}
        }
        check_color("texture.color", &t.texture.color)?;
        check_color("mark.fill", &t.mark.fill)?;
        if !(0.0..=1.0).contains(&t.texture.opacity) {
            return Err("texture.opacity must be within 0..=1".into());
        }
        if !(t.mark.scale > 0.0 && t.mark.scale <= 1.0) {
            return Err("mark.scale must be within (0, 1]".into());
        }
        let bonus = t.mark.small_size.map_or(0.0, |s| s.weight);
        if !(0.0..=MAX_WEIGHT).contains(&t.mark.weight)
            || !(0.0..=MAX_WEIGHT).contains(&bonus)
            || !(0.0..=MAX_WEIGHT).contains(&(t.mark.weight + bonus))
        {
            return Err(format!(
                "mark.weight and small_size.weight must be within 0..={MAX_WEIGHT} source px"
            ));
        }
        if let Some(h) = t.mark.hole_weight
            && !(0.0..=t.mark.weight).contains(&h)
        {
            return Err("mark.hole_weight must be within 0..=mark.weight".into());
        }
        if !matches!(t.container.kind.as_str(), "none" | "squircle") {
            return Err(format!("unknown container kind {:?}", t.container.kind));
        }
        Ok(t)
    }
}
