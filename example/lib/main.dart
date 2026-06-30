// Visual stress / QA lab for the book_page_flip package.
//
// Launch it and exercise every dimension that could produce a visual artifact —
// content type, page count, fit, paper dials, curl trajectory, each effect, pixel
// ratio, the atlas TEXTURE CAP (maxTextureDimension), the MESH resolution
// (meshResolution — reopens the book at the same spread via a fresh controller
// seeded with initialSpread), page labels — while watching the live book. The
// "Grid" content makes any mesh distortion, seam or mirroring obvious; "Auto-flip"
// stress-tests continuous turning and mid-flip interrupts; a page scrubber drives
// goToPage; the diagnostics bar reports the live position and turn progress.
//
//   flutter run -d macos      (native desktop window)
//   flutter run -d chrome     (browser)
//
// Structure: a single immutable [_Config] is the source of truth; the control
// panel emits edited configs and the book reads them. There are no widget-returning
// helper methods — every piece of UI is its own widget. The page builder is
// memoised ([_pageBuilder]) and only re-created when the CONTENT changes, so paper,
// curl, effect and fit changes reconfigure the book live without re-capturing it.
import 'dart:async';

import 'package:book_page_flip/book_page_flip.dart';
import 'package:flutter/material.dart';

void main() => runApp(const StressLabApp());

/// Root of the stress lab.
class StressLabApp extends StatelessWidget {
  /// Creates the app.
  const StressLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'book_page_flip stress lab',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C4AB6),
          brightness: Brightness.dark,
        ),
      ),
      home: const _StressLab(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Screen — owns the controller, the live config, and the auto-flip driver.
// ─────────────────────────────────────────────────────────────────────────────

class _StressLab extends StatefulWidget {
  const _StressLab();

  @override
  State<_StressLab> createState() => _StressLabState();
}

class _StressLabState extends State<_StressLab> {
  BookFlipController _controller = BookFlipController();
  _Config _config = const _Config();

  // Memoised page builder: a stable reference so paper/curl/effect/fit edits
  // reconfigure the book WITHOUT a re-capture. Re-created only when the content
  // mode changes (which must re-capture), in [_applyConfig].
  late Widget Function(BuildContext, int) _pageBuilder;

  Timer? _autoTimer;
  int _autoDir = 1;
  bool _autoFlip = false;

  @override
  void initState() {
    super.initState();
    _rebuildPageBuilder(_config.content);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _rebuildPageBuilder(_ContentMode mode) {
    _pageBuilder = (context, index) => _StressPage(mode: mode, index: index);
  }

  void _applyConfig(_Config next) {
    // Content and the atlas texture cap are baked in at capture/boot time, so a
    // change to either re-creates the page builder to force a fresh capture.
    if (next.content != _config.content ||
        next.maxTextureDimension != _config.maxTextureDimension) {
      _rebuildPageBuilder(next.content);
    }
    setState(() => _config = next);
  }

  // Mesh tessellation is read once, at the book's initState, so changing it
  // reopens the book: a fresh controller seeded at the current spread
  // (initialSpread) re-attaches to the State the new ValueKey forces to rebuild.
  void _applyMeshResolution(int mesh) {
    if (mesh == _config.meshResolution) return;
    final keep = _controller.currentSpread;
    _controller.dispose();
    _controller = BookFlipController(initialSpread: keep);
    setState(() => _config = _config.copyWith(meshResolution: mesh));
  }

  void _toggleAutoFlip(bool on) {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (on) {
      _autoTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) {
        final total = _controller.totalSpreads;
        if (total <= 1) return;
        final spread = _controller.currentSpread;
        if (spread <= 0) {
          _autoDir = 1;
        } else if (spread >= total - 1) {
          _autoDir = -1;
        }
        if (_autoDir > 0) {
          _controller.nextSpread();
        } else {
          _controller.previousSpread();
        }
      });
    }
    setState(() => _autoFlip = on);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14111B),
      appBar: AppBar(
        title: const Text('book_page_flip · visual stress lab'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stage = Column(
              children: <Widget>[
                _DiagnosticsBar(controller: _controller),
                Expanded(
                  child: _BookStage(
                    config: _config,
                    controller: _controller,
                    pageBuilder: _pageBuilder,
                  ),
                ),
                _ActionBar(
                  controller: _controller,
                  autoFlip: _autoFlip,
                  onAutoFlip: _toggleAutoFlip,
                ),
              ],
            );
            final panel = _ControlPanel(
              config: _config,
              onChanged: _applyConfig,
              onMeshResolution: _applyMeshResolution,
            );
            if (constraints.maxWidth >= 900) {
              return Row(
                children: <Widget>[
                  Expanded(child: stage),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 380, child: panel),
                ],
              );
            }
            return Column(
              children: <Widget>[
                Expanded(flex: 5, child: stage),
                const Divider(height: 1),
                Expanded(flex: 6, child: panel),
              ],
            );
          },
        ),
      ),
    );
  }
}

