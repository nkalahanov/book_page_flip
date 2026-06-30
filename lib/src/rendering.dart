part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Painter — consumes the scene; repaints via Listenable (no per-frame setState).
// ─────────────────────────────────────────────────────────────────────────────
// Stateless drawing routine for the scene. Driven by RenderBookCanvas, which
// repaints on the scene Listenable; this is not a CustomPainter, so it carries no
// widget plumbing — RenderBookCanvas calls paint(canvas, size) directly.
class _BookRenderer {
  _BookRenderer(this.scene);
  final FlipScene scene;

  // Cached atlas ImageShader. The shader is a PURE function of (atlas image,
  // TileMode.clamp×2, identity matrix); the tile modes and the matrix
  // (_kIdentityStorage) are constant, so it only needs rebuilding when the atlas
  // IMAGE reference changes. The atlas is stable for a whole flip and is swapped
  // only on a pages-reload (which disposes the old atlas and builds a new one —
  // see _boot). Without this, an identical ImageShader was rebuilt ~60×/s in
  // _emitLeaf for nothing. Keyed by atlas IDENTITY (see _atlasShaderFor).
  ui.Image? _shaderAtlas;
  ui.ImageShader? _atlasShader;

  // The cached shader for [atlas], rebuilt ONLY on an atlas-identity change. On a
  // miss the superseded shader is disposed first — ui.ImageShader.dispose() is a
  // safe public native release in this SDK; disposing each instance exactly once
  // never trips its "disposed more than once" assert. This is only ever reached
  // with a live, non-null atlas (paint early-returns when scene.atlas == null),
  // and EVERY atlas swap is a cache miss → rebuild, so a shader built on a
  // stale/disposed atlas can never be drawn. (Disposing a shader whose atlas
  // image was already disposed on reload is safe: the shader holds its own native
  // handle to the underlying image.)
  ui.ImageShader _atlasShaderFor(ui.Image atlas) {
    final cached = _atlasShader;
    if (cached != null && identical(_shaderAtlas, atlas)) return cached;
    cached?.dispose();
    final shader = ui.ImageShader(
      atlas, TileMode.clamp, TileMode.clamp, //
      _kIdentityStorage,
    );
    _shaderAtlas = atlas;
    _atlasShader = shader;
    return shader;
  }

  // Releases the cached atlas shader (called from RenderBookCanvas.dispose).
  // Idempotent: safe if no shader was ever built (paint never ran).
  void _disposeShader() {
    _atlasShader?.dispose();
    _atlasShader = null;
    _shaderAtlas = null;
  }

  void paint(Canvas canvas, Size size) {
    final atlas = scene.atlas;
    if (atlas == null) return; // painting before _ready — nothing to draw yet.
    final w = size.width, h = size.height;
    if (w <= 1 || h <= 1) return;
    final spineX = w * 0.5;
    final idle = !scene.active || scene.dir == 0;

    // L4 — leaf geometry is computed FIRST when active, because the base layer below
    // needs the projected free-edge curve to confine the OUTGOING page to the leaf's
    // wake (the seamless-commit fix). World feeds the cast shadow + depth sort too.
    final m = scene.mesh;
    var hEnv = 0.0;
    var safe = true;
    if (!idle) {
      m.computeWorld(
        w,
        h,
        scene.t,
        scene.grabV,
        scene.dir,
        material: scene.material,
        curl: scene.curl,
      );
      hEnv = (m.maxAbsZ() / (kShadowZRef * w)).clamp(0.0, 1.0);
      m.project(w, h, kFovY); // sets sx/sy (free-edge clip) + lastBadCount
      safe = m.lastBadCount <= m.n * 0.3;
    }

    // L1 — ALWAYS-OPAQUE base (two page halves; zero transparent spots, ever). While
    // a real committing flip turns, the half the leaf LANDS on is wake-composited so
    // the leaf→base handoff at commit is pixel-seamless (see _drawBase). A boundary
    // peel springs back (never commits, and its landing page is a clamped phantom), so
    // it is excluded — it keeps the plain base.
    final composite = !idle && safe && !scene.atBoundary;
    _drawBase(canvas, atlas, w, h, spineX, wake: composite ? m : null);

    if (idle) {
      // BINDING AMBIENT OCCLUSION at the spine: CONSTANT at ALL times (rest AND
      // flip) → the center shadow can never "appear after landing".
      if (scene.effects.spineShadow) {
        _drawBindingAO(canvas, w, h, spineX);
      }
      return;
    }
    // Catastrophic firewall: the flat base is already drawn; the leaf would be
    // garbage, so bail before emitting it.
    if (!safe) return;

    // L2 — CAST SHADOW (constant umbra, geometric vanish), drawn UNDER the leaf.
    if (scene.effects.castShadow) {
      _drawCastShadow(canvas, m, w, h, hEnv, spineX, scene.dir);
    }
    m.computeNormals();
    m.computeShading(
      w,
      h,
      kFovY,
      material: scene.material,
      effects: scene.effects,
    );

    final order = m.depthOrder();
    _emitLeaf(canvas, atlas, m, order, w, h);

    // The SAME constant binding AO, composited OVER the leaf (drawing it before the
    // leaf's BlendMode.modulate pass would hue-shift the near-spine content). Constant
    // strength → identical at rest, mid-flip, and landing → NO late ramp.
    if (scene.effects.spineShadow) {
      _drawBindingAO(canvas, w, h, spineX);
    }

    // L6 — thin free-edge line for paper "body".
    if (scene.effects.edge) {
      _drawEdge(canvas, m);
    }
  }

