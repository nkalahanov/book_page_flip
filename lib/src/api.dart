part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Public API
// ─────────────────────────────────────────────────────────────────────────────

/// The direction a page turns.
enum FlipDirection {
  /// Toward later pages (the right-hand leaf lifts and falls to the left).
  forward,

  /// Back toward earlier pages (the left-hand leaf lifts and falls to the right).
  backward,
}

/// Tuning for how a [BookFlip] page settles after a drag is released.
///
/// Every value has a sensible default. Pass a custom instance to
/// [BookFlip.physics] only when you want a snappier or softer feel.
@immutable
class BookFlipPhysics {
  /// Creates an immutable set of flip-physics options.
  const BookFlipPhysics({
    this.springStiffness = kSpringStiffness,
    this.springDampingRatio = 1.0,
    this.commitThreshold = 0.5,
    this.commitVelocity = 1.2,
    this.velocityLookAhead = 0.12,
    this.settleEpsilon = kCommitEps,
  })  : assert(springStiffness > 0, 'springStiffness must be > 0'),
        assert(springDampingRatio > 0, 'springDampingRatio must be > 0'),
        assert(
          commitThreshold >= 0 && commitThreshold <= 1,
          'commitThreshold must be 0..1',
        ),
        assert(commitVelocity > 0, 'commitVelocity must be > 0'),
        assert(velocityLookAhead >= 0, 'velocityLookAhead must be >= 0'),
        assert(settleEpsilon > 0, 'settleEpsilon must be > 0');

  /// How hard the spring pulls the page to rest. Higher feels snappier.
  final double springStiffness;

  /// Spring damping. 1.0 is critically damped (no bounce); below 1.0 overshoots.
  final double springDampingRatio;

  /// How far you must drag (0..1 of a full turn) before releasing commits the
  /// flip instead of springing back.
  final double commitThreshold;

  /// A fling faster than this (turns per second) commits the flip even when you
  /// release before [commitThreshold].
  final double commitVelocity;

  /// How far the release velocity is projected ahead when deciding to commit.
  final double velocityLookAhead;

  /// How close to the target the page must be before the flip is finished.
  final double settleEpsilon;

  @override
  bool operator ==(Object other) =>
      other is BookFlipPhysics &&
      other.springStiffness == springStiffness &&
      other.springDampingRatio == springDampingRatio &&
      other.commitThreshold == commitThreshold &&
      other.commitVelocity == commitVelocity &&
      other.velocityLookAhead == velocityLookAhead &&
      other.settleEpsilon == settleEpsilon;

  @override
  int get hashCode => Object.hash(
        springStiffness,
        springDampingRatio,
        commitThreshold,
        commitVelocity,
        velocityLookAhead,
        settleEpsilon,
      );

  /// A copy of this physics with the given fields replaced.
  BookFlipPhysics copyWith({
    double? springStiffness,
    double? springDampingRatio,
    double? commitThreshold,
    double? commitVelocity,
    double? velocityLookAhead,
    double? settleEpsilon,
  }) =>
      BookFlipPhysics(
        springStiffness: springStiffness ?? this.springStiffness,
        springDampingRatio: springDampingRatio ?? this.springDampingRatio,
        commitThreshold: commitThreshold ?? this.commitThreshold,
        commitVelocity: commitVelocity ?? this.commitVelocity,
        velocityLookAhead: velocityLookAhead ?? this.velocityLookAhead,
        settleEpsilon: settleEpsilon ?? this.settleEpsilon,
      );
}