// Top-level (stable identity) so toggling labels is the only thing that swaps it
// null↔function and re-captures. `total` is unused; the pill shows just the page.
Widget _labelAt(BuildContext context, int page, int total) =>
    _PageLabel(page: page);

// ─────────────────────────────────────────────────────────────────────────────
//  Config — one immutable source of truth for every book knob.
// ─────────────────────────────────────────────────────────────────────────────

enum _ContentMode {
  numbered('Numbered'),
  grid('Grid'),
  chapters('Chapters');

  const _ContentMode(this.label);
  final String label;
}

enum _MaterialPreset {
  paper('Paper'),
  magazine('Magazine'),
  custom('Custom');

  const _MaterialPreset(this.label);
  final String label;
}

@immutable
class _Config {
  const _Config({
    this.content = _ContentMode.numbered,
    this.pageCount = 8,
    this.fit = BookFit.contain,
    this.preset = _MaterialPreset.paper,
    this.stiffness = 0.62,
    this.weight = 0.0,
    this.gloss = 0.34,
    this.translucency = 0.0,
    this.thickness = 1.0,
    this.useCurl = false,
    this.bend = 0.5,
    this.foldTilt = 0.5,
    this.droop = 0.0,
    this.effects = BookFlipEffects.all,
    this.pixelRatio = 2.0,
    this.maxTextureDimension = 4096,
    this.meshResolution = 42,
    this.showLabels = true,
  });

  final _ContentMode content;
  final int pageCount;
  final BookFit fit;
  final _MaterialPreset preset;
  final double stiffness;
  final double weight;
  final double gloss;
  final double translucency;
  final double thickness;
  final bool useCurl;
  final double bend;
  final double foldTilt;
  final double droop;
  final BookFlipEffects effects;
  final double pixelRatio;
  final int maxTextureDimension;
  final int meshResolution;
  final bool showLabels;

  BookFlipMaterial get material => switch (preset) {
        _MaterialPreset.paper => BookFlipMaterial.paper,
        _MaterialPreset.magazine => BookFlipMaterial.magazine,
        _MaterialPreset.custom => BookFlipMaterial(
            stiffness: stiffness,
            weight: weight,
            gloss: gloss,
            translucency: translucency,
            thickness: thickness,
          ),
      };

  BookFlipCurl? get curl => useCurl
      ? BookFlipCurl(bend: bend, foldTilt: foldTilt, droop: droop)
      : null;