  // Draws the two opaque page halves. When [wake] is non-null (a committing flip is
  // active), the half the leaf LANDS on is composited so the commit is SEAMLESS:
  //   1. the LANDING page (leaf back) fills that half UNDER the leaf — so every leaf
  //      fringe/AA pixel already sits over the landing page, matching the leaf;
  //   2. the OUTGOING page is clipped to the leaf's WAKE — the region beyond its free
  //      edge it has not covered yet — so the still-turning area correctly shows the
  //      old page during the flip.
  // The wake shrinks to nothing exactly at t=1 (the free edge reaches the page edge),
  // so the only OLD→NEW change at commit is sub-pixel. The SOURCE half never swaps its
  // page, so it is a plain blit, drawn LAST so it wins the 1px spine overlap (full
  // coverage for any fractional spineX; src cell deflated 0.5px to avoid bleed).
  void _drawBase(
    Canvas canvas,
    ui.Image atlas,
    double w,
    double h,
    double spineX, {
    required BookFlipMesh? wake,
  }) {
    final basePaint = Paint()..filterQuality = FilterQuality.high;
    final lSplit = spineX.ceilToDouble();
    final rSplit = spineX.floorToDouble();
    final leftRect = Rect.fromLTRB(0, 0, lSplit, h);
    final rightRect = Rect.fromLTRB(rSplit, 0, w, h);
    void blit(int page, Rect dst) => canvas.drawImageRect(
          atlas,
          _cellRect(page, scene.atlasCols, scene.cellW, scene.cellH)
              .deflate(0.5),
          dst,
          basePaint,
        );

    final dir = scene.dir;
    if (wake == null || dir == 0) {
      // Idle / boundary / firewall: plain two-half base, right half last.
      blit(scene.baseLeft, leftRect);
      blit(scene.baseRight, rightRect);
      return;
    }
    // Active committing flip. dir>0 lands LEFT, dir<0 lands RIGHT.
    final destRect = dir > 0 ? leftRect : rightRect;
    final srcRect = dir > 0 ? rightRect : leftRect;
    final destOld = dir > 0 ? scene.baseLeft : scene.baseRight; // outgoing page
    final srcPage = dir > 0 ? scene.baseRight : scene.baseLeft; // never swaps
    blit(scene.leafBack,
        destRect); // landing page UNDER the leaf — fringes match it
    canvas.save();
    _clipWake(canvas, wake, w, h, dir); // confine the outgoing page to the wake
    blit(destOld, destRect);
    canvas.restore();
    blit(srcPage, srcRect); // source half last → wins the spine overlap
  }

  // Clips to the leaf's WAKE on the destination half: the region between the leaf's
  // projected free-edge column (u = nu−1) and the destination's far edge (x=0 for a
  // forward flip, x=w for a backward one). Built from the SAME projected vertices the
  // leaf renders, so the boundary aligns with the leaf's free edge exactly. At t=1 the
  // free edge reaches the far edge, so the wake collapses to zero area.
  void _clipWake(Canvas canvas, BookFlipMesh m, double w, double h, int dir) {
    final i = m.nu - 1; // free-edge column
    final farX = dir > 0 ? 0.0 : w;
    final path = Path()
      ..moveTo(farX, 0)
      ..lineTo(farX, h);
    for (var j = m.nv - 1; j >= 0; j--) {
      final idx = j * m.nu + i;
      path.lineTo(m.sx[idx], m.sy[idx]); // up the free-edge curve, bottom → top
    }
    path.close();
    canvas.clipPath(path);
  }