/// The look and feel of the paper a [BookFlip] is made of.
///
/// There are two ready-made papers: [paper] — the calibrated matte default — and
/// [magazine], glossy coated stock with the optional white gloss. Pick one, or
/// build your own from four simple 0..1 dials (plus an edge thickness). The
/// default ([paper]) reproduces the package's calibrated look exactly.
///
/// Each dial maps to a safe internal range, so no combination can break the
/// flip's smoothness — at the flat rest state every material looks identical to
/// the page underneath it, so changing material never causes a pop.
///
/// ```dart
/// BookFlip(pages: pages, material: BookFlipMaterial.magazine);
///
/// // or tune your own:
/// BookFlip(
///   pages: pages,
///   material: const BookFlipMaterial(stiffness: 0.4, gloss: 0.8),
/// );
/// ```
@immutable
class BookFlipMaterial {
  /// Creates a paper material. Every value has a sensible default; override only
  /// the dials you care about.
  const BookFlipMaterial({
    this.stiffness = _kStiffness0,
    this.weight = 0.0,
    this.gloss = _kGloss0,
    this.translucency = 0.0,
    this.thickness = 1.0,
  })  : assert(stiffness >= 0 && stiffness <= 1, 'stiffness must be 0..1'),
        assert(weight >= 0 && weight <= 1, 'weight must be 0..1'),
        assert(gloss >= 0 && gloss <= 1, 'gloss must be 0..1'),
        assert(
          translucency >= 0 && translucency <= 1,
          'translucency must be 0..1',
        ),
        assert(thickness >= 0, 'thickness must be >= 0');

  /// How much the page resists bending. 0 is limp (curls tightly, like
  /// newsprint); 1 is rigid (stays nearly flat, like a board cover).
  final double stiffness;

  /// How much the free corner droops under its own weight while turning. 0 is
  /// weightless; 1 sags noticeably. Heavier usually pairs with lower [stiffness].
  final double weight;

  /// Surface shine. 0 is matte (no highlight); 1 is high-gloss, with a tight,
  /// bright glint when the page curves into the light.
  ///
  /// Above roughly 0.6 the page also takes on a smooth, bright **white coated
  /// gloss** — a compact "wet" highlight — on top of the glint, the
  /// way magazine stock catches the light. This coat is opt-in: it stays off for
  /// every matte and semigloss paper, so only a deliberately glossy material (e.g.
  /// [magazine]) shows it. Higher gloss also reads as smoother paper, with
  /// less visible grain, because the coating fills the tooth.
  final double gloss;

  /// How much light passes through thin paper. 0 is opaque; 1 lets the curled
  /// part glow softly, the way onionskin or newsprint does.
  final double translucency;

  /// The visual heft of the page edge, in logical pixels. Thicker pages show a
  /// heavier edge line and cast a firmer shadow. 0 is a hairline.
  final double thickness;

  /// Plain matte book paper — the calibrated reference stock.
  ///
  /// Bends easily with a soft satin sheen and **no** coated gloss (its gloss sits
  /// below the coat knee). This is the package default: a [BookFlip] given no
  /// `material` is made of exactly this paper, and every internal mapping is
  /// anchored to it, so it reproduces the engine's calibrated look exactly.
  static const BookFlipMaterial paper = BookFlipMaterial();

  /// Glossy coated magazine stock — the high-gloss alternative to [paper].
  ///
  /// A bright, tight glint plus the smooth white **coated gloss** (a compact
  /// "wet" highlight) over near-grainless, coating-filled paper. It is the only
  /// preset whose gloss clears the coat knee, so it is the one that shows the
  /// optional white gloss; see [gloss]. Slightly floppy and thin, the way real
  /// magazine pages turn.
  static const BookFlipMaterial magazine = BookFlipMaterial(
    stiffness: 0.42,
    weight: 0.32,
    gloss: 0.92,
    translucency: 0.12,
    thickness: 0.8,
  );

  /// A copy of this material with the given dials replaced.
  BookFlipMaterial copyWith({
    double? stiffness,
    double? weight,
    double? gloss,
    double? translucency,
    double? thickness,
  }) =>
      BookFlipMaterial(
        stiffness: stiffness ?? this.stiffness,
        weight: weight ?? this.weight,
        gloss: gloss ?? this.gloss,
        translucency: translucency ?? this.translucency,
        thickness: thickness ?? this.thickness,
      );

