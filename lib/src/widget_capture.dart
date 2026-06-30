part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Widget → ui.Image rasteriser. Turns arbitrary page WIDGETS (Text, RichText,
//  Image, Icon, whole subtrees) into the decoded images the atlas pipeline already
//  knows how to pack and flip — so a BookFlip built from widgets reuses the exact
//  same, already-proven mesh/atlas/shading path, with zero engine changes.
//
//  CAPTURE MECHANISM (deliberately the version-stable one): each page is mounted
//  inside the live BookFlip subtree wrapped in a RepaintBoundary and rasterised
//  with RenderRepaintBoundary.toImage. That API is stable across the whole
//  supported Flutter range (3.22 → current), unlike the off-tree RenderView/
//  ViewConfiguration pipeline whose constructor churned between versions. Mounting
//  in-tree also means each page inherits the ambient Directionality, MediaQuery,
//  DefaultTextStyle and Theme, so Text/TextSpan "just work" with no extra wiring.
//
//  The pages paint UNDER an opaque cover (the loading view), so they are captured
//  but never visible. They are painted (not Offstage / not Opacity-0, both of which
//  SKIP painting the child and would make toImage fail) — occlusion by a sibling
//  does not stop a child from painting, so the capture is reliable.
// ─────────────────────────────────────────────────────────────────────────────

/// Rasterises page [pages] to [ui.Image]s (via [RepaintBoundary.toImage]) so a
/// [BookFlip] can turn arbitrary widgets — text, rich text, images, whole
/// subtrees — exactly like decoded image pages.
///
/// Mounted hidden inside the BookFlip subtree during loading: each page inherits
/// the ambient [Directionality], [MediaQuery] and [Theme], renders at
/// [logicalSize], and is captured at [pixelRatio]× that size (so pages stay crisp
/// on high-density screens). [onCaptured] fires once with the decoded images, in
/// page order; the caller then owns and must dispose them.
///
/// This is package-internal (not exported); it is annotated [visibleForTesting]
/// only so the package's own tests can drive the capture directly.
@visibleForTesting
class BookFlipPageRasterizer extends StatefulWidget {
  /// Creates a hidden rasteriser that captures [pages] at [logicalSize] (scaled by
  /// [pixelRatio]) and reports the decoded images to [onCaptured].
  const BookFlipPageRasterizer({
    required this.pages,
    required this.logicalSize,
    required this.onCaptured,
    this.pixelRatio = 1.0,
    this.cover = const SizedBox.expand(),
    this.onError,
    super.key,
  });

  /// The page contents, in reading order. Each becomes one [ui.Image].
  final List<Widget> pages;

  /// The logical size each page is laid out at before capture. The resulting
  /// image is [logicalSize] × [pixelRatio] pixels.
  final Size logicalSize;

  /// Called once with the decoded page images, in order. The receiver owns them
  /// and is responsible for disposing them.
  final void Function(List<ui.Image> images) onCaptured;

  /// Called if capture fails (e.g. GPU OOM) instead of throwing, so the host can
  /// show an error/retry UI rather than leaving a dead loading cover. When null, a
  /// capture failure rethrows (the original behaviour, used by the test harness).
  final void Function(Object error, StackTrace stack)? onError;

  /// Resolution multiplier applied at capture time. Pass the device pixel ratio
  /// (or more) for crisp pages on high-density screens.
  final double pixelRatio;

  /// Painted on top of the (hidden) capture layer while rasterising — typically
  /// the loading view, so the user never sees the pages being captured.
  final Widget cover;

  @override
  State<BookFlipPageRasterizer> createState() => _BookFlipPageRasterizerState();
}

class _BookFlipPageRasterizerState extends State<BookFlipPageRasterizer> {
  late final List<GlobalKey> _keys = List<GlobalKey>.generate(
    widget.pages.length,
    (_) => GlobalKey(),
    growable: false,
  );
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    // Capture AFTER the first frame is painted (post-frame), so every boundary's
    // layer exists. A handful of retries covers the rare not-yet-laid-out frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture([int attempt = 0]) async {
    if (_captured || !mounted) return;
    final boundaries = <RenderRepaintBoundary>[];
    for (final key in _keys) {
      final object = key.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary) {
        // Not laid out yet — try again next frame, then give up rather than spin.
        if (attempt < 5) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _capture(attempt + 1));
        }
        return;
      }
      boundaries.add(object);
    }
    final images = <ui.Image>[];
    try {
      for (final boundary in boundaries) {
        images.add(await boundary.toImage(pixelRatio: widget.pixelRatio));
      }
    } on Object catch (error, stack) {
      for (final image in images) {
        image.dispose(); // never leak a partial capture
      }
      final onError = widget.onError;
      if (onError != null) {
        onError(error, stack); // host shows retry UI — never a dead cover
        return;
      }
      rethrow;
    }
    if (!mounted) {
      for (final image in images) {
        image.dispose();
      }
      return;
    }
    _captured = true;
    widget.onCaptured(images);
  }

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final size = widget.logicalSize;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        for (var i = 0; i < widget.pages.length; i++)
          Positioned(
            left: 0,
            top: 0,
            width: size.width,
            height: size.height,
            child: RepaintBoundary(
              key: _keys[i],
              child: Directionality(
                textDirection: direction,
                child: widget.pages[i],
              ),
            ),
          ),
        Positioned.fill(child: widget.cover),
      ],
    );
  }
}