  void _emitLeaf(
    Canvas canvas,
    ui.Image atlas,
    BookFlipMesh m,
    Int32List order,
    double w,
    double h,
  ) {
    final triCount = m.triCount;
    final vCount =
        triCount * 3; // triangle soup (no shared indices across batch)
    final pos = m.posSoup, tex = m.texSoup, colM = m.colMain, colS = m.colSheen;
    final dir = scene.dir;

    final frontCell =
        _cellRect(scene.leafFront, scene.atlasCols, scene.cellW, scene.cellH);
    final backCell =
        _cellRect(scene.leafBack, scene.atlasCols, scene.cellW, scene.cellH);
    final fU = frontCell.left, fV = frontCell.top;
    final bU = backCell.left, bV = backCell.top;
    final pw = scene.cellW, ph = scene.cellH;

    var vi = 0;
    for (var oi = 0; oi < triCount; oi++) {
      final tr = order[oi];
      final o = tr * 3;
      final a = m.triIdx[o], b = m.triIdx[o + 1], c = m.triIdx[o + 2];
      // Direction-aware facing (recto vs verso) + the horizontal-mirror flag that
      // makes the verso read correctly and lands at 180° with NO content snap.
      final area = m.signedArea(a, b, c);
      final faceFront = bookFlipFaceFront(area, dir);
      final cu = faceFront ? fU : bU;
      final cv = faceFront ? fV : bV;
      final mirror = bookFlipMirror(dir, faceFront);
      // Allocation-free vertex walk — SCOPED TO THIS INNER PER-VERTEX LOOP ONLY,
      // not the render frame (the frame still allocates Paint/Path/Vertices; see
      // the note at mainPaint below). The old `for (final vIdx in [a, b, c])`
      // allocated a throwaway 3-element List per triangle (~triCount lists/frame,
      // never captured by the vertsAllocs metric) — pure GC pressure on the hot
      // path. a/b/c are exactly triIdx[o..o+2], so index directly.
      for (var k = 0; k < 3; k++) {
        final vIdx = k == 0 ? a : (k == 1 ? b : c);
        final ui0 =
            m.uNorm[vIdx]; // precomputed grid coords (no per-vertex divide)
        final v = m.vNorm[vIdx];
        final tU = mirror ? (1.0 - ui0) : ui0; // arc-length-locked; sign only
        final p2 = vi * 2;
        pos[p2] = m.sx[vIdx];
        pos[p2 + 1] = m.sy[vIdx];
        // Half-texel inset: map u,v∈[0,1] to pixel CENTERS so the bilinear
        // (FilterQuality.high) footprint never crosses into an adjacent atlas cell
        // (which would bleed a neighbouring page along the leaf edges). v never
        // flips (rotation is about the vertical spine).
        tex[p2] = (cu + 0.5) + tU * (pw - 1.0);
        tex[p2 + 1] = (cv + 0.5) + v * (ph - 1.0);
        // Vertex color = luminance * white. Alpha MUST be 255 (modulate
        // multiplies alpha too → any <255 makes the leaf translucent).
        final lum = (m.lum[vIdx] * 255.0).clamp(0.0, 255.0).round();
        colM[vi] = (0xFF << 24) | (lum << 16) | (lum << 8) | lum;
        final sp = (m.spec[vIdx] * 255.0).clamp(0.0, 255.0).round();
        colS[vi] = (0xFF << 24) | (sp << 16) | (sp << 8) | sp;
        vi++;
      }
    }

    // ONE drawVertices for the whole leaf — single atlas texture, so the global
    // depth sort produces zero texture switches.
    final vertsMain = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(pos, 0, vCount * 2),
      textureCoordinates: Float32List.sublistView(tex, 0, vCount * 2),
      colors: Int32List.sublistView(colM, 0, vCount),
    );
    // The atlas ImageShader is now cached and reused across frames (see
    // _atlasShaderFor) — it was the one per-frame allocation here that was a pure
    // function of constants. The rest of the frame is NOT allocation-free: this
    // Paint, the sheen layer/draw Paints below, and the per-call Paint/Path/
    // Vertices in _drawBase, _drawCastShadow, _drawBindingAO and _drawEdge are
    // still freshly allocated every active frame (~a dozen short-lived
    // Paint/Path/Vertices objects, now minus the cached ImageShader). The
    // "allocation-free" claims apply only to the inner vertex walk above and the
    // geometry mesh core, never to the whole frame.
    final mainPaint = Paint()
      ..filterQuality = FilterQuality.high
      ..shader = _atlasShaderFor(atlas);
    // drawVertices blendMode = modulate: result = texture(src) * vertexColor(dst).
    canvas.drawVertices(vertsMain, BlendMode.modulate, mainPaint);

