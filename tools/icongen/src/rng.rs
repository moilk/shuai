//! Minimal PCG32 (XSH RR) generator, so texture output is reproducible without a `rand` dependency.

const MULT: u64 = 6364136223846793005;

#[derive(Debug, Clone)]
pub struct Pcg32 {
    state: u64,
    inc: u64,
}

impl Pcg32 {
    /// Reference seeding (`pcg32_srandom_r`).
    pub fn new(initstate: u64, initseq: u64) -> Self {
        let mut r = Pcg32 {
            state: 0,
            inc: (initseq << 1) | 1,
        };
        r.next_u32();
        r.state = r.state.wrapping_add(initstate);
        r.next_u32();
        r
    }

    /// Seed from a single number (fixed stream).
    pub fn from_seed(seed: u64) -> Self {
        Self::new(seed, 0xda3e_39cb_94b9_5bdb)
    }

    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(MULT).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    /// Uniform in `[0, 1)`.
    pub fn next_f64(&mut self) -> f64 {
        f64::from(self.next_u32()) / 4_294_967_296.0
    }

    /// Uniform in `[lo, hi)`.
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next_f64()
    }
}
