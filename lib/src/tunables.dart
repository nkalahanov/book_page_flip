part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Tunables (all in one place; safe to nudge on real hardware).
// ─────────────────────────────────────────────────────────────────────────────
const int kNu = 42; // mesh columns across the leaf width (u). kNu*kNv < 65536
const int kNv = 30; // mesh rows down the leaf height (v).
const int kPageTexMax =
    4096; // initial atlas-dimension target (broad GPU support).
const int kPageTexMin =
    256; // floor for the adaptive retry — below this, give up.
// Fallback cell size, used only until the first page image is measured. The REAL
// atlas cell is derived from the page images at boot (see _BookFlipState._boot),
// so no page shape is ever hardcoded.
const int kPageTexW = 512;
const int kPageTexH = 720;

// Atlas grid: column count for `pageCount` cells (near-square, rows derived).
// Page count is dynamic (= the caller's page list length), so the old fixed
// kNumPages/kAtlasCols/kAtlasRows constants are gone; the layout is computed.
int _atlasColsFor(int pageCount) =>
    pageCount <= 1 ? 1 : math.sqrt(pageCount).ceil();
int _atlasRowsFor(int pageCount) =>
    (pageCount / _atlasColsFor(pageCount)).ceil();

// Pixel rect of page [p] in an atlas of [cols] columns of [cellW]×[cellH] cells.
Rect _cellRect(int p, int cols, int cellW, int cellH) => Rect.fromLTWH(
      (p % cols) * cellW.toDouble(),
      (p ~/ cols) * cellH.toDouble(),
      cellW.toDouble(),
      cellH.toDouble(),
    );

/// Atlas cell size (px) for [imgW]×[imgH] pages packed into a [cols]×[rows] grid,
/// scaled down uniformly so the packed atlas fits [maxDim] in both axes. Preserves
/// the page aspect ratio (no distortion) and never returns a zero dimension; a
/// non-positive image size falls back to the default cell shape.
(int, int) bookFlipAtlasCell(
    int imgW, int imgH, int cols, int rows, int maxDim) {
  final w = imgW > 0 ? imgW : kPageTexW;
  final h = imgH > 0 ? imgH : kPageTexH;
  final fit = math.min(1.0, math.min(maxDim / (cols * w), maxDim / (rows * h)));
  return (math.max(1, (w * fit).floor()), math.max(1, (h * fit).floor()));
}

const double kFovY = 0.62; // FULL vertical FOV (radians) — vm64 halves it.
const double kNear = 1.0;
const double kFarPad = 4.0; // far = camDist + H*kFarPad.

const double kAmax = 1.32; // peak developable bend angle at mid-flip (radians).
const double kTiltMax =
    0.30; // peak per-row fold tilt (radians) for corner folds.
const double kEpsA = 1e-4; // bend->flat limit guard (avoids div-by-zero).
const double kWEps = 1e-6; // perspective-w firewall threshold.

const double kAmbient =
    0.30; // diffuse floor; crest reads as a soft fold-shadow,
//                               while flat (|N·ẑ|=1) renders at full 1.0 == base.
const double kSheen = 0.18; // additive specular cap (<=0.25).
const double kShininess = 26.0;

// ── PAPER TEXTURE (grain) ──────────────────────────────────────────────────
// A per-vertex page-space relief (bookFlipGrainAt), GATED BY CURVATURE so it is
// exactly 0 on a flat page → the leaf at rest/landing stays pixel-identical to the
// base (pop-free by construction), and the grain only emerges as the page bends
// into the light during a flip — which is physically how paper tooth reveals
// itself: micro-facets catch raking light on the slopes. Amplitudes scale per
// material by bookFlipTooth (matte = rough, coated = smooth).
const double kTooth = 0.55; // DEFAULT paper tooth (grain amount), 0..1.
const double kGrainDiffuse =
    0.34; // diffuse mottle depth: lum *= 1 + this·tooth·curl·g.
const double kGrainSpecular =
    0.85; // highlight sparkle: breaks the matte glint on tooth.

// ── COATED WHITE GLOSS (optional; magazine-tier only) ──────────────────────
// A clearcoat highlight that appears ONLY on high-gloss stock (gloss past
// kCoatKnee — e.g. magazine). Every matte/semigloss paper, and the default
// material, leave it at 0, so it is opt-in through the gloss dial and changes
// nothing elsewhere. It is a white, additive, curl-gated (→ 0 when flat) highlight.
//
// CRITICAL — it must stay COMPACT. An earlier broad lobe + grazing Fresnel rim lit
// most of the curled page white, cancelling the curvature form-shading: the page
// read as flat/see-through, and the additive back-face glint bled THROUGH the front
// at mid-flip folds. The fix is a tight glint + a narrow halo only (no broad lobe,
// no Fresnel), so the highlight is a small bright streak and the 3D form survives —
// and the sheen is composited as ONE unit (see _emitLeaf) so it cannot bleed through.
const double kCoatKnee =
    0.62; // gloss below this → NO coat (matte/semigloss stay matte).