  /// Blends smoothly from [a] at t=0 to [b] at t=1. Use it to animate between
  /// materials (for example, a page slowly soaking and going limp). The endpoints
  /// are returned exactly.
  static BookFlipMaterial lerp(
      BookFlipMaterial a, BookFlipMaterial b, double t) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;
    return BookFlipMaterial(
      stiffness: _mix(a.stiffness, b.stiffness, t),
      weight: _mix(a.weight, b.weight, t),
      gloss: _mix(a.gloss, b.gloss, t),
      translucency: _mix(a.translucency, b.translucency, t),
      thickness: a.thickness + (b.thickness - a.thickness) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BookFlipMaterial &&
      other.stiffness == stiffness &&
      other.weight == weight &&
      other.gloss == gloss &&
      other.translucency == translucency &&
      other.thickness == thickness;

  @override
  int get hashCode =>
      Object.hash(stiffness, weight, gloss, translucency, thickness);
}

/// Direct control over the page-curve — the trajectory the turning leaf bends
/// through — independent of the paper [BookFlipMaterial].
///
/// Leave [BookFlip.curl] null (the default) to let the material decide the bend.
/// Provide one to take over: every dial is 0..1 and maps into the engine's safe
/// range, so no setting can break the flip's smoothness or its pop-free landing —
/// at the flat rest states the leaf stays identical to the page beneath it for ANY
/// curl, exactly as for any material. Its mid defaults give a balanced arc near the
/// default book's; for the exact material-derived arc, leave [BookFlip.curl] null.
/// Nudge a dial to reshape the turn.
///
/// Three ready-made curves — [gentle], [tight] and [floppy] — cover the common
/// feels; they vary the magnitude of the one developable arc (its depth, corner
/// fold and droop), not its underlying shape.
@immutable
class BookFlipCurl {
  /// Creates a page-curve. Every value has a sensible mid default; override only
  /// the dials you want to reshape.
  const BookFlipCurl({
    this.bend = 0.5,
    this.foldTilt = 0.5,
    this.droop = 0.0,
  })  : assert(bend >= 0 && bend <= 1, 'bend must be 0..1'),
        assert(foldTilt >= 0 && foldTilt <= 1, 'foldTilt must be 0..1'),
        assert(droop >= 0 && droop <= 1, 'droop must be 0..1');

  /// How tightly the page curls at mid-turn. 0 is a gentle, wide arc; 1 is a
  /// tight, deep curl.
  final double bend;

  /// How far the free corner folds diagonally across the page as it turns. 0 keeps
  /// the rows parallel; 1 is a pronounced corner fold.
  final double foldTilt;

  /// How much the free corner sags under its own weight while turning. 0 is
  /// weightless; 1 droops noticeably.
  final double droop;

  /// A soft, wide, shallow turn — a relaxed arc, the way a well-thumbed
  /// paperback falls open.
  static const BookFlipCurl gentle =
      BookFlipCurl(bend: 0.30, foldTilt: 0.35, droop: 0.05);

  /// A deep, tight curl with a crisp diagonal corner fold — a brisk turn.
  static const BookFlipCurl tight = BookFlipCurl(bend: 0.85, foldTilt: 0.48);

  /// A heavy, sagging turn whose free corner droops under its own weight, the
  /// way limp, weighty stock turns.
  static const BookFlipCurl floppy =
      BookFlipCurl(bend: 0.55, foldTilt: 0.45, droop: 0.90);

  /// A copy of this curve with the given dials replaced.
  BookFlipCurl copyWith({double? bend, double? foldTilt, double? droop}) =>
      BookFlipCurl(
        bend: bend ?? this.bend,
        foldTilt: foldTilt ?? this.foldTilt,
        droop: droop ?? this.droop,
      );

