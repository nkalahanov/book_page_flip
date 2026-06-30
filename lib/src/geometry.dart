part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Interpolation primitives (clamped, C1).
// ─────────────────────────────────────────────────────────────────────────────

/// GLSL-compliant clamped smoothstep. s(0)=0, s(1)=1, s'(0)=s'(1)=0 → C1 at the
/// rest points, which is what makes the page ease into/out of rest with zero
/// velocity (no sharp jump on hand-off or commit).
double bookSmoothstep01(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// C1 "hump": value AND derivative are 0 at t=0 and t=1, peak 1 at t=0.5.
/// = sin²(πt) = (1-cos(2πt))/2.  d/dt = π·sin(2πt) → 0 at both ends.
/// (We deliberately do NOT use sin(πt): its slope is ±π at the ends → a velocity
/// pop and a moving fold crease.)
double bookBumpC1(double t) {
  final s = math.sin(math.pi * t.clamp(0.0, 1.0));
  return s * s;
}

/// Cast-shadow opacity envelope vs leaf height [hEnv]: 0 at contact (hEnv=0), ramping
/// C1 (smoothstep) to full once the leaf has lifted past [kCastFade]. The drop shadow
/// scales its umbra by this, so it DISSOLVES smoothly at landing instead of popping off
/// a hard cutoff. s(0)=0 with s'(0)=0 → the dissolve starts with zero slope (no opacity
/// step); and because hEnv is sin²-enveloped (zero slope at t=0/1), the fade is C1 in
/// time too. Pure → reused by the painter AND a unit test locks the no-pop contract.
double bookFlipCastFade(double hEnv) => bookSmoothstep01(hEnv / kCastFade);

/// Paper grain relief at page coordinate (u,v) ∈ [0,1]², returned in [-1,1].
///
/// Summed incommensurate cosine lobes — a small band-limited spectral noise that is
/// C∞ (so its vertex samples interpolate to a smooth, alias-free field), purely
/// DETERMINISTIC (no RNG → reproducible, test-lockable), and ~zero-mean (it textures
/// the page without biasing its brightness). The low octaves read as handmade-paper
/// cloud; the v-aligned term is the machine/laid grain direction; the fine term is
/// the tooth. Frequencies are kept ≤ ~5 cycles so the default kNu×kNv mesh resolves
/// them. The painter precomputes one field per mesh (it is locked to the page and
/// never moves); `computeShading` then gates it by curvature so it is invisible at
/// rest and only emerges as the page bends — see [BookFlipMesh.computeShading].
double bookFlipGrainAt(double u, double v) {
  const tau = 2.0 * math.pi;
  var g = 0.0;
  // Cloud (low frequency): the broad unevenness of a real sheet.
  g += 0.55 *
      math.sin(tau * (1.30 * u + 0.13)) *
      math.cos(tau * (1.10 * v + 0.27));
  g += 0.34 *
      math.sin(tau * (2.30 * u + 0.61)) *
      math.cos(tau * (1.90 * v + 0.05));
  g += 0.21 *
      math.sin(tau * (3.70 * u + 0.20)) *
      math.cos(tau * (3.10 * v + 0.74));
  // Fiber (anisotropic): parallel laid lines down the page (v), gently waved by u.
  g += 0.30 * math.sin(tau * (4.30 * v + 0.40) + 0.6 * math.sin(tau * 0.7 * u));
  // Tooth (fine): the per-cell texture the highlight sparkles on.
  g += 0.16 *
      math.sin(tau * (4.90 * u + 0.33)) *
      math.cos(tau * (5.30 * v + 0.51));
  // Σ|amplitudes| = 1.56 → normalize into ~[-1,1]; clamp tames the rare stack-up.
  return (g / 1.56).clamp(-1.0, 1.0);
}

// ─────────────────────────────────────────────────────────────────────────────
//  GEOMETRY CORE — pure, allocation-free, test-addressable.
//
//  Holds reusable Float64 buffers (state in Float64 end-to-end) and the
//  per-frame compute. The CustomPainter AND the test suite both drive this
//  exact code path → no "tested math diverges from rendered math" gap.
// ─────────────────────────────────────────────────────────────────────────────
class BookFlipMesh {
  BookFlipMesh({this.nu = kNu, this.nv = kNv})
      : assert(nu * nv <= 65536, 'nu*nv must fit a Uint16 index (<= 65536)'),
        n = nu * nv,
        wx = Float64List(nu * nv),
        wy = Float64List(nu * nv),
        wz = Float64List(nu * nv),
        nrx = Float64List(nu * nv),
        nry = Float64List(nu * nv),
        nrz = Float64List(nu * nv),
        sx = Float64List(nu * nv),
        sy = Float64List(nu * nv),
        lum = Float64List(nu * nv),
        spec = Float64List(nu * nv) {
    // Static triangle index triples (CCW at rest), 2 tris per grid cell. Filled
    // straight into a right-sized Uint16List — no growing list, no per-cell temp
    // arrays. (kNu*kNv < 65536, so the indices fit Uint16; the list also feeds the
    // `indices` arg of ui.Vertices.raw in the cast-shadow pass.)
    triIdx = Uint16List((nu - 1) * (nv - 1) * 6);
    var ti = 0;
    for (var j = 0; j < nv - 1; j++) {
      for (var i = 0; i < nu - 1; i++) {
        final v00 = j * nu + i;
        final v10 = j * nu + (i + 1);
        final v01 = (j + 1) * nu + i;
        final v11 = (j + 1) * nu + (i + 1);
        triIdx[ti++] = v00;
        triIdx[ti++] = v10;
        triIdx[ti++] = v11;
        triIdx[ti++] = v00;
        triIdx[ti++] = v11;
        triIdx[ti++] = v01;
      }
    }
    triCount = triIdx.length ~/ 3;
    _meanZ = Float64List(triCount);
    _order = Int32List(triCount);
    for (var i = 0; i < triCount; i++) {
      _order[i] = i;
    }
    // GPU-handoff soup buffers, sized once (triangle soup = 3 verts/triangle).
    // Non-nullable late-final → zero `?`/`!` on the hot path (fully type-safe).
    final soupV = triCount * 3;
    posSoup = Float32List(soupV * 2); // Float32 ONLY at the GPU boundary
    texSoup = Float32List(soupV * 2);
    colMain = Int32List(soupV);
    colSheen = Int32List(soupV);
    shadowPos = Float32List(n * 2); // indexed cast-shadow footprint (screen px)
    // Normalized grid coordinates per vertex, precomputed once. The emit loop ran
    // `vIdx % nu` and `vIdx ~/ nu` plus two divides for every one of ~7k vertices
    // every frame; this lifts that out of the hot path entirely.
    uNorm = Float64List(n);
    vNorm = Float64List(n);
    grain = Float64List(n);
    final invU = nu == 1 ? 0.0 : 1.0 / (nu - 1);
    final invV = nv == 1 ? 0.0 : 1.0 / (nv - 1);
    for (var j = 0; j < nv; j++) {
      for (var i = 0; i < nu; i++) {
        final idx = j * nu + i;
        final un = i * invU, vn = j * invV;
        uNorm[idx] = un;
        vNorm[idx] = vn;
        // Paper relief is locked to page space → computed ONCE here, not per frame.
        grain[idx] = bookFlipGrainAt(un, vn);
      }
    }
  }

  final int nu, nv, n;
  // World positions (Float64), normals, screen positions, per-vertex shading.
  final Float64List wx, wy, wz, nrx, nry, nrz, sx, sy, lum, spec;
  late final Uint16List triIdx;
  late final int triCount;
  late final Float64List _meanZ;
  late final Int32List _order;
  // Per-vertex normalized grid coords (u,v ∈ [0,1]); precomputed, never change.
  late final Float64List uNorm, vNorm;
  // Per-vertex paper-grain relief ∈ [-1,1], locked to page space; precomputed once
  // (it never moves with the flip). computeShading gates it by curvature. [texture]
  late final Float64List grain;
  // Reusable GPU-handoff soup (filled per frame by the painter; persistent).
  late final Float32List posSoup, texSoup, shadowPos;
  late final Int32List colMain, colSheen;
  // Cached MVP — a pure function of (w, h, fovY); the camera does not move during
  // a flip, so it is rebuilt only on a resize, not every frame.
  vm.Matrix4? _mvp;
  double _mvpW = -1, _mvpH = -1, _mvpFov = double.nan;

  /// Peak |z| of the leaf this frame (height above the base plane). 0 when flat.
  /// Drives the cast-shadow opacity/softness so the shadow resolves smoothly to
  /// nothing exactly at the flat landing (C1, since A(t) uses sin²).
  double maxAbsZ() {
    var m = 0.0;
    for (var i = 0; i < n; i++) {
      final a = wz[i].abs();
      if (a > m) m = a;
    }
    return m;
  }

  int lastBadCount = 0; // firewall telemetry (vertices that fell back).

  /// Camera distance that makes the z=0 world plane project pixel-exact onto
  /// the screen rect [0,W]×[0,H].  camDist = H / (2·tan(fovY/2)).
  static double camDistFor(double h, double fovY) =>
      h / (2.0 * math.tan(fovY * 0.5));

  // Scratch (hoisted; no per-frame alloc). column-major handled by vm64.
  final vm.Vector4 _v4 = vm.Vector4.zero();

  /// World position of one leaf vertex. PURE — no Flutter, no canvas.
  ///   dir = +1 : right leaf turning forward (spine at center, free edge at x=W)
  ///   dir = -1 : left  leaf turning backward (spine at center, free edge at x=0)
  /// grabV ∈ [0,1] is the vertical grab point (NaN-sanitized by caller).
  void _world(
    int i,
    int j,
    double w,
    double h,
    double t,
    double grabV,
    int dir,
    double amax,
    double tiltMax,
    double sagAmp,
  ) {
    final u = nu == 1 ? 0.0 : i / (nu - 1);
    final v = nv == 1 ? 0.0 : j / (nv - 1);

    final bump = bookBumpC1(t);
    final phiBase = math.pi * bookSmoothstep01(t);
    final tilt = tiltMax * bump;
    final a = amax * bump;
    final sgv = grabV.isFinite ? grabV.clamp(0.0, 1.0) : 0.5;

    final leafW = w * 0.5;
    final spineX = w * 0.5;

    // Per-row effective spine-rotation angle → corner-aware diagonal fold.
    // With bump=sin²(πt) and tiltMax<=0.30 the clamp never actually fires for any
    // grabV∈[0,1]; it remains purely as a paranoid safety rail.
    var phi = phiBase + tilt * (v - sgv);
    if (phi < 0.0) phi = 0.0;
    if (phi > math.pi) phi = math.pi;

    // Developable bend (texture-perfect; arc length = u·leafW is preserved).
    double bx, bz;
    if (a < kEpsA) {
      bx = u * leafW; // exact-flat limit (no NaN as a→0).
      bz = 0.0;
    } else {
      final r = leafW / a;
      bx = r * math.sin(a * u);
      bz = r * (1.0 - math.cos(a * u));
    }

    // Rotate (bx,bz) about the vertical spine axis by phi.
    final c = math.cos(phi), s = math.sin(phi);
    final xr = bx * c - bz * s;
    final zr = bx * s + bz * c;

    final idx = j * nu + i;
    wx[idx] = spineX + dir * xr;
    // Free-corner droop (material weight): 0 at the hinge (u=0) and at the held
    // row (v=grabV), and gated by bump so it is 0 — value AND slope — at the flat
    // rest states. So sag never moves the spine and never causes a landing pop.
    final sag = sagAmp * bump * u * (v - sgv).abs() * h;
    wy[idx] = v * h + sag;
    wz[idx] = zr; // +z toward the viewer.
  }

  /// Fill all world positions for a frame, shaped by [material].
  void computeWorld(
    double w,
    double h,
    double t,
    double grabV,
    int dir, {
    BookFlipMaterial material = BookFlipMaterial.paper,
    BookFlipCurl? curl,
  }) {
    final tc = t.isFinite ? t.clamp(0.0, 1.0) : 0.0; // temporal clamp
    // A non-null curl OVERRIDES the material-derived geometry with its own dials;
    // null → the proven material path, byte-for-byte unchanged. Each curl dial maps
    // into the same CLAMPED envelope ([_kAmaxMin.._kAmaxHi], [_kTiltMin.._kTiltHi],
    // [0.._kSagPeak]) the engine is proven over; the phi guard in _world is verified
    // never to fire up to tiltMax=_kTiltHi=0.42, so the pop-free / NaN guarantees hold.
    final amax = curl != null ? bookFlipCurlAmax(curl) : bookFlipAmax(material);
    final tiltMax =
        curl != null ? bookFlipCurlTilt(curl) : bookFlipTilt(material);
    final sagAmp =
        curl != null ? bookFlipCurlSag(curl) : bookFlipSagAmp(material);
    for (var j = 0; j < nv; j++) {
      for (var i = 0; i < nu; i++) {
        _world(i, j, w, h, tc, grabV, dir, amax, tiltMax, sagAmp);
      }
    }
  }

  /// Area-weighted-ish vertex normals via central differences over the grid.
  /// Two-sided lighting uses |N·L| downstream so the SIGN here is irrelevant —
  /// that is what keeps shading continuous across the silhouette (no seam).
  void computeNormals() {
    for (var j = 0; j < nv; j++) {
      for (var i = 0; i < nu; i++) {
        final i0 = i > 0 ? i - 1 : i;
        final i1 = i < nu - 1 ? i + 1 : i;
        final j0 = j > 0 ? j - 1 : j;
        final j1 = j < nv - 1 ? j + 1 : j;
        final a = j * nu + i0, b = j * nu + i1;
        final c = j0 * nu + i, d = j1 * nu + i;
        final tux = wx[b] - wx[a], tuy = wy[b] - wy[a], tuz = wz[b] - wz[a];
        final tvx = wx[d] - wx[c], tvy = wy[d] - wy[c], tvz = wz[d] - wz[c];
        final nxv = tuy * tvz - tuz * tvy;
        final nyv = tuz * tvx - tux * tvz;
        final nzv = tux * tvy - tuy * tvx;
        final len = math.sqrt(nxv * nxv + nyv * nyv + nzv * nzv);
        final idx = j * nu + i;
        if (len > 1e-9) {
          // guard zero-length normalize
          nrx[idx] = nxv / len;
          nry[idx] = nyv / len;
          nrz[idx] = nzv / len;
        } else {
          nrx[idx] = 0.0;
          nry[idx] = 0.0;
          nrz[idx] = 1.0; // fallback faces the camera.
        }
      }
    }
  }

  /// Build the MVP with genuine vector_math_64 and project every vertex with the
  /// perspective w (NOT transform3 — that drops the w-row). Firewall every output
  ///: non-finite or w<=eps → fall back to the FLAT rest projection so a single
  /// poisoned vertex can never blank or tear the frame.
  void project(double w, double h, double fovY) {
    if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) {
      for (var i = 0; i < n; i++) {
        sx[i] = 0.0;
        sy[i] = 0.0;
      }
      lastBadCount = n;
      return; // degenerate viewport: never build a det=0 view
    }
    final camDist = camDistFor(h, fovY);
    var mvp = _mvp;
    if (mvp == null || w != _mvpW || h != _mvpH || fovY != _mvpFov) {
      mvp = bookFlipMvp(w, h, fovY); // same math as the public test surface
      _mvp = mvp;
      _mvpW = w;
      _mvpH = h;
      _mvpFov = fovY;
    }

    var bad = 0;
    for (var idx = 0; idx < n; idx++) {
      _v4
        ..x = wx[idx]
        ..y = wy[idx]
        ..z = wz[idx]
        ..w = 1.0;
      mvp.transform(_v4); // full 4×4 incl. w-row (perspective). mutates _v4.
      final cw = _v4.w;
      if (!cw.isFinite || cw <= kWEps || !_v4.x.isFinite || !_v4.y.isFinite) {
        _restProject(idx, w, h, camDist, fovY); // per-vertex fallback
        bad++;
        continue;
      }
      final ndcX = _v4.x / cw;
      final ndcY = _v4.y / cw;
      if (!ndcX.isFinite || !ndcY.isFinite) {
        _restProject(idx, w, h, camDist, fovY);
        bad++;
        continue;
      }
      // up=(0,-1,0) makes the view x-axis (-1,0,0): world +X → -ndc.x, so X needs
      // the (1-...) flip to land on the correct half. Y also flips.
      sx[idx] = (1.0 - (ndcX * 0.5 + 0.5)) * w;
      sy[idx] = (1.0 - (ndcY * 0.5 + 0.5)) * h;
    }
    lastBadCount = bad;
  }

  void _restProject(int idx, double w, double h, double camDist, double fovY) {
    // Project the vertex's FLAT (z=0) rest position with the same calibration.
    final t2 = math.tan(fovY * 0.5);
    final aspect = w / h;
    final wp = camDist; // z=0 → w = camDist
    final ndcX = (w * 0.5 - wx[idx]) / (aspect * t2 * wp);
    final ndcY = (h * 0.5 - wy[idx]) / (t2 * wp);
    sx[idx] = (1.0 - (ndcX * 0.5 + 0.5)) * w;
    sy[idx] = (1.0 - (ndcY * 0.5 + 0.5)) * h;
  }

  /// Per-vertex diffuse + specular, including the curvature-gated paper grain and
  /// the optional coated white gloss.
  ///
  /// CAMERA-PLANE FORM LIGHT: diffuse = ambient + (1-ambient)·|N·ẑ| where ẑ is the
  /// screen normal (0,0,1). A FLAT page (N ∥ ẑ) is therefore EXACTLY 1.0 — pixel-
  /// identical to the unlit base layer — so the leaf appearing at a flat angle
  /// (long-press) or landing flat (commit) produces NO brightness jump. Only the
  /// surface CURVING (its normal tilting off the screen plane) darkens it, so the
  /// shading is a pure function of the page's SHAPE and cannot change while the
  /// page is held still. The directional light drives ONLY the sheen, which is
  /// gated by curvature so it is 0 when flat (the base has no glint either).
  ///
  /// PAPER GRAIN and COATED GLOSS hang off the SAME `curl = 1-|N·ẑ|` gate, so they
  /// too are exactly 0 at the flat rest/landing states — the leaf stays pixel-
  /// identical to the base there (pop-free), and the texture/gloss only appear as
  /// the page bends, which is how real tooth and clear-coat reveal themselves under
  /// raking light. Grain is a mean-zero mottle (depth ∝ tooth) that deepens with
  /// curvature; it also sparkle-breaks the matte glint. The coat — a compact,
  /// white, additive highlight (a tight glint plus a narrow curl-gated halo, no
  /// broad lobe, no Fresnel rim) — is non-zero only for high-gloss stock
  /// (bookFlipCoat), so it is opt-in and reserved for magazine-tier paper.
  void computeShading(
    double w,
    double h,
    double fovY, {
    BookFlipMaterial material = BookFlipMaterial.paper,
    BookFlipEffects effects = BookFlipEffects.all,
  }) {
    final camDist = camDistFor(h, fovY);
    final lxn = _kLight.x,
        lyn = _kLight.y,
        lzn = _kLight.z; // shared scene light
    // Each effect flag zeroes ONLY its own contribution; default (all on) leaves
    // every term exactly as before, so the calibrated look is byte-for-byte
    // unchanged (the material / grain / coat invariant tests lock this).
    final sheen = effects.gloss ? bookFlipSheen(material) : 0.0;
    final shininess = bookFlipShininess(material);
    final trans = effects.translucency ? bookFlipTranslucency(material) : 0.0;
    // Texture + coat — all curvature-gated below, so all 0 on a flat page.
    final tooth = effects.grain ? bookFlipTooth(material) : 0.0;
    final coat = effects.gloss ? bookFlipCoat(material) : 0.0;
    final lumGrain = kGrainDiffuse * tooth; // diffuse mottle depth
    final specGrain = kGrainSpecular * tooth; // highlight sparkle depth
    final specMax = sheen + kCoatPeak * coat; // == bookFlipSpecMax(material)
    for (var idx = 0; idx < n; idx++) {
      final nx = nrx[idx], ny = nry[idx], nz = nrz[idx];
      // |N·ẑ|: 1 when the surface faces the screen (flat), 0 at the crest.
      final facing = nz.abs() > 1.0 ? 1.0 : nz.abs();
      final curl = 1.0 - facing;
      final g = grain[idx]; // static page-space relief ∈ [-1,1]
      var baseLum = kAmbient + (1.0 - kAmbient) * facing;
      // Thin-paper translucency: light through the page lifts the curled (darkest)
      // parts toward white. 0 when flat (curl=0) and for opaque stock (trans=0).
      baseLum += trans * curl * (1.0 - baseLum);
      // Paper tooth: a mean-zero mottle that DEEPENS with curvature — micro-facets
      // catch raking light only where the page slopes (curl=0 → no rest change).
      // Floored at kAmbient so tooth-shadows never crush past the ambient guarantee.
      lum[idx] = (baseLum * (1.0 + lumGrain * curl * g)).clamp(kAmbient, 1.0);
      // Sheen: half-vector specular, GATED by curvature (1-facing) so it vanishes
      // at the flat state (→ matches the glint-free base, no pop) and appears on
      // the rising crest. View dir per vertex; abs() keeps it two-sided/continuous.
      var vx = w * 0.5 - wx[idx];
      var vy = h * 0.5 - wy[idx];
      var vz = camDist - wz[idx];
      final vl = math.sqrt(vx * vx + vy * vy + vz * vz);
      if (vl > 1e-9) {
        vx /= vl;
        vy /= vl;
        vz /= vl;
      }
      var hx = lxn + vx, hy = lyn + vy, hz = lzn + vz;
      final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
      if (hl > 1e-9) {
        hx /= hl;
        hy /= hl;
        hz /= hl;
      }
      final ndh = (nx * hx + ny * hy + nz * hz).abs();
      // Matte tight lobe, with the tooth breaking the glint into sparkle on rough
      // stock (sparkle≈1 for smooth/coated paper). Curl-gated → 0 when flat.
      final sparkle = (1.0 + specGrain * g).clamp(0.0, 2.0);
      var s = math.pow(ndh, shininess).toDouble() * sheen * curl * sparkle;
      // Coated white gloss (magazine-tier only): a COMPACT clearcoat highlight — a
      // tight glint + a narrow halo, white & additive, curl-gated. NO broad lobe and
      // NO grazing Fresnel rim: those lit most of the curled page white, cancelling
      // the curvature form-shading (the page read as flat / see-through). Tight
      // exponents keep it a small bright streak, so the 3D form survives everywhere
      // but the glint. 0 for matte stock (coat=0) and 0 when flat → optional, pop-free.
      if (coat > 0.0) {
        // The glint lives where the page faces the light/camera — i.e. at LOW
        // curvature — so a plain ·curl gate would crush it exactly where it appears.
        // Gate on smoothstep(curl/knee): 0 at flat (pop-free, C1) but full a little
        // off-flat, so the bright glint shows. Tight exponents keep it COMPACT.
        final gate = bookSmoothstep01(curl / kCoatCurlKnee);
        final core = math.pow(ndh, kCoatShininess).toDouble();
        final halo = math.pow(ndh, kCoatHaloShininess).toDouble();
        s += coat * gate * (kCoatCoreWeight * core + kCoatHaloWeight * halo);
      }
      spec[idx] = s.clamp(0.0, specMax);
    }
  }

  /// Signed screen-area of a triangle → winding → facing (backface test).
  double signedArea(int a, int b, int c) =>
      (sx[b] - sx[a]) * (sy[c] - sy[a]) - (sx[c] - sx[a]) * (sy[b] - sy[a]);

  /// Depth-sorted triangle order (FAR → NEAR; nearer = larger world z). A single
  /// global painter's-algorithm sort over ALL triangles regardless of facing —
  /// the two-pass back-then-front scheme is provably wrong at mid-flip.
  Int32List depthOrder() {
    final mz = _meanZ;
    final ord = _order;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (var tr = 0; tr < triCount; tr++) {
      final o = tr * 3;
      final z = (wz[triIdx[o]] + wz[triIdx[o + 1]] + wz[triIdx[o + 2]]) / 3.0;
      mz[tr] = z;
      if (z < lo) lo = z;
      if (z > hi) hi = z;
    }
    // Coplanar leaf (flat at t≈0/1, where bookBumpC1 & the spine rotation both put
    // every vertex back on z=0): no triangle occludes another, so the existing
    // order already renders correctly. Skip the sort — and avoid insertion-sort
    // churn on near-equal noisy keys.
    if (hi - lo < kDepthEps) return ord;
    // ADAPTIVE insertion sort, ascending mean-z (far→near), IN PLACE over the
    // PERSISTED order. The leaf bends continuously (C1, no teleports — guaranteed
    // by the frame-walk test, and re-grab preserves t), so frame-to-frame the
    // order shifts by only a few positions ⇒ this is ~O(n) on the nearly-sorted
    // input, with the key comparison INLINED (no per-comparison closure call the
    // old `_order.sort(_cmp)` paid ~n·log n times). The first active frame may cost
    // one ~O(n²) pass from a cold order; every subsequent motion frame is linear.
    for (var i = 1; i < triCount; i++) {
      final key = ord[i];
      final kz = mz[key];
      var j = i - 1;
      while (j >= 0 && mz[ord[j]] > kz) {
        ord[j + 1] = ord[j];
        j--;
      }
      ord[j + 1] = key;
    }
    return ord;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Shared camera / projection (single source for the render path AND the tests).
// ─────────────────────────────────────────────────────────────────────────────

/// MVP = perspective · view, built with genuine vector_math_64. Camera looks at
/// the page from straight in front, calibrated so the z=0 plane maps pixel-exact
/// to the screen rect.
vm.Matrix4 bookFlipMvp(double w, double h, double fovY) {
  final camDist = BookFlipMesh.camDistFor(h, fovY);
  final eye = vm.Vector3(w * 0.5, h * 0.5, camDist);
  final center = vm.Vector3(w * 0.5, h * 0.5, 0.0);
  assert((eye - center).length > 1e-6, 'eye==center → det=0 view');
  final view = vm.makeViewMatrix(eye, center, vm.Vector3(0.0, -1.0, 0.0));
  final far = camDist + h * kFarPad;
  final proj = vm.makePerspectiveMatrix(fovY, w / h, kNear, far); // FULL fov
  return proj.multiplied(view); // NEW matrix (non-destructive)
}

/// Project ONE world point. Returns (screenX, screenY, clipW). The clipW lets
/// callers/tests assert the perspective w is positive (in front of the camera).
/// Uses the same firewall + screen mapping as the render path.
(double, double, double) bookFlipProjectPoint(
  double px,
  double py,
  double pz,
  double w,
  double h,
  double fovY,
) {
  final mvp = bookFlipMvp(w, h, fovY);
  final v = vm.Vector4(px, py, pz, 1.0);
  mvp.transform(v);
  final cw = v.w;
  if (!cw.isFinite || cw <= kWEps || !v.x.isFinite || !v.y.isFinite) {
    final camDist = BookFlipMesh.camDistFor(h, fovY);
    final t2 = math.tan(fovY * 0.5);
    final aspect = w / h;
    final ndcX = (w * 0.5 - px) / (aspect * t2 * camDist);
    final ndcY = (h * 0.5 - py) / (t2 * camDist);
    return ((1.0 - (ndcX * 0.5 + 0.5)) * w, (1.0 - (ndcY * 0.5 + 0.5)) * h, cw);
  }
  final ndcX = v.x / cw, ndcY = v.y / cw;
  return ((1.0 - (ndcX * 0.5 + 0.5)) * w, (1.0 - (ndcY * 0.5 + 0.5)) * h, cw);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Content orientation — eliminate the "180° mirrored back-face" bug.
//
//  Criterion (unambiguous): at any FLAT state the leaf's (world-x → page-texel) map
//  MUST equal the base layer's drawImageRect map, which is always world-x↑ ⟺ texel↑.
//  A leaf face turning about the VERTICAL spine only ever mirrors HORIZONTALLY, so
//  the fix is purely on u (never v). Derived & verified for all 4 states
//  (dir=±1 × recto/verso) — derived purely from the geometry.
// ─────────────────────────────────────────────────────────────────────────────

/// Which physical face (recto=front, verso=back) is visible, from the triangle's
/// SCREEN winding. Direction-aware: a backward leaf's u-axis is mirrored in world
/// space, so the same winding inverts — hence the dir branch. [orientation]
bool bookFlipFaceFront(double signedArea, int dir) =>
    dir > 0 ? signedArea >= 0.0 : signedArea < 0.0;

/// Whether this visible face must mirror its texture-u to read correctly (i.e. to
/// satisfy world-x↑ ⟺ texel↑ at the flat states).
bool bookFlipMirror(int dir, bool faceFront) =>
    dir > 0 ? !faceFront : faceFront;

/// Normalized page-u (0..1) for a leaf vertex given its arc-length u, the flip
/// direction, and which face shows. Arc-length-locked (no stretch); only the SIGN
/// is chosen here. The painter inlines this identical branch on its hot path
/// (_emitLeaf); this is its named, test-checkable twin — keep the two in lockstep.
double bookFlipLeafTexU(double u, int dir, bool faceFront) =>
    bookFlipMirror(dir, faceFront) ? (1.0 - u) : u;

// ─────────────────────────────────────────────────────────────────────────────
//  Boundary elastic resistance — soft asymptote so a flip past the first/last
//  spread peels slightly then springs back, with NO sharp jump.
// ─────────────────────────────────────────────────────────────────────────────
double boundaryResist(double raw) {
  final x = raw < 0 ? 0.0 : raw;
  return 0.10 * (1.0 - math.exp(-3.0 * x)); // monotone, bounded by 0.10, C1.
}
