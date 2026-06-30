part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Scene — repaint model (ChangeNotifier). Owns the long-lived mesh + atlas so
//  per-frame buffers survive widget rebuilds. Painter uses super(repaint: scene).
// ─────────────────────────────────────────────────────────────────────────────
class FlipScene extends ChangeNotifier {
  /// Creates a scene whose mesh has [meshCols]×[meshRows] vertices.
  FlipScene({int meshCols = kNu, int meshRows = kNv})
      : mesh = BookFlipMesh(nu: meshCols, nv: meshRows);

  final BookFlipMesh mesh;
  ui.Image? atlas;

  double w = 0, h = 0;
  double t = 0.0; // flip progress [0,1]
  int dir = 0; // +1 forward (right leaf), -1 backward (left leaf), 0 idle
  double grabV = 0.5;
  bool active = false; // a leaf is mid-flip (dragging or springing)
  // True while a flip is peeling against the first/last spread (springs back, never
  // commits). The painter skips destination wake-compositing for it: there is no
  // page swap to hide, and the would-be landing page is a clamped phantom.
  bool atBoundary = false;

  // Page indices for the current flip (see _PageMap).
  int baseLeft = 0, baseRight = 1, leafFront = 1, leafBack = 2;
  // Column count of the packed atlas (fixed once the atlas is built).
  int atlasCols = 1;
  // Atlas cell size in px, derived from the page images at boot (not hardcoded).
  // Cells keep each page's aspect ratio, so the rendered spread never distorts.
  int cellW = kPageTexW, cellH = kPageTexH;
  // Paper material — shapes the bend, sheen, droop, shadow and edge.
  BookFlipMaterial material = BookFlipMaterial.paper;
  // Optional direct page-curve override (null → the material decides the bend).
  BookFlipCurl? curl;
  // Which visual effects are drawn (all on by default = the full look).
  BookFlipEffects effects = BookFlipEffects.all;

  // ── RENDER-STATE DEDUPE ────────────────────────────────────────────────────
  // The painter (_BookPainter) is a PURE function of exactly these fields — every
  // per-frame buffer is recomputed from (t, active, dir, grabV, the four page
  // indices, w, h, atlas). Therefore two consecutive identical tuples paint a
  // BYTE-IDENTICAL frame, and issuing notifyListeners() for the second one runs
  // the whole ~2 ms world→normals→project→shading→sort→emit→shadow pipeline + a
  // GPU submit for zero visible change. A held/stationary finger (delta.dx==0),
  // the spring's first tick (== the last drag t), and the clamped overshoot tail
  // all produce such repeats — exactly the "redundant notifyListeners / redundant
  // paint" pattern. We elide them here, at the SOLE notify
  // choke point, so the fix covers drag, tick, activate, commit and settle-back
  // uniformly. Exact (==) equality is intentional: the observed repeats are
  // bit-identical, and any genuine sub-pixel motion changes the bits → still
  // paints, so there is no risk of swallowing real movement. NaN/-1 sentinels make
  // the very first frame() always notify. It is a correctness-neutral performance
  // guard, not instrumentation.
  double _rT = double.nan;
  bool _rActive = false;
  int _rDir = 0;
  double _rGrabV = double.nan;
  int _rBL = -1, _rBR = -1, _rLF = -1, _rLB = -1;
  double _rW = -1, _rH = -1;
  ui.Image? _rAtlas;
  BookFlipMaterial? _rMaterial;
  BookFlipCurl? _rCurl;
  BookFlipEffects? _rEffects;

  /// Repaints only when a pixel-relevant field actually changed since the last
  /// notify. Returns whether a repaint was issued, so callers can also gate any
  /// secondary side effects (e.g. notifying a controller) on real change.
  bool frame() {
    final changed = t != _rT ||
        active != _rActive ||
        dir != _rDir ||
        grabV != _rGrabV ||
        baseLeft != _rBL ||
        baseRight != _rBR ||
        leafFront != _rLF ||
        leafBack != _rLB ||
        w != _rW ||
        h != _rH ||
        !identical(atlas, _rAtlas) ||
        !identical(material, _rMaterial) ||
        !identical(curl, _rCurl) ||
        !identical(effects, _rEffects);
    if (!changed) {
      return false; // identical render state → repaint would be waste.
    }
    _rT = t;
    _rActive = active;
    _rDir = dir;
    _rGrabV = grabV;
    _rBL = baseLeft;
    _rBR = baseRight;
    _rLF = leafFront;
    _rLB = leafBack;
    _rW = w;
    _rH = h;
    _rAtlas = atlas;
    _rMaterial = material;
    _rCurl = curl;
    _rEffects = effects;
    notifyListeners();
    return true;
  }
}
