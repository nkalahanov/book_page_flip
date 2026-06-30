part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Widget state — gesture/spring driver. No setState: the boot phase drives a
//  ValueListenableBuilder, and the flip itself repaints through the scene
//  Listenable, so the gesture + painter subtree is built once and never rebuilt.
// ─────────────────────────────────────────────────────────────────────────────
enum _BootPhase { loading, ready, error }

class _BookFlipState extends State<BookFlip>
    with SingleTickerProviderStateMixin {
  late final FlipScene _scene;
  late final AnimationController _ctl;
  final ValueNotifier<_BootPhase> _phase = ValueNotifier(_BootPhase.loading);

  int _pageCount = 0;
  int _spread = 0;
  int _target = 0; // spring target (0 settle-back, 1 commit)
  bool _dragging = false;
  bool _atBoundary = false;
  bool _armed =
      false; // grabbed but not yet moved → leaf idle (long-press inert)
  int _pendingDir = 0;
  double _pendingGrabV = 0.5;
  int _bootGen =
      0; // bumped per _boot; a stale boot aborts at its post-await check

  BookFlipPhysics get _physics => widget.physics;

  int get _maxSpread => (_pageCount ~/ 2) - 1;
  bool _canForward(int s) => (2 * s + 3) <= (_pageCount - 1);
  bool _canBackward(int s) => s > 0;

  // Repaint the scene AND notify a listening controller (for flipProgress).
  void _render() {
    // Only notify the controller when the scene actually repainted, so a
    // ListenableBuilder on the controller never rebuilds on a suppressed frame
    // (e.g. the spring tail, where t is pinned and frame() is a no-op).
    if (_scene.frame()) widget.controller?._emit();
  }

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController.unbounded(vsync: this)..addListener(_onTick);
    assert(
        widget.controller?._state == null,
        'This BookFlipController is already attached to another BookFlip — use '
        'one controller per widget.');
    widget.controller?._state = this;
    _spread = (widget.controller?._initialSpread ?? 0)
        .clamp(0, math.max(0, (widget.pages.length ~/ 2) - 1));
    // Clamp to the asserted range so a release build (asserts stripped) can never
    // overflow the 16-bit mesh index — a stripped assert would otherwise corrupt the
    // triangle soup. Debug builds still trip the constructor assert first.
    final meshCols = widget.meshResolution.clamp(8, 300);
    _scene = FlipScene(
      meshCols: meshCols,
      meshRows: math.max(2, (meshCols * kNv / kNu).round()),
    );
    _scene.material = widget.material;
    _scene.curl = widget.curl;
    _scene.effects = widget.effects;
    unawaited(_boot());
  }

  @override
  void didUpdateWidget(BookFlip old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      if (identical(old.controller?._state, this)) {
        old.controller?._state = null;
      }
      assert(
          widget.controller?._state == null,
          'This BookFlipController is already attached to another BookFlip — use '
          'one controller per widget.');
      widget.controller?._state = this;
    }
    if (old.material != widget.material) {
      _scene.material = widget.material;
      _render(); // material changes pixels → repaint (dedupe gates it precisely)
    }
    if (old.curl != widget.curl) {
      _scene.curl = widget.curl;
      _render(); // curve trajectory changed → repaint (dedupe gates precisely)
    }
    if (old.effects != widget.effects) {
      _scene.effects = widget.effects;
      _render(); // effect toggles change pixels → repaint (dedupe gates it)
    }
    if (!identical(old.pages, widget.pages)) {
      // A reload supersedes any in-flight flip: stop the spring and return the
      // scene to idle so the controller can't keep ticking against the (now
      // null) atlas and flash blank. Clamp the visible spread to the NEW book
      // immediately so a listening controller never reports an out-of-range one.
      final wasFlipping = _scene.active;
      _ctl.stop();
      _dragging = false;
      _scene
        ..active = false
        ..dir = 0
        ..t = 0.0;
      _spread = _spread.clamp(0, math.max(0, (widget.pages.length ~/ 2) - 1));
      _scene.atlas?.dispose();
      _scene.atlas = null;
      _phase.value = _BootPhase.loading;
      // A flip cut short by a reload still concludes: fire the single guaranteed
      // terminator so every onFlipStart is balanced by exactly one onFlipEnd —
      // the same interrupt contract as _jumpTo. (onFlipEnd already means "the
      // flip animation concluded"; it fires on spring-back too.) No
      // onSpreadChanged: a content swap is not a navigation, and the controller
      // re-syncs once the new book finishes booting.
      if (wasFlipping) widget.onFlipEnd?.call(_spread);
      unawaited(_boot());
    }
  }

  Future<void> _boot() async {
    final gen = ++_bootGen; // a later _boot supersedes this one
    try {
      final pages = widget.pages;
      final cols = _atlasColsFor(pages.length);
      final rows = _atlasRowsFor(pages.length);
      // Pack into one atlas with the largest cell that fits maxTextureDimension.
      // If the GPU rejects the texture (its real limit is below our target), halve
      // the target and retry: this discovers the device's true ceiling empirically,
      // so a low-end GPU degrades resolution instead of failing to load. Resolved
      // before any interaction.
      final src = pages.first;
      var cap = widget.maxTextureDimension;
      ui.Image? atlas;
      var cellW = 0, cellH = 0;
      while (atlas == null) {
        final (cw, ch) =
            bookFlipAtlasCell(src.width, src.height, cols, rows, cap);
        try {
          atlas = await _packAtlas(pages, cols, cw, ch);
          cellW = cw;
          cellH = ch;
        } on Object {
          if (cap <= kPageTexMin) rethrow; // can't pack even tiny → error UI
          cap = cap ~/ 2;
        }
      }
      if (!mounted || gen != _bootGen) {
        atlas.dispose(); // unmounted OR superseded by a newer boot → no leak
        return;
      }
      _pageCount = pages.length;
      _spread = _spread.clamp(0, math.max(0, _maxSpread));
      _scene
        ..atlas = atlas
        ..atlasCols = cols
        ..cellW = cellW
        ..cellH = cellH;
      _applyPageMap(); // idle map for the opening spread
      _phase.value = _BootPhase.ready;
      // totalSpreads is now known: nudge a listening controller so a "page X of N"
      // indicator built before load updates from its 0 placeholder.
      widget.controller?._emit();
    } on Object catch (_) {
      // toImage can throw (e.g. GPU OOM). Surface retry, never a dead spinner.
      // Ignore a stale boot's failure so it can't clobber a newer success.
      if (mounted && gen == _bootGen) _phase.value = _BootPhase.error;
    }
  }

  // Pack the caller's page images into one atlas texture (a single GPU upload,
  // zero per-flip texture switches). Each page fills a fixed-size cell.
  Future<ui.Image> _packAtlas(
    List<ui.Image> pages,
    int cols,
    int cellW,
    int cellH,
  ) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final paint = Paint()..filterQuality = FilterQuality.high;
    for (var p = 0; p < pages.length; p++) {
      final img = pages[p];
      final src =
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      canvas.drawImageRect(img, src, _cellRect(p, cols, cellW, cellH), paint);
    }
    final pic = rec.endRecording();
    final rows = _atlasRowsFor(pages.length);
    try {
      return await pic.toImage(cols * cellW, rows * cellH);
    } finally {
      pic.dispose(); // dispose even if toImage throws (the adaptive retry path)
    }
  }

  // Programmatic turn (from the controller): a full spring from flat to turned.
  // Returns whether a flip actually started — false is an inert no-op (not ready,
  // a flip already running, or already at the boundary) — so the controller can
  // report it to callers chaining turns.
  bool _driveFlip(int dir, double velocity) {
    if (_phase.value != _BootPhase.ready || _scene.active) return false;
    final canGo = dir > 0 ? _canForward(_spread) : _canBackward(_spread);
    if (!canGo) return false;
    _ctl.stop();
    _dragging = false;
    _atBoundary = false;
    _scene
      ..grabV = 0.5
      ..dir = dir
      ..active = true
      ..atBoundary = false
      ..t = 0.0;
    _applyPageMap();
    widget.onFlipStart?.call(
      _spread,
      dir > 0 ? FlipDirection.forward : FlipDirection.backward,
    );
    _target = 1;
    final spring = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: _physics.springStiffness,
      ratio: _physics.springDampingRatio,
    );
    _ctl.value = 0.0;
    unawaited(_ctl.animateWith(SpringSimulation(spring, 0.0, 1.0, velocity)));
    return true;
  }

  // Instant jump with no animation.
  void _jumpTo(int spread) {
    if (_phase.value != _BootPhase.ready) return;
    // Capture before the teardown: a jump that INTERRUPTS a live flip must still
    // balance the onFlipStart it already fired, and a jump that does not move the
    // book must not emit a spurious onSpreadChanged.
    final wasFlipping = _scene.active;
    final prevSpread = _spread;
    _ctl.stop();
    _dragging = false;
    _spread = spread.clamp(0, math.max(0, _maxSpread));
    _scene
      ..active = false
      ..dir = 0
      ..t = 0.0;
    _applyPageMap();
    _render();
    if (_spread != prevSpread) widget.onSpreadChanged?.call(_spread);
    if (wasFlipping) widget.onFlipEnd?.call(_spread);
  }

  @override
  void dispose() {
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _ctl.dispose();
    _scene.dispose();
    _scene.atlas?.dispose();
    _phase.dispose();
    super.dispose();
  }

  // ── page index mapping ─────────────────────────────────────────────────────
  int _pg(int i) {
    // Paranoid clamp → never a null texture. EXPECTED to clamp at the first/last
    // spread: the off-edge leaf's hidden back page (2s+2 / 2s−1) has no real page,
    // but it is never drawn (you can't flip past the boundary), so it is benign.
    return i.clamp(0, _pageCount - 1);
  }

  void _applyPageMap() {
    final s = _spread;
    if (_scene.dir >= 0) {
      // forward / idle: right leaf turns left.
      _scene.baseLeft = _pg(2 * s);
      _scene.baseRight = _scene.active ? _pg(2 * s + 3) : _pg(2 * s + 1);
      _scene.leafFront = _pg(2 * s + 1);
      _scene.leafBack = _pg(2 * s + 2);
    } else {
      // backward: left leaf turns right.
      _scene.baseLeft = _scene.active ? _pg(2 * s - 2) : _pg(2 * s);
      _scene.baseRight = _pg(2 * s + 1);
      _scene.leafFront = _pg(2 * s);
      _scene.leafBack = _pg(2 * s - 1);
    }
  }

  // ── ticking (spring drives _scene.t) ───────────────────────────────────────
  void _onTick() {
    _scene.t = _ctl.value.clamp(0.0, 1.0);
    _render();
    if (!_dragging) {
      // Use the CLAMPED visible position (scene.t), not _ctl.value: a critically-
      // damped spring with a hard fling can momentarily overshoot the target, and
      // we want the commit to fire when the leaf is visually landed, not after the
      // controller finishes wandering back. No stall, no dangling re-grab window.
      final settled = (_scene.t - _target).abs() < _physics.settleEpsilon &&
          _ctl.velocity.abs() < 0.06;
      if (settled) _finishAnimation();
    }
  }

  void _finishAnimation() {
    _ctl.stop();
    final dir = _scene.dir;
    if (_target == 1 && !_atBoundary) {
      // COMMIT — seamless: at t=1 the leaf lies flat on the far half showing its
      // BACK texture, pixel-identical to the new idle base redraw.
      _spread = (_spread + dir).clamp(0, _maxSpread);
    }
    final committed = _target == 1 && !_atBoundary;
    _scene
      ..active = false
      ..dir = 0
      ..atBoundary = false
      ..t = 0.0;
    _applyPageMap();
    _render();
    if (committed) widget.onSpreadChanged?.call(_spread);
    widget.onFlipEnd?.call(_spread);
  }

  // ── gestures (driven by RenderBookCanvas's HorizontalDragGestureRecognizer) ──
  // A horizontal recognizer (not a pan) so a vertical drag still scrolls a parent
  // list — the book claims only left/right motion. Positions arrive already in the
  // book's content space (RenderBookCanvas subtracts the letterbox margin).
  void _onDragStart(Offset local) {
    if (_scene.w <= 0 || _scene.h <= 0) return;
    _ctl.stop();
    _dragging = true;
    if (_scene.active) {
      // RE-GRAB mid-flip: continue from the CURRENT position. Preserve dir, the
      // page map, AND grabV (changing grabV mid-flip would jolt the per-row tilt).
      // Resetting t here would teleport the leaf back to flat, which this prevents.
      _scene.t = _ctl.value.clamp(0.0, 1.0);
      _render();
      return;
    }
    // Not flipping yet: ARM only. A pure press (no movement) must change NOTHING —
    // no leaf, no shading, no page-map swap. Activation is deferred to the first
    // real movement in _onDragUpdate, so the press itself is inert.
    final raw = local.dy / _scene.h;
    _pendingGrabV = raw.isFinite ? raw.clamp(0.0, 1.0) : 0.5;
    _pendingDir = local.dx >= _scene.w * 0.5 ? 1 : -1;
    _armed = true;
  }

  void _onDragUpdate(double dx) {
    if (!_dragging || _scene.w <= 0) return;
    if (!_scene.active) {
      if (!_armed) return;
      // First real movement → activate the flip now (onUpdate only fires on actual
      // motion, so a held finger never reaches here).
      final dir = _pendingDir;
      _atBoundary = dir > 0 ? !_canForward(_spread) : !_canBackward(_spread);
      _scene
        ..grabV = _pendingGrabV
        ..dir = dir
        ..active = true
        ..atBoundary = _atBoundary
        ..t = 0.0;
      _applyPageMap();
      _armed = false;
      widget.onFlipStart?.call(
        _spread,
        dir > 0 ? FlipDirection.forward : FlipDirection.backward,
      );
    }
    // Drag a full page width to complete a flip. Forward: drag left (dx<0).
    final delta = (-_scene.dir * dx) / _scene.w;
    var raw = _scene.t + delta;
    if (_atBoundary) {
      raw = boundaryResist(raw); // soft peel, springs back.
    } else {
      raw = raw.clamp(0.0, 1.0);
    }
    _scene.t = raw;
    _render();
  }

  void _onDragEnd(double vx) {
    if (!_dragging) return;
    _dragging = false;
    _armed = false;
    if (!_scene.active) return; // pure press, never moved → nothing to settle
    // t-space velocity from the finger (px/s → t/s).
    final vel = (-_scene.dir * vx) / _scene.w;
    if (_atBoundary) {
      _target = 0;
    } else {
      _target = (_scene.t + vel * _physics.velocityLookAhead >
                  _physics.commitThreshold ||
              vel > _physics.commitVelocity)
          ? 1
          : 0;
    }
    // Critically-damped spring: starts at current t with the finger's velocity →
    // C1 hand-off (no position OR velocity jump), no overshoot past flat.
    final spring = SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: _physics.springStiffness,
      ratio: _physics.springDampingRatio,
    );
    _ctl.value = _scene.t;
    unawaited(
      _ctl.animateWith(
          SpringSimulation(spring, _scene.t, _target.toDouble(), vel)),
    );
  }

  // The gesture arena cancelled the drag (system interrupt, a parent scroll won,
  // app backgrounded). Settle from the current position with no fling so the leaf
  // never freezes mid-turn; an armed-but-unmoved press just disarms.
  void _onDragCancel() {
    if (!_dragging) return;
    _onDragEnd(0.0);
  }

  // The spread's natural width÷height, read straight from the input images (known
  // from the first frame, so the size stays stable through loading → ready). A
  // spread is two pages side by side, so it is 2× the single-page ratio. The
  // developer's [BookFlip.pageAspectRatio] override wins when given.
  double _resolveSpreadAspect() {
    final override = widget.pageAspectRatio;
    if (override != null && override.isFinite && override > 0) {
      return 2.0 * override;
    }
    final img = widget.pages.first;
    return img.height > 0
        ? 2.0 * img.width / img.height
        : 2.0 * kPageTexW / kPageTexH;
  }

  // The spread's intrinsic width in logical px, taken 1:1 from the page images
  // (two pages wide). This is the size used when nothing constrains the widget.
  double _naturalSpreadWidth() {
    final pw = widget.pages.first.width;
    return 2.0 * (pw > 0 ? pw : kPageTexW);
  }

  @override
  Widget build(BuildContext context) {
    // RenderAspectFitBox resolves a finite, non-distorting size for ANY parent
    // constraints and centres the phase content — so loading, error and the book
    // share one stable size and none is ever handed an infinite constraint. The
    // flip itself repaints through the scene Listenable, never a rebuild.
    return _AspectFitBox(
      aspectRatio: _resolveSpreadAspect(),
      naturalWidth: _naturalSpreadWidth(),
      fit: widget.fit,
      child: ValueListenableBuilder<_BootPhase>(
        valueListenable: _phase,
        builder: (context, phase, _) {
          switch (phase) {
            case _BootPhase.error:
              return widget.errorBuilder?.call(context) ??
                  _BookErrorView(onRetry: _boot);
            case _BootPhase.loading:
              return widget.loadingBuilder?.call(context) ??
                  const _BookLoadingView();
            case _BootPhase.ready:
              return _BookCanvas(
                scene: _scene,
                onStart: _onDragStart,
                onUpdate: _onDragUpdate,
                onEnd: _onDragEnd,
                onCancel: _onDragCancel,
              );
          }
        },
      ),
    );
  }
}