const double kCoatShininess =
    40.0; // sharp clearcoat glint exponent (compact accent).
const double kCoatHaloShininess =
    16.0; // the "wet" sheen lobe — DOMINANT weight, because
//   exp≈16 is ~4 columns wide on the coarse render mesh, so it is well-sampled and stable
//   (the razor core alone would shimmer between vertices as the glint sweeps).
const double kCoatCurlKnee =
    0.08; // curl at which the glint gate reaches full. The glint
//   lives where the page faces the light (LOW curvature), so a plain ·curl gate would
//   crush it; the coat gates on smoothstep(curl/this) instead — 0 at EXACTLY flat
//   (pop-free, C1) but full a little off-flat, so the gloss actually shows. Still tight
//   enough (both lobes) that the strongly-curved form hump stays unwashed → 3D survives.
const double kCoatCoreWeight = 0.36; // weight of the sharp glint accent.
const double kCoatHaloWeight = 0.40; // weight of the (dominant) soft wet sheen.
const double kCoatPeak =
    0.50; // extra additive-spec ceiling a full coat adds atop sheen.

const double kShadowMax =
    0.46; // cast (drop) shadow PEAK umbra density. Held flat
//   through the flight; only EASED to 0 over the last fraction of the descent (see
//   kCastFade) so the drop shadow DISSOLVES at contact instead of popping off.
const double kCastFade =
    0.15; // leaf height (hEnv) below which the cast umbra eases
//   to 0 (smoothstep): the landing shadow dissolves C1 — no opacity/velocity step,
//   no hard cutoff. hEnv is itself sin²-enveloped, so the fade is C1 in time too.
const double kBindingAO =
    0.20; // constant binding ambient-occlusion at the spine,
//   present at ALL times (rest & flip) → the center shadow never ramps in late.
const double kBindingSigma =
    0.024; // Gaussian half-spread of the binding AO (÷W).
const double kBindingCore =
    0.02; // solid-core half-width of the binding AO (÷W),
//   blurred by kBindingSigma into the soft spine valley. core < sigma keeps the
//   profile a smooth bump (no flat plateau → no hard shoulder at the core edge).
const double kShadowZRef =
    0.365; // leaf height (÷W) mapped to the cast penumbra blur.

const double kSpringStiffness = 220.0; // critically-damped settle.
const double kCommitEps = 0.0008; // |t-target| below which a flip commits.
const double kDepthEps =
    1e-3; // world-z span below which the leaf is coplanar →
//                                triangles can't occlude → depth sort is skipped.

// Scene light direction, normalized ONCE (math.sqrt is not a const expression).
// Shared by the per-vertex sheen (computeShading) and the cast shadow so they can
// never drift apart. The raw direction (-0.16, -0.6, 0.72) leans down-and-toward.
final ({double x, double y, double z}) _kLight = (() {
  const lxr = -0.16, lyr = -0.6, lzr = 0.72;
  final ll = math.sqrt(lxr * lxr + lyr * lyr + lzr * lzr);
  return (x: lxr / ll, y: lyr / ll, z: lzr / ll);
})();
final double _kInvLightZ = _kLight.z.abs() > 1e-6 ? 1.0 / _kLight.z : 0.0;

// Identity shader transform for the atlas ImageShader — allocated once instead of
// rebuilding a Matrix4 every paint (texcoords are already in absolute atlas px).
final Float64List _kIdentityStorage = vm.Matrix4.identity().storage;

// ─────────────────────────────────────────────────────────────────────────────
//  BINDING-SHADOW SHARPNESS MODEL (pure; always compiled — used by tests too).
//
//  The MIDDLE shadow — the binding ambient-occlusion painted BETWEEN the two pages
//  at the spine — is a solid core of half-width a = w·kBindingCore, fill α=kBindingAO,
//  blurred by a MaskFilter Gaussian σ = w·kBindingSigma. Its alpha profile across x
//  (measured from the spine) is that box convolved with the Gaussian:
//
//      α(x) = kBindingAO · ½ · [ erf((x+a)/(σ√2)) − erf((x−a)/(σ√2)) ]
//
//  This is C∞ — analytically it CANNOT be sharp. Two scale facts fall straight out
//  of a,σ ∝ w: the peak darkness α(0)=kBindingAO·erf(a/(σ√2)) is SCALE-INVARIANT
//  (the a/σ ratio is fixed at every width), while the steepest slope maxGrad ∝ 1/w.
//  So the ONLY way the spine can read as a hard line is a tiny render width driving
//  σ sub-pixel: the soft ramp then collapses below the sampling grid and the core's
//  box edges survive. This model quantifies exactly that, in device-logical px.
// ─────────────────────────────────────────────────────────────────────────────

