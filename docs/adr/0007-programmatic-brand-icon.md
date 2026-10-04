# ADR 0007: Generate the app icon programmatically from a traced master glyph

Status: Accepted

## Context

The icon is the oracle-bone character 率 on a dark, textured stone field. iOS 18 wants three
appearances of one 1024 px icon (default, dark, tinted), and the project also needs brand exports
(README icon, favicons, transparent marks). Requirements:

- Fidelity to the original glyph comes first; the canonical glyph source is the raster
  `brand/source/oracle-rate.png`.
- Every variant (background, texture, mark colour, weight) is a small configuration change that does
  not touch the glyph geometry.
- The result is reproducible and reviewable in a PR, and drift is caught by CI.
- No heavy toolchain for contributors who only build the app.

## Decision

A small Rust tool, `tools/icongen` (its own Cargo workspace, not part of `core/`), generates
everything from plain-text configuration under `brand/`:

- The glyph is traced once from the source PNG at sub-pixel accuracy (bicubic 4x upsample, 50%
  iso-contour, smoothing between carved corners, simplification) into `brand/mark/mark.toml`, a
  dense outline per piece. The tracer output is committed and then curated; the source PNG is the
  reference the fidelity gates measure against.
- Themes (`brand/themes/*.toml`) describe background, texture, mark fill, weight and scale. A mark
  weight is a uniform mitred outline offset, never a different glyph.
- `icongen generate` renders layered SVG (base, texture, mark, gloss, container, composite) with
  fixed-precision numbers, rasterises with resvg to opaque 8-bit sRGB RGB PNGs, and writes the
  asset catalog and exports. Outputs are committed.
- `icongen check` regenerates in memory and compares (SVG and JSON byte-exact, PNG within +-2 per
  channel); `icongen fidelity` enforces numeric fidelity gates. Both run in CI (`icon` job).
- The app consumes the committed `AppIcon.appiconset` (iOS 18 single-size with dark and tinted
  appearances). `scripts/check-app-icon.sh` verifies the compiled `Assets.car` has all three.

## Alternatives considered

- **Autotrace or potrace to SVG**: produces curve soup with arbitrary node counts, no notion of
  carved corners versus smooth edges, and no way to apply a uniform weight; hard to review and to
  hold to a numeric fidelity gate.
- **Icon Composer `.icon` bundle**: the right format for iOS 26 Liquid Glass layering, but it is an
  Xcode-only binary-ish authoring flow with no headless generation or CI check. Planned later as an
  addition, fed from the same layer SVGs (see `docs/development/icon.md`).
- **Node or Python tooling** (sharp, cairosvg, Pillow): adds a second language runtime and
  system libraries (cairo) with version-dependent anti-aliasing. The repo already requires Rust, and
  resvg is pure Rust and deterministic.
- **Hand-exported PNGs from a design tool**: no source of truth for variants, and a theme change
  means a manual re-export.
- **Not committing generated outputs**: would make every app build require the tool and Rust, and
  the PR diff would not show the visual change. Committed outputs plus `check` keep both honest.

## Consequences

- Changing a colour, texture or weight is a TOML edit plus `generate`; the diff shows the images.
- Outputs must be regenerated and committed with any change to configs or tool code (CI fails
  otherwise).
- On iOS 26 and later the system applies its own glass treatment to icons that are not `.icon`
  bundles; the flat matte look is therefore not guaranteed pixel-identical there.
- The glyph geometry is a curated artefact; re-tracing is an explicit, reviewed step.