  _Config copyWith({
    _ContentMode? content,
    int? pageCount,
    BookFit? fit,
    _MaterialPreset? preset,
    double? stiffness,
    double? weight,
    double? gloss,
    double? translucency,
    double? thickness,
    bool? useCurl,
    double? bend,
    double? foldTilt,
    double? droop,
    BookFlipEffects? effects,
    double? pixelRatio,
    int? maxTextureDimension,
    int? meshResolution,
    bool? showLabels,
  }) =>
      _Config(
        content: content ?? this.content,
        pageCount: pageCount ?? this.pageCount,
        fit: fit ?? this.fit,
        preset: preset ?? this.preset,
        stiffness: stiffness ?? this.stiffness,
        weight: weight ?? this.weight,
        gloss: gloss ?? this.gloss,
        translucency: translucency ?? this.translucency,
        thickness: thickness ?? this.thickness,
        useCurl: useCurl ?? this.useCurl,
        bend: bend ?? this.bend,
        foldTilt: foldTilt ?? this.foldTilt,
        droop: droop ?? this.droop,
        effects: effects ?? this.effects,
        pixelRatio: pixelRatio ?? this.pixelRatio,
        maxTextureDimension: maxTextureDimension ?? this.maxTextureDimension,
        meshResolution: meshResolution ?? this.meshResolution,
        showLabels: showLabels ?? this.showLabels,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  The book under test.
// ─────────────────────────────────────────────────────────────────────────────

class _BookStage extends StatelessWidget {
  const _BookStage({
    required this.config,
    required this.controller,
    required this.pageBuilder,
  });

  final _Config config;
  final BookFlipController controller;
  final Widget Function(BuildContext, int) pageBuilder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: BookFlip.builder(
        key: ValueKey<int>(config.meshResolution),
        controller: controller,
        pageCount: config.pageCount,
        pageSize: const Size(360, 500),
        pixelRatio: config.pixelRatio,
        maxTextureDimension: config.maxTextureDimension,
        meshResolution: config.meshResolution,
        material: config.material,
        curl: config.curl,
        effects: config.effects,
        fit: config.fit,
        pageBuilder: pageBuilder,
        pageLabel: config.showLabels ? _labelAt : null,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Diagnostics + actions — driven by the controller, no mirror state.
// ─────────────────────────────────────────────────────────────────────────────

class _DiagnosticsBar extends StatelessWidget {
  const _DiagnosticsBar({required this.controller});

  final BookFlipController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final total = controller.totalSpreads;
        final String text;
        if (total > 0) {
          final cp = controller.currentPage;
          final tp = controller.totalPages;
          final right = cp + 2 <= tp ? cp + 2 : tp;
          text = 'spread ${controller.currentSpread + 1}/$total   ·   '
              'pages ${cp + 1}–$right of $tp   ·   '
              't=${controller.flipProgress.toStringAsFixed(2)}   ·   '
              '${controller.isAnimating ? 'FLIPPING' : 'idle'}';
        } else {
          text = 'opening…';
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          color: Colors.black.withAlpha(60),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        );
      },
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.autoFlip,
    required this.onAutoFlip,
  });

  final BookFlipController controller;
  final bool autoFlip;
  final ValueChanged<bool> onAutoFlip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final total = controller.totalSpreads;
          final spread = controller.currentSpread;
          final ready = total > 0;
          final canBack = ready && spread > 0;
          final canForward = ready && spread < total - 1;
          final tp = controller.totalPages;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _NavButton(
                    icon: Icons.first_page,
                    onPressed: canBack ? () => controller.goToSpread(0) : null,
                  ),
                  _NavButton(
                    icon: Icons.chevron_left,
                    onPressed:
                        canBack ? () => controller.previousSpread() : null,
                  ),
                  _NavButton(
                    icon: Icons.chevron_right,
                    onPressed:
                        canForward ? () => controller.nextSpread() : null,
                  ),
                  _NavButton(
                    icon: Icons.last_page,
                    onPressed: canForward
                        ? () => controller.goToSpread(total - 1)
                        : null,
                  ),
                  FilterChip(
                    avatar: const Icon(Icons.all_inclusive, size: 18),
                    label: const Text('Auto-flip'),
                    selected: autoFlip,
                    onSelected: onAutoFlip,
                  ),
                ],
              ),
              if (tp > 1)
                _CommitSlider(
                  label: 'go to page',
                  value: (controller.currentPage + 1).toDouble(),
                  min: 1,
                  max: tp.toDouble(),
                  divisions: tp - 1,
                  onCommit: (v) => controller.goToPage(v.round() - 1),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      iconSize: 26,
      icon: Icon(icon),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Control panel — pure config editing; emits new configs via copyWith.
// ─────────────────────────────────────────────────────────────────────────────

class _ControlPanel extends StatelessWidget {
  const _ControlPanel({
    required this.config,
    required this.onChanged,
    required this.onMeshResolution,
  });

  final _Config config;
  final ValueChanged<_Config> onChanged;
  final ValueChanged<int> onMeshResolution;

  @override
  Widget build(BuildContext context) {
    final effects = config.effects;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        _Section(
          title: 'CONTENT',
          child: SegmentedButton<_ContentMode>(
            showSelectedIcon: false,
            segments: <ButtonSegment<_ContentMode>>[
              for (final mode in _ContentMode.values)
                ButtonSegment<_ContentMode>(
                    value: mode, label: Text(mode.label)),
            ],
            selected: <_ContentMode>{config.content},
            onSelectionChanged: (s) =>
                onChanged(config.copyWith(content: s.first)),
          ),
        ),
        _Section(
          title: 'PAGES — ${config.pageCount}'
              '${config.pageCount.isOdd ? '  (odd: last page unpaired)' : ''}',
          child: _BareSlider(
            value: config.pageCount.toDouble(),
            min: 2,
            max: 30,
            divisions: 28,
            onChanged: (v) => onChanged(config.copyWith(pageCount: v.round())),
          ),
        ),
        _Section(
          title: 'FIT',
          child: SegmentedButton<BookFit>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<BookFit>>[
              ButtonSegment<BookFit>(
                  value: BookFit.contain, label: Text('Contain')),
              ButtonSegment<BookFit>(value: BookFit.fill, label: Text('Fill')),
            ],
            selected: <BookFit>{config.fit},
            onSelectionChanged: (s) => onChanged(config.copyWith(fit: s.first)),
          ),
        ),
        _Section(
          title: 'PIXEL RATIO',
          child: _LabeledSlider(
            label: 'capture density',
            value: config.pixelRatio,
            min: 1,
            max: 3,
            divisions: 8,
            onChanged: (v) => onChanged(config.copyWith(pixelRatio: v)),
          ),
        ),
        _Section(
          title: 'TEXTURE CAP — ${config.maxTextureDimension}px atlas',
          child: _CommitSlider(
            label: 'max texture',
            value: config.maxTextureDimension.toDouble(),
            min: 256,
            max: 4096,
            divisions: 15,
            onCommit: (v) =>
                onChanged(config.copyWith(maxTextureDimension: v.round())),
          ),
        ),
        _Section(
          title: 'MESH — ${config.meshResolution} cols (reopens the book)',
          child: _CommitSlider(
            label: 'tessellation',
            value: config.meshResolution.toDouble(),
            min: 8,
            max: 300,
            divisions: 292,
            onCommit: (v) => onMeshResolution(v.round()),
          ),
        ),
        _ToggleTile(
          label: 'Page labels',
          value: config.showLabels,
          onChanged: (v) => onChanged(config.copyWith(showLabels: v)),
        ),
        _Section(
          title: 'PAPER',
          child: SegmentedButton<_MaterialPreset>(
            showSelectedIcon: false,
            segments: <ButtonSegment<_MaterialPreset>>[
              for (final preset in _MaterialPreset.values)
                ButtonSegment<_MaterialPreset>(
                    value: preset, label: Text(preset.label)),
            ],
            selected: <_MaterialPreset>{config.preset},
            onSelectionChanged: (s) =>
                onChanged(config.copyWith(preset: s.first)),
          ),
        ),
        if (config.preset == _MaterialPreset.custom) ...<Widget>[
          _LabeledSlider(
            label: 'stiffness',
            value: config.stiffness,
            onChanged: (v) => onChanged(config.copyWith(stiffness: v)),
          ),
          _LabeledSlider(
            label: 'weight',
            value: config.weight,
            onChanged: (v) => onChanged(config.copyWith(weight: v)),
          ),
          _LabeledSlider(
            label: 'gloss',
            value: config.gloss,
            onChanged: (v) => onChanged(config.copyWith(gloss: v)),
          ),
          _LabeledSlider(
            label: 'translucency',
            value: config.translucency,
            onChanged: (v) => onChanged(config.copyWith(translucency: v)),
          ),
          _LabeledSlider(
            label: 'thickness',
            value: config.thickness,
            min: 0,
            max: 3,
            onChanged: (v) => onChanged(config.copyWith(thickness: v)),
          ),
        ],
        _ToggleTile(
          label: 'Override page-curve (curl)',
          value: config.useCurl,
          onChanged: (v) => onChanged(config.copyWith(useCurl: v)),
        ),
        if (config.useCurl) ...<Widget>[
          _LabeledSlider(
            label: 'bend',
            value: config.bend,
            onChanged: (v) => onChanged(config.copyWith(bend: v)),
          ),
          _LabeledSlider(
            label: 'fold tilt',
            value: config.foldTilt,
            onChanged: (v) => onChanged(config.copyWith(foldTilt: v)),
          ),
          _LabeledSlider(
            label: 'droop',
            value: config.droop,
            onChanged: (v) => onChanged(config.copyWith(droop: v)),
          ),
        ],
        _Section(
          title: 'EFFECTS',
          child: Column(
            children: <Widget>[
              _ToggleTile(
                label: 'Gloss',
                value: effects.gloss,
                onChanged: (v) => onChanged(
                    config.copyWith(effects: effects.copyWith(gloss: v))),
              ),
              _ToggleTile(
                label: 'Grain',
                value: effects.grain,
                onChanged: (v) => onChanged(
                    config.copyWith(effects: effects.copyWith(grain: v))),
              ),
              _ToggleTile(
                label: 'Cast shadow',
                value: effects.castShadow,
                onChanged: (v) => onChanged(
                    config.copyWith(effects: effects.copyWith(castShadow: v))),
              ),
              _ToggleTile(
                label: 'Spine shadow',
                value: effects.spineShadow,
                onChanged: (v) => onChanged(
                    config.copyWith(effects: effects.copyWith(spineShadow: v))),
              ),
              _ToggleTile(
                label: 'Edge line',
                value: effects.edge,
                onChanged: (v) => onChanged(
                    config.copyWith(effects: effects.copyWith(edge: v))),
              ),
              _ToggleTile(
                label: 'Translucency',
                value: effects.translucency,
                onChanged: (v) => onChanged(config.copyWith(
                    effects: effects.copyWith(translucency: v))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _BareSlider extends StatelessWidget {
  const _BareSlider({
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    required this.divisions,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int divisions;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      label: value.round().toString(),
      onChanged: onChanged,
    );
  }
}

// A slider that reports only on release: it tracks the drag locally so the value
// stays smooth, but fires [onCommit] once — used for the costly knobs (texture
// cap re-captures; mesh resolution reopens the book) so a drag does not thrash.
class _CommitSlider extends StatefulWidget {
  const _CommitSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onCommit,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onCommit;

  @override
  State<_CommitSlider> createState() => _CommitSliderState();
}

class _CommitSliderState extends State<_CommitSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = (_drag ?? widget.value).clamp(widget.min, widget.max);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 96,
          child: Text(widget.label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: shown,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: shown.round().toString(),
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) {
              setState(() => _drag = null);
              widget.onCommit(v);
            },
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            shown.round().toString(),
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Page content — three modes, each a plain widget the book rasterises.
// ─────────────────────────────────────────────────────────────────────────────

class _StressPage extends StatelessWidget {
  const _StressPage({required this.mode, required this.index});

  final _ContentMode mode;
  final int index;

  @override
  Widget build(BuildContext context) => switch (mode) {
        _ContentMode.numbered => _NumberedPage(index: index),
        _ContentMode.grid => _GridPage(index: index),
        _ContentMode.chapters =>
          _LeafView(leaf: _leaves[index % _leaves.length]),
      };
}

// Big cycling-hue number — easy to track page identity and spot colour blinks.
class _NumberedPage extends StatelessWidget {
  const _NumberedPage({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final hue = (index * 47.0) % 360.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            HSVColor.fromAHSV(1, hue, 0.55, 0.52).toColor(),
            HSVColor.fromAHSV(1, (hue + 24) % 360, 0.70, 0.30).toColor(),
          ],
        ),
      ),
      child: Center(
        child: Text(
          '${index + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 120,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

// Ruled grid + corner tags — exposes mesh distortion, seams and mirroring.
class _GridPage extends StatelessWidget {
  const _GridPage({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final hue = (index * 47.0) % 360.0;
    return ColoredBox(
      color: HSVColor.fromAHSV(1, hue, 0.16, 0.97).toColor(),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const GridPaper(color: Colors.black26, interval: 60, subdivisions: 1),
          const _CornerTag(alignment: Alignment.topLeft, text: 'TL'),
          const _CornerTag(alignment: Alignment.topRight, text: 'TR'),
          const _CornerTag(alignment: Alignment.bottomLeft, text: 'BL'),
          const _CornerTag(alignment: Alignment.bottomRight, text: 'BR'),
          Center(
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: Colors.black.withAlpha(120),
                fontSize: 72,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CornerTag extends StatelessWidget {
  const _CornerTag({required this.alignment, required this.text});

  final AlignmentGeometry alignment;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.black54,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _PageLabel extends StatelessWidget {
  const _PageLabel({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(70),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            child: Text(
              '$page',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Realistic widget-page content for the "Chapters" mode.
// ─────────────────────────────────────────────────────────────────────────────

class _LeafView extends StatelessWidget {
  const _LeafView({required this.leaf});

  final _Leaf leaf;

  static const Color _paper = Color(0xFFF7F1E6);
  static const Color _ink = Color(0xFF2A2520);
  static const Color _bodyInk = Color(0xFF4A4136);

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _paper,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(30, 34, 30, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _LeafHeader(leaf: leaf),
            const SizedBox(height: 24),
            Text(
              leaf.title,
              style: const TextStyle(
                color: _ink,
                fontSize: 30,
                height: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Text(
                leaf.body,
                style: const TextStyle(
                  color: _bodyInk,
                  fontSize: 16,
                  height: 1.55,
                ),
              ),
            ),
            _LeafRule(color: leaf.accent),
          ],
        ),
      ),
    );
  }
}

class _LeafHeader extends StatelessWidget {
  const _LeafHeader({required this.leaf});

  final _Leaf leaf;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: leaf.accent.withAlpha(38),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(leaf.icon, color: leaf.accent, size: 24),
        ),
        const SizedBox(width: 14),
        Text(
          leaf.kicker,
          style: TextStyle(
            color: leaf.accent,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

class _LeafRule extends StatelessWidget {
  const _LeafRule({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 3,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

@immutable
class _Leaf {
  const _Leaf({
    required this.kicker,
    required this.title,
    required this.body,
    required this.icon,
    required this.accent,
  });

  final String kicker;
  final String title;
  final String body;
  final IconData icon;
  final Color accent;
}

const List<_Leaf> _leaves = <_Leaf>[
  _Leaf(
    kicker: 'CHAPTER ONE',
    title: 'Paper & Light',
    body: 'A page is a thin plane of light. Hold it to a window and the world '
        'behind it bleeds through the fibres; lay it flat and it keeps its own '
        'quiet glow.',
    icon: Icons.wb_sunny_outlined,
    accent: Color(0xFFE0A106),
  ),
  _Leaf(
    kicker: 'CHAPTER TWO',
    title: 'The Spine',
    body: 'Every book turns on its spine — the still valley where two pages '
        'meet. Light pools there, a soft shadow that tells the eye exactly '
        'where the fold lives.',
    icon: Icons.menu_book_outlined,
    accent: Color(0xFF5C6BC0),
  ),
  _Leaf(
    kicker: 'CHAPTER THREE',
    title: 'Grain & Tooth',
    body: 'Drag a thumb across uncoated stock and you feel the tooth: a faint '
        'mottle that scatters light. It is the fingerprint of the paper, '
        'strongest where the page bends.',
    icon: Icons.texture,
    accent: Color(0xFF2B9C8A),
  ),
  _Leaf(
    kicker: 'CHAPTER FOUR',
    title: 'The Weight of a Page',
    body: 'A heavy leaf falls slowly, its free corner drooping under its own '
        'weight. A light one snaps. Weight is the difference between newsprint '
        'and a board cover.',
    icon: Icons.fitness_center,
    accent: Color(0xFFCB6B3A),
  ),
  _Leaf(
    kicker: 'CHAPTER FIVE',
    title: 'Gloss',
    body: 'Coated stock answers the light with a single bright glint that '
        'slides along the curl. Matte paper only whispers back. Gloss is how a '
        'surface says it is smooth.',
    icon: Icons.auto_awesome,
    accent: Color(0xFFC2477E),
  ),
  _Leaf(
    kicker: 'CHAPTER SIX',
    title: 'The Turn',
    body: 'A page in motion is never flat. It lifts, curls, and lays itself '
        'down on the far side — a developable surface that bends in one '
        'direction and never tears.',
    icon: Icons.gesture,
    accent: Color(0xFF7C4DFF),
  ),
  _Leaf(
    kicker: 'CHAPTER SEVEN',
    title: 'Shadow',
    body: 'The lifting leaf throws a soft shadow on the page beneath, darkest '
        'at the hinge. Remove it and the book goes flat; restore it and depth '
        'returns at once.',
    icon: Icons.dark_mode_outlined,
    accent: Color(0xFF5B7186),
  ),
  _Leaf(
    kicker: 'CHAPTER EIGHT',
    title: 'Rest',
    body: 'When the turn completes, the page settles until it is '
        'indistinguishable from the one below. A good turn ends in perfect '
        'stillness: no seam, no pop, no trace.',
    icon: Icons.spa_outlined,
    accent: Color(0xFF3E8E5A),
  ),
];