// Gauss error function (Abramowitz & Stegun 7.1.26, |err| < 1.5e-7). dart:math has
// no erf, and the binding-AO profile is literally a difference of two erfs.
double _erf(double x) {
  final sign = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  final t = 1.0 / (1.0 + 0.3275911 * ax);
  final poly =
      ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) *
                  t +
              0.254829592) *
          t;
  return sign * (1.0 - poly * math.exp(-ax * ax));
}

/// Sharpness of the binding (spine) ambient-occlusion when the spread is rendered
/// [logicalW] logical px wide, under the [core]/[sigma]/[alpha] tuning (defaults =
/// the live binding-AO constants). Reconstructs the EXACT analytic alpha profile —
/// a solid core convolved with the MaskFilter Gaussian — and measures it:
///
///  * `peakAlpha`  darkest alpha, at the spine (SCALE-INVARIANT under the defaults);
///  * `maxGrad`    steepest per-pixel alpha step (α/px) — the eye reads a step
///                 >~0.02/px as a line (Weber ~1–2% on a light page);
///  * `sigmaPx`    the MaskFilter Gaussian σ in px (= logicalW·sigma);
///  * `fwhmPx`     full width at half-max — the visible band thickness;
///  * `rise1090Px` 10→90% edge ramp width — "how many px the shadow edge takes";
///  * `verdict`    0 = soft, 1 = sharp-risk, 2 = sharp.
///
/// Pure → a unit test guards it, so a retune
/// that hardens the spine fails CI instead of shipping a sharp seam.
({
  double peakAlpha,
  double maxGrad,
  double sigmaPx,
  double fwhmPx,
  double rise1090Px,
  int verdict,
}) bookFlipBindingSharpness(
  double logicalW, {
  double core = kBindingCore,
  double sigma = kBindingSigma,
  double alpha = kBindingAO,
}) {
  final s = logicalW * sigma;
  final a = logicalW * core;
  if (!logicalW.isFinite || !(s > 0) || !(a >= 0)) {
    // Degenerate: no Gaussian to soften the core → as hard as it gets.
    return (
      peakAlpha: alpha,
      maxGrad: double.infinity,
      sigmaPx: 0,
      fwhmPx: 0,
      rise1090Px: 0,
      verdict: 2,
    );
  }
  const root2 = math.sqrt2;
  double alphaAt(double x) =>
      alpha * 0.5 * (_erf((x + a) / (s * root2)) - _erf((x - a) / (s * root2)));

  // Sample the real profile from the spine out through the soft tail; extract the
  // peak, steepest step, and the 10/50/90% crossings EXACTLY (no closed form).
  final peak = alphaAt(0);
  final span = a + 5.0 * s;
  const samples = 512;
  final dx = span / (samples - 1);
  var maxGrad = 0.0;
  var prev = peak;
  double? x90, x50, x10;
  for (var i = 1; i < samples; i++) {
    final x = i * dx;
    final cur = alphaAt(x);
    final g = (prev - cur) / dx; // α decreases with x on this flank
    if (g > maxGrad) maxGrad = g;
    if (x90 == null && cur <= 0.9 * peak) x90 = x;
    if (x50 == null && cur <= 0.5 * peak) x50 = x;
    if (x10 == null && cur <= 0.1 * peak) x10 = x;
    prev = cur;
  }
  final fwhm = x50 != null ? 2.0 * x50 : span * 2.0;
  final rise = (x90 != null && x10 != null) ? x10 - x90 : span;
  // σ < 1px: the Gaussian is sub-pixel — it cannot soften the core. maxGrad > 0.02:
  // a per-pixel step the eye reads as a line. Either → SHARP; the softer band → RISK.
  final verdict = (s < 1.0 || maxGrad > 0.02)
      ? 2
      : (s < 1.6 || maxGrad > 0.012)
          ? 1
          : 0;
  return (
    peakAlpha: peak,
    maxGrad: maxGrad,
    sigmaPx: s,
    fwhmPx: fwhm,
    rise1090Px: rise,
    verdict: verdict,
  );
}
