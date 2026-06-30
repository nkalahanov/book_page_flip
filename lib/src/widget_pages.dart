part of 'engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Widget pages → BookFlip.  Public entry point: [BookFlip.builder] (api.dart)
//  returns one of these.  It rasterises each page WIDGET to a ui.Image with the
//  already-proven [BookFlipPageRasterizer], OWNS the resulting images, then hands
//  them to an ordinary [BookFlip] — so widget pages reuse the EXACT same mesh /
//  atlas / flip engine with ZERO engine changes (geometry, rendering, scene and
//  the state hot path are untouched; they only ever see decoded images).
//
//  The captured images live exactly as long as this wrapper: re-captured when the
//  page definition changes, disposed on reconfigure and on teardown — so the
//  consumer never touches a ui.Image lifecycle (the disposal footgun of the raw
//  List<ui.Image> constructor simply does not exist on this path).
// ─────────────────────────────────────────────────────────────────────────────
class _BookFlipWidgetPages extends StatefulWidget {
  const _BookFlipWidgetPages({
    required this.pageCount,
    required this.pageBuilder,
    required this.pageSize,
    required this.pixelRatio,
    required this.controller,
    required this.physics,
    required this.material,
    required this.curl,
    required this.effects,
    required this.fit,
    required this.maxTextureDimension,
    required this.meshResolution,
    required this.onSpreadChanged,
    required this.onFlipStart,
    required this.onFlipEnd,
    required this.loadingBuilder,
    required this.errorBuilder,
    required this.pageLabel,
    super.key,
  });

  final int pageCount;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Size pageSize;
  final double? pixelRatio;
  final BookFlipController? controller;
  final BookFlipPhysics physics;
  final BookFlipMaterial material;
  final BookFlipCurl? curl;
  final BookFlipEffects effects;
  final BookFit fit;
  final int maxTextureDimension;
  final int meshResolution;
  final void Function(int spread)? onSpreadChanged;
  final void Function(int spread, FlipDirection direction)? onFlipStart;
  final void Function(int spread)? onFlipEnd;
  final WidgetBuilder? loadingBuilder;
  final WidgetBuilder? errorBuilder;
  final Widget Function(BuildContext context, int page, int total)? pageLabel;

  @override
  State<_BookFlipWidgetPages> createState() => _BookFlipWidgetPagesState();
}

class _BookFlipWidgetPagesState extends State<_BookFlipWidgetPages> {
  // The captured page images. Non-null once rasterisation completes; OWNED here
  // (disposed on reconfigure and teardown) so the consumer never manages them.
  List<ui.Image>? _images;
  // Set if a capture fails → build() shows the retry UI instead of a dead cover.
  Object? _captureError;
  // Bumped on any capture-affecting change; keys the rasteriser so a reconfigure
  // (even mid-capture) remounts it fresh and abandons the stale in-flight capture.
  int _epoch = 0;

  void _disposeImages() {
    final imgs = _images;
    if (imgs != null) {
      for (final img in imgs) {
        img.dispose();
      }
    }
  }

  @override
  void didUpdateWidget(_BookFlipWidgetPages old) {
    super.didUpdateWidget(old);
    // Any change to WHAT or HOW we capture → drop the stale capture and start over.
    final changed = old.pageCount != widget.pageCount ||
        old.pageSize != widget.pageSize ||
        old.pixelRatio != widget.pixelRatio ||
        !identical(old.pageBuilder, widget.pageBuilder) ||
        !identical(old.pageLabel, widget.pageLabel);
    if (changed) {
      _disposeImages();
      setState(() {
        _images = null; // null → re-enter the capture branch
        _captureError = null;
        _epoch++; // remount the rasteriser at the new configuration
      });
    }
  }

  @override
  void dispose() {
    _disposeImages();
    super.dispose();
  }

  void _onCaptured(List<ui.Image> images) {
    if (!mounted) {
      // Capture finished after we were removed → never leak it.
      for (final img in images) {
        img.dispose();
      }
      return;
    }
    setState(() => _images = images);
  }

  void _onCaptureError(Object error, StackTrace stack) {
    if (!mounted) return;
    setState(() => _captureError = error);
  }

  void _retryCapture() {
    setState(() {
      _captureError = null;
      _epoch++; // fresh rasteriser → a new capture attempt
    });
  }

  @override
  Widget build(BuildContext context) {
    final images = _images;
    if (images != null) {
      // Captured → an ordinary BookFlip, engine untouched. We own [images] and
      // outlive the book, so the book is left on its default "caller owns" footing
      // and we dispose them ourselves in [dispose].
      return BookFlip(
        pages: images,
        controller: widget.controller,
        physics: widget.physics,
        material: widget.material,
        curl: widget.curl,
        effects: widget.effects,
        fit: widget.fit,
        pageAspectRatio: widget.pageSize.height > 0
            ? widget.pageSize.width / widget.pageSize.height
            : null,
        maxTextureDimension: widget.maxTextureDimension,
        meshResolution: widget.meshResolution,
        onSpreadChanged: widget.onSpreadChanged,
        onFlipStart: widget.onFlipStart,
        onFlipEnd: widget.onFlipEnd,
        loadingBuilder: widget.loadingBuilder,
        errorBuilder: widget.errorBuilder,
      );
    }
    // Capture failed (e.g. GPU OOM) → the same tap-to-retry UI as the book's own
    // boot error, never a dead loading cover.
    if (_captureError != null) {
      return widget.errorBuilder?.call(context) ??
          _BookErrorView(onRetry: _retryCapture);
    }
    // Not captured yet → rasterise every page widget at [pageSize], hidden under
    // the loading cover; [_onCaptured] then swaps us to the real book. The rasteriser
    // is keyed by [_epoch] so any reconfigure remounts it fresh (correct page count,
    // new capture) instead of reusing a stale, wrong-length capture state.
    final ratio = widget.pixelRatio ?? MediaQuery.devicePixelRatioOf(context);
    return BookFlipPageRasterizer(
      key: ValueKey<int>(_epoch),
      pixelRatio: ratio,
      logicalSize: widget.pageSize,
      cover: widget.loadingBuilder?.call(context) ?? const _BookLoadingView(),
      onCaptured: _onCaptured,
      onError: _onCaptureError,
      pages: <Widget>[
        for (var i = 0; i < widget.pageCount; i++)
          Builder(builder: (context) => _composePage(context, i)),
      ],
    );
  }

  // One page widget, with the optional page-number label composited on top — baked
  // into the capture, so numeration costs the engine nothing. The label widget
  // self-positions (wrap it in Align/Positioned). [page] passed out is 1-based.
  Widget _composePage(BuildContext context, int index) {
    final page = widget.pageBuilder(context, index);
    final label = widget.pageLabel?.call(context, index + 1, widget.pageCount);
    if (label == null) {
      return page;
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[page, label],
    );
  }
}