  /// Blends smoothly from [a] at t=0 to [b] at t=1 — animate a page slowly
  /// changing how it curls. The endpoints are returned exactly.
  static BookFlipCurl lerp(BookFlipCurl a, BookFlipCurl b, double t) {
    if (t <= 0.0) return a;
    if (t >= 1.0) return b;
    return BookFlipCurl(
      bend: a.bend + (b.bend - a.bend) * t,
      foldTilt: a.foldTilt + (b.foldTilt - a.foldTilt) * t,
      droop: a.droop + (b.droop - a.droop) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BookFlipCurl &&
      other.bend == bend &&
      other.foldTilt == foldTilt &&
      other.droop == droop;

  @override
  int get hashCode => Object.hash(bend, foldTilt, droop);
}

/// Which visual effects a [BookFlip] draws. Every effect is ON by default —
/// `const BookFlipEffects()` is the full calibrated look — so you turn things OFF
/// by setting a flag false, individually, with no effect on the others.
///
/// Turning an effect off never changes the geometry or the pop-free landing; it
/// only stops that one layer from drawing (or zeroes its shading contribution),
/// so a minimal/flat look is one flag away.
@immutable
class BookFlipEffects {
  /// Creates an effect set. Every flag defaults to true (the full look).
  const BookFlipEffects({
    this.gloss = true,
    this.grain = true,
    this.castShadow = true,
    this.spineShadow = true,
    this.edge = true,
    this.translucency = true,
  });

  /// Specular sheen and the optional coated white gloss (the highlight on the
  /// curling page). Off → no glint, no coat.
  final bool gloss;

  /// The curvature-gated paper-tooth grain (mottle and sparkle). Off → smooth.
  final bool grain;

  /// The soft drop shadow the lifting leaf casts on the page below. Off → none.
  final bool castShadow;

  /// The binding ambient-occlusion shadow in the spine valley. Off → flat spine.
  final bool spineShadow;

  /// The thin dark free-edge line that gives the page body. Off → no edge line.
  final bool edge;

  /// The thin-paper light-lift at the curl (onionskin glow). Off → opaque.
  final bool translucency;

  /// A copy of this set with the given flags replaced.
  BookFlipEffects copyWith({
    bool? gloss,
    bool? grain,
    bool? castShadow,
    bool? spineShadow,
    bool? edge,
    bool? translucency,
  }) =>
      BookFlipEffects(
        gloss: gloss ?? this.gloss,
        grain: grain ?? this.grain,
        castShadow: castShadow ?? this.castShadow,
        spineShadow: spineShadow ?? this.spineShadow,
        edge: edge ?? this.edge,
        translucency: translucency ?? this.translucency,
      );

  /// Every effect on — the full calibrated look, and the default.
  static const BookFlipEffects all = BookFlipEffects();

  @override
  bool operator ==(Object other) =>
      other is BookFlipEffects &&
      other.gloss == gloss &&
      other.grain == grain &&
      other.castShadow == castShadow &&
      other.spineShadow == spineShadow &&
      other.edge == edge &&
      other.translucency == translucency;

  @override
  int get hashCode => Object.hash(
        gloss,
        grain,
        castShadow,
        spineShadow,
        edge,
        translucency,
      );
}

// Default dials, named so the mappings below can anchor to them: at the default
// material every mapping returns the engine's calibrated constant exactly, which
// the test suite proves. Deviating a dial scales smoothly within a safe clamp.
const double _kStiffness0 = 0.62;
const double _kGloss0 = 0.34;

// Sensitivity + safe clamps for each derived value (tuning only).
const double _kBendSpan = 0.55, _kAmaxMin = 0.96, _kAmaxHi = 1.72;
const double _kTiltSpan = 0.55, _kTiltMin = 0.18, _kTiltHi = 0.42;
const double _kSheenSpan = 2.0, _kSheenHardCap = 0.30;
const double _kShinSpan = 1.7, _kShinMin = 6.0, _kShinMax = 80.0;
const double _kSagPeak =
    0.10; // free-corner droop, as a fraction of page height
const double _kTransPeak = 0.55; // thin-paper light-lift at the curl
const double _kToothGlossSpan =
    0.85; // matte (low gloss) reads toothier than glossy.
const double _kThickShadowSpan = 0.18, _kShadowHardCap = 0.66;
const double _kEdgeBaseWidth = 1.2;

double _mix(double a, double b, double t) => a + (b - a) * t;

/// Developable-bend amplitude for a material. Floppier (low stiffness) bends more.
double bookFlipAmax(BookFlipMaterial m) =>
    (kAmax * (1.0 + _kBendSpan * (_kStiffness0 - m.stiffness)))
        .clamp(_kAmaxMin, _kAmaxHi);

/// Per-row fold tilt for a material. Floppier pages fold their corners harder.
double bookFlipTilt(BookFlipMaterial m) =>
    (kTiltMax * (1.0 + _kTiltSpan * (_kStiffness0 - m.stiffness)))
        .clamp(_kTiltMin, _kTiltHi);

/// Peak free-corner droop for a material (0 for weightless stock).
double bookFlipSagAmp(BookFlipMaterial m) => m.weight * _kSagPeak;

/// Specular sheen strength for a material (always capped so it cannot blow out).
double bookFlipSheen(BookFlipMaterial m) =>
    (kSheen * (1.0 + _kSheenSpan * (m.gloss - _kGloss0)))
        .clamp(0.0, _kSheenHardCap);

/// Specular tightness for a material. Glossier pages give a smaller, sharper glint.
double bookFlipShininess(BookFlipMaterial m) =>
    (kShininess * (1.0 + _kShinSpan * (m.gloss - _kGloss0)))
        .clamp(_kShinMin, _kShinMax);

/// Thin-paper light-lift strength for a material (0 for opaque stock).
double bookFlipTranslucency(BookFlipMaterial m) => m.translucency * _kTransPeak;

/// Paper tooth (grain depth) for a material. Coated/glossy stock reads smoother —
/// the coating fills the tooth — while matte stock reads rougher. Anchored so the
/// default material returns [kTooth] exactly. Drives the curvature-gated grain in
/// `computeShading`, so it can never change the flat (rest/landing) appearance.
double bookFlipTooth(BookFlipMaterial m) =>
    (kTooth + _kToothGlossSpan * (_kGloss0 - m.gloss)).clamp(0.0, 1.0);

/// Coated white-gloss strength for a material: 0 for matte/semigloss stock,
/// ramping C1 (smoothstep) once gloss passes [kCoatKnee], so the bright smooth
/// white gloss is opt-in and reserved for magazine-tier paper (e.g.
/// [BookFlipMaterial.magazine]). 0 at the default material → the coat adds
/// nothing unless you choose a glossy one.
double bookFlipCoat(BookFlipMaterial m) =>
    bookSmoothstep01((m.gloss - kCoatKnee) / (1.0 - kCoatKnee));

/// Total additive-specular ceiling for a material: the matte sheen cap plus the
/// extra headroom a coat adds ([kCoatPeak]·coat). Equals [bookFlipSheen] (= [kSheen]
/// at the default) for any non-glossy paper, and rises for coated stock so the
/// white gloss can read bright while staying within a defined, testable bound.
double bookFlipSpecMax(BookFlipMaterial m) =>
    bookFlipSheen(m) + kCoatPeak * bookFlipCoat(m);

/// Cast-shadow umbra density for a material. Thicker pages cast a firmer shadow.
double bookFlipUmbra(BookFlipMaterial m) =>
    (kShadowMax * (1.0 + _kThickShadowSpan * (m.thickness - 1.0)))
        .clamp(0.0, _kShadowHardCap);

/// Free-edge line width for a material, in logical pixels.
double bookFlipEdgeWidth(BookFlipMaterial m) =>
    (_kEdgeBaseWidth * m.thickness).clamp(0.4, 6.0);

// ── CURVE TRAJECTORY (BookFlipCurl) → engine geometry ───────────────────────
// Each curl dial maps 0..1 into the SAME safe envelope the material path is
// clamped to, so a curl can never push the leaf outside the range the engine is
// already proven pop-free / NaN-free over. bend≈0.5, foldTilt≈0.5, droop=0
// reproduce the default book's geometry.

/// Developable-bend amplitude for a [BookFlipCurl.bend] dial.
double bookFlipCurlAmax(BookFlipCurl c) =>
    _kAmaxMin + (_kAmaxHi - _kAmaxMin) * c.bend;

/// Per-row fold tilt for a [BookFlipCurl.foldTilt] dial.
double bookFlipCurlTilt(BookFlipCurl c) =>
    _kTiltMin + (_kTiltHi - _kTiltMin) * c.foldTilt;

/// Free-corner droop for a [BookFlipCurl.droop] dial.
double bookFlipCurlSag(BookFlipCurl c) => _kSagPeak * c.droop;

/// Turns the pages of a [BookFlip] from code and reports its state.
///
/// Create one, pass it to [BookFlip.controller], then call [nextSpread],
/// [previousSpread], or [goToSpread]. It is a [ChangeNotifier], so you can
/// listen to mirror [currentSpread] or [flipProgress] in your own UI. A drag
/// always takes priority and can interrupt a code-driven flip.
///
/// Dispose the controller when you no longer need it.
class BookFlipController extends ChangeNotifier {
  /// Creates a controller, optionally opening at [initialSpread].
  BookFlipController({int initialSpread = 0}) : _initialSpread = initialSpread;

  final int _initialSpread;
  _BookFlipState? _state;

  /// The spread (open two-page view) shown at rest. Spread 0 is the first two
  /// pages.
  int get currentSpread => _state?._spread ?? _initialSpread;

  /// Total number of spreads in the book (pages shown two at a time). Useful for
  /// a "spread X of N" indicator. 0 until the book has loaded.
  int get totalSpreads => (_state?._pageCount ?? 0) ~/ 2;

  /// Whether a flip is in progress (dragging or animating).
  bool get isAnimating => _state?._scene.active ?? false;

  /// Progress of the current turn, 0 (flat) to 1 (turned). Stays 0 when idle.
  double get flipProgress => _state?._scene.t ?? 0.0;

  /// Turns to the next spread, if there is one. [velocity] is in turns/second.
  ///
  /// Returns true if a flip was started, or false on a no-op — already at the
  /// last spread, a flip already in progress, or the book not yet ready. Use the
  /// result (or [BookFlip.onFlipEnd]) to chain turns reliably.
  bool nextSpread({double velocity = 0.0}) =>
      _state?._driveFlip(1, velocity) ?? false;

  /// Turns back to the previous spread, if there is one. [velocity] is in
  /// turns/second. Returns true if a flip was started; false on a no-op (already
  /// at the first spread, a flip in progress, or not ready).
  bool previousSpread({double velocity = 0.0}) =>
      _state?._driveFlip(-1, velocity) ?? false;

  /// Jumps straight to [spread] with no animation — handy for restoring a saved
  /// position.
  void goToSpread(int spread) => _state?._jumpTo(spread);

  /// Total number of pages in the book (two per spread). 0 until it has loaded.
  int get totalPages => _state?._pageCount ?? 0;

  /// The 0-based index of the left-hand page of the current spread. Pair it with
  /// [totalPages] for a "page X of N" indicator (show `currentPage + 1`).
  int get currentPage => currentSpread * 2;

  /// Jumps straight to the spread that contains [page] (0-based), no animation.
  void goToPage(int page) => _state?._jumpTo(page ~/ 2);

  void _emit() => notifyListeners();
}

/// A realistic open-book page-flip widget.
///
/// Give it a list of already-decoded page images of equal size; it packs them
/// into a single texture and lets the user turn pages by dragging, or you drive
/// it with a [BookFlipController]. Two pages show at a time (a spread).
///
/// The images in [pages] belong to you: dispose them only after this widget is
/// gone, never before.
///
/// ```dart
/// BookFlip(
///   pages: myDecodedImages,
///   onSpreadChanged: (spread) => saveLastReadSpread(spread),
/// )
/// ```
class BookFlip extends StatefulWidget {
  /// Creates a book from a list of decoded [pages] (two or more, equal size).
  const BookFlip({
    required this.pages,
    super.key,
    this.controller,
    this.physics = const BookFlipPhysics(),
    this.material = BookFlipMaterial.paper,
    this.curl,
    this.effects = BookFlipEffects.all,
    this.fit = BookFit.contain,
    this.pageAspectRatio,
    this.maxTextureDimension = kPageTexMax,
    this.meshResolution = kNu,
    this.onSpreadChanged,
    this.onFlipStart,
    this.onFlipEnd,
    this.loadingBuilder,
    this.errorBuilder,
  })  : assert(pages.length >= 2, 'BookFlip needs at least 2 pages.'),
        assert(
          pageAspectRatio == null || pageAspectRatio > 0,
          'pageAspectRatio must be a positive width/height ratio.',
        ),
        assert(
          maxTextureDimension >= kPageTexMin,
          'maxTextureDimension must be >= $kPageTexMin; a smaller cap packs an '
          'unreadable atlas.',
        ),
        assert(
          meshResolution >= 8 && meshResolution <= 300,
          'meshResolution must be 8..300.',
        );

  /// Builds a book whose pages are ANY widgets — [Text], [RichText], images,
  /// icons, whole layouts — instead of pre-decoded images.
  ///
  /// Each of the [pageCount] pages is built by [pageBuilder], laid out at
  /// [pageSize], and rasterised to an image (at [pixelRatio], defaulting to the
  /// device pixel ratio so pages stay crisp) before the book is shown. Pages
  /// inherit the ambient [Directionality], [MediaQuery] and [Theme], so text and
  /// themed widgets render exactly as they would anywhere else. The captured
  /// images are owned and disposed for you — there is no `ui.Image` lifecycle to
  /// manage, unlike the default [BookFlip] constructor.
  ///
  /// Everything else (controller, physics, material, curl, effects, fit, callbacks,
  /// loading and error builders) behaves exactly as on the default constructor. Pass
  /// [pageLabel] to stamp a custom page number — `page` is 1-based, `total` is
  /// [pageCount] — onto every page; leave it null for none.
  ///
  /// ```dart
  /// BookFlip.builder(
  ///   pageCount: chapters.length,
  ///   pageSize: const Size(420, 560),
  ///   pageBuilder: (context, i) => ChapterPage(chapters[i]),
  /// )
  /// ```
  static Widget builder({
    required int pageCount,
    required Widget Function(BuildContext context, int pageIndex) pageBuilder,
    required Size pageSize,
    Key? key,
    double? pixelRatio,
    BookFlipController? controller,
    BookFlipPhysics physics = const BookFlipPhysics(),
    BookFlipMaterial material = BookFlipMaterial.paper,
    BookFlipCurl? curl,
    BookFlipEffects effects = BookFlipEffects.all,
    BookFit fit = BookFit.contain,
    int maxTextureDimension = kPageTexMax,
    int meshResolution = kNu,
    void Function(int spread)? onSpreadChanged,
    void Function(int spread, FlipDirection direction)? onFlipStart,
    void Function(int spread)? onFlipEnd,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? errorBuilder,
    Widget Function(BuildContext context, int page, int total)? pageLabel,
  }) {
    assert(pageCount >= 2, 'BookFlip.builder needs at least 2 pages.');
    assert(
      pageSize.width > 0 && pageSize.height > 0,
      'pageSize must be a positive width/height.',
    );
    assert(
      pixelRatio == null || pixelRatio > 0,
      'pixelRatio must be positive.',
    );
    assert(
      maxTextureDimension >= kPageTexMin,
      'maxTextureDimension must be >= $kPageTexMin; a smaller cap packs an '
      'unreadable atlas.',
    );
    assert(
      meshResolution >= 8 && meshResolution <= 300,
      'meshResolution must be 8..300.',
    );
    return _BookFlipWidgetPages(
      key: key,
      pageCount: pageCount,
      pageBuilder: pageBuilder,
      pageSize: pageSize,
      pixelRatio: pixelRatio,
      controller: controller,
      physics: physics,
      material: material,
      curl: curl,
      effects: effects,
      fit: fit,
      maxTextureDimension: maxTextureDimension,
      meshResolution: meshResolution,
      onSpreadChanged: onSpreadChanged,
      onFlipStart: onFlipStart,
      onFlipEnd: onFlipEnd,
      loadingBuilder: loadingBuilder,
      errorBuilder: errorBuilder,
      pageLabel: pageLabel,
    );
  }

  /// Like [BookFlip.builder], but for a list of widgets you already have. Each
  /// entry in [pages] becomes one page, laid out at [pageSize] and captured to an
  /// image. A thin convenience over [BookFlip.builder] — same owns-and-disposes
  /// behaviour, same options.
  static Widget widgets({
    required List<Widget> pages,
    required Size pageSize,
    Key? key,
    double? pixelRatio,
    BookFlipController? controller,
    BookFlipPhysics physics = const BookFlipPhysics(),
    BookFlipMaterial material = BookFlipMaterial.paper,
    BookFlipCurl? curl,
    BookFlipEffects effects = BookFlipEffects.all,
    BookFit fit = BookFit.contain,
    int maxTextureDimension = kPageTexMax,
    int meshResolution = kNu,
    void Function(int spread)? onSpreadChanged,
    void Function(int spread, FlipDirection direction)? onFlipStart,
    void Function(int spread)? onFlipEnd,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? errorBuilder,
    Widget Function(BuildContext context, int page, int total)? pageLabel,
  }) =>
      BookFlip.builder(
        key: key,
        pageCount: pages.length,
        pageBuilder: (context, index) => pages[index],
        pageSize: pageSize,
        pixelRatio: pixelRatio,
        controller: controller,
        physics: physics,
        material: material,
        curl: curl,
        effects: effects,
        fit: fit,
        maxTextureDimension: maxTextureDimension,
        meshResolution: meshResolution,
        onSpreadChanged: onSpreadChanged,
        onFlipStart: onFlipStart,
        onFlipEnd: onFlipEnd,
        loadingBuilder: loadingBuilder,
        errorBuilder: errorBuilder,
        pageLabel: pageLabel,
      );

  /// The page images, in reading order, all the same size.
  ///
  /// Pages are shown two at a time (a spread), so an even count is recommended —
  /// an odd final page has no partner and is not shown. To swap the content,
  /// pass a NEW list instance: the widget reloads on list-identity change, not on
  /// in-place edits of the same list. Very large books are packed into one
  /// texture, scaled down to fit [maxTextureDimension] (and the device's real
  /// GPU limit, discovered by retry), so a book always loads; the error builder
  /// appears only if even the smallest atlas cannot be created.
  final List<ui.Image> pages;

  /// Optional controller for turning pages from code and observing state.
  final BookFlipController? controller;

  /// How a released page settles. Defaults to a smooth, critically-damped feel.
  final BookFlipPhysics physics;

  /// The paper the pages are made of. Defaults to [BookFlipMaterial.paper] (the
  /// calibrated matte look); pass [BookFlipMaterial.magazine] for glossy coated
  /// stock, or build your own to change the feel.
  final BookFlipMaterial material;

  /// Optional direct control of the page-curve trajectory. Null (the default)
  /// lets [material] decide the bend; pass a [BookFlipCurl] to take over.
  final BookFlipCurl? curl;

  /// Which visual effects are drawn. Defaults to [BookFlipEffects.all] (the full
  /// look); pass a [BookFlipEffects] with flags off for a flatter/minimal book.
  final BookFlipEffects effects;

  /// How the book fits the space it is given. Defaults to [BookFit.contain],
  /// which keeps the pages' true shape and never distorts them; use
  /// [BookFit.fill] to stretch the book to fill its box.
  final BookFit fit;

  /// The width-to-height ratio of a single page, used to lay the book out.
  ///
  /// Leave this null (the default) to read it from the page images, so the book
  /// matches their shape automatically. Set it when you know the ratio up front —
  /// for example to keep a stable size while the images are still loading.
  final double? pageAspectRatio;

  /// The largest atlas-texture dimension, in pixels, the widget will request.
  ///
  /// All pages are packed into one texture; if it would exceed this size the
  /// pages are scaled down to fit. The default (4096) is safe on virtually all
  /// devices. Lower it for very old GPUs, or raise it on high-end hardware to
  /// keep more page resolution in large books.
  final int maxTextureDimension;

  /// Mesh smoothness — the number of columns across each page (rows scale to
  /// match). Higher is smoother on large or high-density screens but costs more
  /// per frame; the default (42) is tuned for phones, and the value is capped so
  /// the mesh fits a 16-bit index.
  final int meshResolution;

  /// Called whenever the resting spread changes — after a committed flip, or
  /// a [BookFlipController.goToSpread]/`goToPage` jump landing on a different
  /// spread. Not called for a spring-back (the spread did not change) or a
  /// `pages` reload (a content swap is not navigation).
  final void Function(int spread)? onSpreadChanged;

  /// Called the instant a flip begins, with the spread being left and the
  /// direction.
  final void Function(int spread, FlipDirection direction)? onFlipStart;

  /// Called once when a flip concludes — the single terminator that always
  /// balances [onFlipStart], so "in progress" is exactly the window between
  /// them. It fires after a committed turn, after a spring-back, and when a
  /// flip is cut short (a [BookFlipController.goToSpread] jump, or a `pages`
  /// reload mid-turn). The reported `spread` is where the book then rests: the
  /// new spread after a commit, the original after a spring-back, or the
  /// clamped spread it reopens on after an interruption. Not called if the
  /// widget is disposed mid-flip.
  final void Function(int spread)? onFlipEnd;

  /// Shown while the page texture is being prepared. Defaults to a spinner.
  final WidgetBuilder? loadingBuilder;

  /// Shown if preparing the page texture fails. Defaults to a tap-to-retry note.
  final WidgetBuilder? errorBuilder;

  @override
  State<BookFlip> createState() => _BookFlipState();
}