    // L5 — additive sheen, composited as ONE unit through a saveLayer. Drawn
    // directly with BlendMode.plus, the depth-sorted soup ADDS the BACK face's glint
    // and then the FRONT face's on top wherever the curled leaf folds over itself at
    // mid-flip — the hidden back-face highlight bleeds THROUGH the opaque front,
    // reading as a see-through page (and the brighter coat makes it glaring). Inside
    // the layer the sheen is opaque (alpha 255) and drawn far→near, so srcOver lets
    // the NEAR (front) triangle win — no bleed-through, no double-add at the fold —
    // and the layer is then added to the scene exactly once. (Same one-unit trick
    // the cast shadow uses to avoid double-darkening overlaps.)
    final vertsSheen = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(pos, 0, vCount * 2),
      colors: Int32List.sublistView(colS, 0, vCount),
    );
    canvas
      ..saveLayer(_leafBounds(m, w, h), Paint()..blendMode = BlendMode.plus)
      ..drawVertices(
        vertsSheen,
        BlendMode.modulate,
        Paint()..color = Colors.white,
      )
      ..restore();
  }

  // Tight screen AABB of the projected leaf (sx/sy are firewalled finite), padded a
  // pixel, used to size the sheen saveLayer's offscreen. Falls back to the full page
  // rect if anything is degenerate, so the layer is never empty/NaN.
  Rect _leafBounds(BookFlipMesh m, double w, double h) {
    var loX = double.infinity, loY = double.infinity;
    var hiX = double.negativeInfinity, hiY = double.negativeInfinity;
    for (var i = 0; i < m.n; i++) {
      final x = m.sx[i], y = m.sy[i];
      if (x < loX) loX = x;
      if (x > hiX) hiX = x;
      if (y < loY) loY = y;
      if (y > hiY) hiY = y;
    }
    if (!(loX.isFinite && loY.isFinite && hiX.isFinite && hiY.isFinite) ||
        hiX < loX ||
        hiY < loY) {
      return Rect.fromLTWH(0, 0, w, h);
    }
    return Rect.fromLTRB(loX - 1, loY - 1, hiX + 1, hiY + 1);
  }

  void _drawBindingAO(Canvas c, double w, double h, double spineX) {
    // The binding valley's ambient occlusion as a TRUE Gaussian: a thin solid core
    // blurred by MaskFilter → a C∞-smooth dark band, darkest at the spine, with no
    // center crease (the old linear tent flipped slope at the apex → a visible
    // ridge line) and no hard side edge. CONSTANT strength → it is simply the
    // book's binding, identical at every instant of the flip → no late ramp.
    final sigma = w * kBindingSigma;
    final coreW = w * kBindingCore;
    c.drawRect(
      Rect.fromLTRB(spineX - coreW, -sigma, spineX + coreW, h + sigma),
      Paint()
        ..color = const Color.fromRGBO(0, 0, 0, kBindingAO)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
    );
  }

  void _drawCastShadow(
    Canvas canvas,
    BookFlipMesh m,
    double w,
    double h,
    double hEnv,
    double spineX,
    int dir,
  ) {
    // The drop shadow DISSOLVES at contact via two cooperating mechanisms, so it
    // never pops: (1) GEOMETRY — the cast offset (Pz/Lz)→0 as the leaf flattens, so the
    // footprint tucks back under the leaf (drawn on top) and the source-half clip drops
    // anything crossing the spine; (2) a C1 OPACITY fade over the last fraction of the
    // descent (bookFlipCastFade) that eases the umbra to 0. The geometric vanish alone
    // left the spine-ANCHORED hinge strip at full alpha until a hard cutoff — the
    // "sharp disappearance of the shadow at the spine on landing" this fade removes.
    final fade = bookFlipCastFade(hEnv);
    if (fade <= 0.002) {
      return; // < ~0.1% umbra → invisible: skip the empty shadow layer
    }
    final alpha =
        bookFlipUmbra(scene.material) * fade; // thicker stock → firmer shadow

    // Cast each leaf vertex onto the base plane z=0 along the light. The camera
    // is calibrated so the z=0 plane maps screen-identity → the cast SCREEN
    // position is simply the cast world (x,y); no matrix needed.
    final lx = _kLight.x, ly = _kLight.y; // shared scene light
    final sp = m.shadowPos;
    final invLz = _kInvLightZ;
    for (var i = 0; i < m.n; i++) {
      final k = m.wz[i] * invLz;
      var shx = m.wx[i] - k * lx;
      var shy = m.wy[i] - k * ly;
      if (!shx.isFinite || !shy.isFinite) {
        shx = m.wx[i];
        shy = m.wy[i];
      } // firewall → flat footprint
      sp[i * 2] = shx;
      sp[i * 2 + 1] = shy;
    }

    // Softness grows with height: large/soft mid-flight, tighter as it lands — but a
    // raised floor (6, not 3) keeps the DISSOLVING landing shadow soft-edged, so the
    // umbra fade reads as a gentle melt rather than a crisp shape blinking out.
    final sigma = 6.0 + 23.0 * hEnv;
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(sp, 0, m.n * 2),
      indices: m.triIdx,
    );
    // Composite the whole shadow as ONE blurred, semi-transparent unit so folded
    // (overlapping) triangles don't double-darken. Layer alpha = shadow opacity.
    final layer = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      )
      ..color = Color.fromRGBO(0, 0, 0, alpha);
    // Pad bounds by the blur radius so the shadow footprint isn't hard-clipped at
    // the screen edge (which the blur would otherwise smear into a straight band).
    final pad = sigma;
    canvas.save();
    // Clip the cast shadow to the half of the canvas that the leaf is departing
    // from. The light vector has a rightward bias (lx < 0 → shadow shifts right),
    // so the footprint can cross the spine by up to ~3.7 px unblurred and, after
    // the Gaussian, brightens the exposed page's spine by ~44% at mid-flip.
    // Restricting to the source half keeps the shadow entirely under the leaf.
    if (dir > 0) {
      // Forward flip: leaf moves right→left; source half is the right side.
      canvas.clipRect(Rect.fromLTRB(spineX, -pad, w + pad, h + pad));
    } else {
      // Backward flip: leaf moves left→right; source half is the left side.
      canvas.clipRect(Rect.fromLTRB(-pad, -pad, spineX, h + pad));
    }
    canvas.saveLayer(Rect.fromLTRB(-pad, -pad, w + pad, h + pad), layer);
    canvas.drawVertices(
      verts,
      BlendMode.srcOver,
      Paint()..color = const Color(0xFF000000),
    );
    canvas.restore();
    canvas.restore(); // restore the clip
  }

  void _drawEdge(Canvas c, BookFlipMesh m) {
    // Free edge = u=1 column (i = nu-1), all rows. A thin translucent dark line.
    final path = Path();
    final i = m.nu - 1;
    for (var j = 0; j < m.nv; j++) {
      final idx = j * m.nu + i;
      if (j == 0) {
        path.moveTo(m.sx[idx], m.sy[idx]);
      } else {
        path.lineTo(m.sx[idx], m.sy[idx]);
      }
    }
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bookFlipEdgeWidth(scene.material)
        ..color = const Color(0x33000000),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Layout — a finite, non-distorting size for ANY constraints. No LayoutBuilder
//  and no hardcoded page shape. RenderAspectFitBox resolves the size and centres
//  the phase content (the book, or a placeholder) in a letterbox; RenderBookCanvas
//  just fills that box, paints and recognises drags.
// ─────────────────────────────────────────────────────────────────────────────

/// How a [BookFlip] fits inside the space its parent gives it.
enum BookFit {
  /// Keep the pages' true proportions, centring the book and leaving empty space
  /// on the longer side when the space is a different shape. The book never
  /// stretches. This is the default.
  contain,

  /// Stretch the book to fill all the space. Simple, but the pages look squashed
  /// or stretched when the space is a different shape than the pages.
  fill,
}

// Sizes the book (and its loading/error placeholders) for ANY parent constraints
// and centres the result — the single place layout happens, so no infinity ever
// reaches the paint math and every phase shares one stable size.
class _AspectFitBox extends SingleChildRenderObjectWidget {
  const _AspectFitBox({
    required this.aspectRatio,
    required this.naturalWidth,
    required this.fit,
    required super.child,
  });

  final double aspectRatio; // natural spread width÷height (> 0)
  final double naturalWidth; // intrinsic spread width in logical px (> 0)
  final BookFit fit;

  @override
  RenderAspectFitBox createRenderObject(BuildContext context) =>
      RenderAspectFitBox(
        aspectRatio: aspectRatio,
        naturalWidth: naturalWidth,
        fit: fit,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAspectFitBox renderObject,
  ) {
    renderObject
      ..aspectRatio = aspectRatio
      ..naturalWidth = naturalWidth
      ..fit = fit;
  }
}

/// Lays [BookFlip] out to a finite size under ANY constraints and centres its
/// child in a letterbox so the pages keep their true shape. It never throws under
/// unbounded constraints and never distorts the pages.
class RenderAspectFitBox extends RenderShiftedBox {
  /// Creates the box. [aspectRatio] is the spread's natural width÷height.
  RenderAspectFitBox({
    required double aspectRatio,
    required double naturalWidth,
    required BookFit fit,
  })  : _aspectRatio = aspectRatio,
        _naturalWidth = naturalWidth,
        _fit = fit,
        super(null);

  /// The spread's natural width÷height. Non-positive values are ignored.
  double get aspectRatio => _aspectRatio;
  double _aspectRatio;
  set aspectRatio(double value) {
    if (_aspectRatio == value || !(value > 0)) return;
    _aspectRatio = value;
    markNeedsLayout();
  }

  /// The spread's intrinsic width in logical pixels (from the page images). Used
  /// only when BOTH axes are unbounded — the book then takes its content's natural
  /// size, exactly as an unconstrained [Image] does. Non-positive values ignored.
  double get naturalWidth => _naturalWidth;
  double _naturalWidth;
  set naturalWidth(double value) {
    if (_naturalWidth == value || !(value > 0)) return;
    _naturalWidth = value;
    markNeedsLayout();
  }

  /// How the book fits its box.
  BookFit get fit => _fit;
  BookFit _fit;
  set fit(BookFit value) {
    if (_fit == value) return;
    _fit = value;
    markNeedsLayout();
  }

  // Resolve a finite size for ANY constraints. Bounded axes fill; an unbounded
  // axis takes the natural size for the bounded one; fully-unbounded falls back to
  // a finite preferred size so the widget can never throw or collapse to nothing.
  Size _resolveSize(BoxConstraints c) {
    final ar = _aspectRatio;
    if (c.hasBoundedWidth && c.hasBoundedHeight) return c.biggest;
    if (c.hasBoundedWidth) {
      return c.constrain(Size(c.maxWidth, c.maxWidth / ar));
    }
    if (c.hasBoundedHeight) {
      return c.constrain(Size(c.maxHeight * ar, c.maxHeight));
    }
    // BOTH axes unbounded: take the content's intrinsic size (like an
    // unconstrained Image) — there is no magic fallback dimension.
    return c.constrain(Size(_naturalWidth, _naturalWidth / ar));
  }

  // The centred book rectangle within [box]: the whole box for BookFit.fill, else
  // the largest aspect-correct rectangle that fits, centred (a letterbox).
  Rect _contentRectFor(Size box) {
    if (_fit == BookFit.fill || box.isEmpty) return Offset.zero & box;
    final ar = _aspectRatio;
    final boxAr = box.width / box.height;
    final double w, h;
    if (boxAr >= ar) {
      h = box.height;
      w = h * ar;
    } else {
      w = box.width;
      h = w / ar;
    }
    return Rect.fromLTWH((box.width - w) / 2.0, (box.height - h) / 2.0, w, h);
  }

  /// The centred book rectangle within [size]. Exposed for tests.
  @visibleForTesting
  Rect get contentRect => _contentRectFor(size);

  @override
  double computeMinIntrinsicWidth(double height) =>
      height.isFinite ? height * _aspectRatio : 0.0;
  @override
  double computeMaxIntrinsicWidth(double height) =>
      computeMinIntrinsicWidth(height);
  @override
  double computeMinIntrinsicHeight(double width) =>
      width.isFinite ? width / _aspectRatio : 0.0;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _resolveSize(constraints);

  @override
  void performLayout() {
    size = _resolveSize(constraints);
    final child = this.child;
    if (child == null) return;
    final content = _contentRectFor(size);
    child.layout(BoxConstraints.tight(content.size));
    (child.parentData! as BoxParentData).offset = content.topLeft;
  }
}

// The book itself: a leaf that fills the (already letterboxed) box it is given,
// publishes that size to the scene, paints, and recognises horizontal drags. It
// holds no sizing logic — RenderAspectFitBox decided the size and position, so a
// touch point already arrives in the book's own coordinate space.
class _BookCanvas extends LeafRenderObjectWidget {
  const _BookCanvas({
    required this.scene,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  final FlipScene scene;
  final void Function(Offset localInContent) onStart;
  final void Function(double dx) onUpdate;
  final void Function(double vx) onEnd;
  final VoidCallback onCancel;

  @override
  RenderBookCanvas createRenderObject(BuildContext context) => RenderBookCanvas(
        scene: scene,
        onStart: onStart,
        onUpdate: onUpdate,
        onEnd: onEnd,
        onCancel: onCancel,
      );

  @override
  void updateRenderObject(BuildContext context, RenderBookCanvas renderObject) {
    renderObject
      ..onStart = onStart
      ..onUpdate = onUpdate
      ..onEnd = onEnd
      ..onCancel = onCancel;
  }
}

/// Paints a [BookFlip] and recognises its horizontal drags. It fills the box it
/// is given — its parent [RenderAspectFitBox] has already sized and positioned it
/// — so a touch point is already in the book's own coordinate space.
class RenderBookCanvas extends RenderBox {
  /// Creates the canvas bound to [scene], reporting drags through the callbacks.
  RenderBookCanvas({
    required FlipScene scene,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  }) : _scene = scene {
    _drag = HorizontalDragGestureRecognizer()
      ..onStart = ((d) => onStart(d.localPosition))
      ..onUpdate = ((d) => onUpdate(d.primaryDelta ?? d.delta.dx))
      ..onEnd =
          ((d) => onEnd(d.primaryVelocity ?? d.velocity.pixelsPerSecond.dx))
      ..onCancel = (() => onCancel());
  }

  final FlipScene _scene;

  /// Called when a drag begins, with the touch point in the book's content space.
  void Function(Offset localInContent) onStart;

  /// Called on each drag move, with the horizontal delta in logical pixels.
  void Function(double dx) onUpdate;

  /// Called when the drag ends, with the horizontal fling velocity (px/s).
  void Function(double vx) onEnd;

  /// Called when the drag is cancelled by the gesture arena.
  VoidCallback onCancel;

  late final HorizontalDragGestureRecognizer _drag;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scene.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _scene.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    // Release the renderer's cached atlas ImageShader before tearing down. Safe
    // even if paint never ran (no shader was built → idempotent no-op).
    _renderer._disposeShader();
    _drag.dispose();
    super.dispose();
  }

  @override
  bool get sizedByParent => true; // size is purely the (tight) parent box.

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    // sizedByParent: [size] is already set from the tight parent box. Publish it
    // to the scene so the render math runs at the book's real size.
    _scene
      ..w = size.width
      ..h = size.height;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    assert(debugHandleEvent(event, entry), 'pointer event/entry mismatch');
    if (event is PointerDownEvent) _drag.addPointer(event);
  }

  late final _BookRenderer _renderer = _BookRenderer(_scene);

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    if (offset == Offset.zero) {
      _renderer.paint(canvas, size);
      return;
    }
    canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    _renderer.paint(canvas, size);
    canvas.restore();
  }
}

// Default placeholder while the page texture is prepared. Theme-coloured so it
// stays visible on any background (no hardcoded light-on-light colour).
class _BookLoadingView extends StatelessWidget {
  const _BookLoadingView();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

// Default placeholder when the page texture could not be built; tap to retry.
class _BookErrorView extends StatelessWidget {
  const _BookErrorView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(
          onPressed: onRetry,
          child: const Text('Could not build pages — tap to retry'),
        ),
      );
}
