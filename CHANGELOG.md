## 0.1.0

- Initial release.
- `BookFlip` widget with drag-to-turn 3D page flip over a single packed texture.
- `BookFlip.builder` and `BookFlip.widgets`: build pages from ANY widgets (text,
  images, whole layouts), captured and disposed for you — no `ui.Image`
  lifecycle to manage.
- `pageLabel`: stamp a custom page number (or any widget) onto every page, baked
  into the page at no per-frame cost.
- `BookFlipCurl`: direct control of the page-curve trajectory — `bend`,
  `foldTilt` and `droop` — independent of the paper, with `copyWith` and `lerp`.
- `BookFlipEffects`: turn each visual layer (gloss, grain, cast shadow, spine
  shadow, edge line, translucency) on or off individually.
- `BookFit` and `pageAspectRatio`: fits any layout (fixed, flex, scrollable) and
  keeps the pages' true shape — no distortion, never throws under any constraints.
- `maxTextureDimension` and `meshResolution` for device tuning. The atlas adapts
  to the GPU's real texture limit (retrying smaller if rejected), and mesh
  smoothness can be raised for large or high-density screens.
- `BookFlipController` for programmatic turns by spread (`nextSpread`,
  `previousSpread`, `goToSpread`) or by page (`goToPage`), and for observing
  `currentSpread`, `currentPage`, `totalSpreads`, `totalPages`, `flipProgress`
  and `isAnimating`.
- `BookFlipPhysics` for tuning the spring and commit behavior.
- `BookFlipMaterial` for the paper's feel — stiffness, weight, gloss,
  translucency and edge thickness — with two ready-made papers (`paper`, the
  matte default, and glossy `magazine`), plus `lerp` and `copyWith`.
- `onSpreadChanged` / `onFlipStart` / `onFlipEnd` callbacks.
