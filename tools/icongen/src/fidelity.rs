//! Fidelity metrics of the vector mark against the source raster. Extended by the fidelity task.

/// Binary raster mask, row-major, `true` = ink.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mask {
    pub width: usize,
    pub height: usize,
    pub data: Vec<bool>,
}

/// Intersection over union of two masks of equal size (1.0 when both are empty).
pub fn iou(a: &Mask, b: &Mask) -> f64 {
    assert_eq!(
        (a.width, a.height),
        (b.width, b.height),
        "mask size mismatch"
    );
    let (mut inter, mut union) = (0usize, 0usize);
    for (&x, &y) in a.data.iter().zip(&b.data) {
        inter += usize::from(x && y);
        union += usize::from(x || y);
    }
    if union == 0 {
        1.0
    } else {
        inter as f64 / union as f64
    }
}
