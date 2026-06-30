import 'dart:ui' as ui;

import 'package:book_page_flip/src/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _solid(int w, int h) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(w, h);
}

RenderBookCanvas _canvasOf(WidgetTester tester) =>
    tester.allRenderObjects.whereType<RenderBookCanvas>().first;

class _Paint {
  _Paint(this.counts, this.clipRect, this.blits);
  final Map<Symbol, int> counts;
  final Rect? clipRect;
  final List<(Rect, Rect)> blits;
  int call(Symbol m) => counts[m] ?? 0;
  Rect srcForDst(bool Function(Rect dst) where) =>
      blits.firstWhere((b) => where(b.$2)).$1;
}

_Paint _record(RenderBookCanvas ro) {
  final canvas = TestRecordingCanvas();
  ro.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final counts = <Symbol, int>{};
  Rect? clip;
  final blits = <(Rect, Rect)>[];
  for (final inv in canvas.invocations) {
    final name = inv.invocation.memberName;
    counts[name] = (counts[name] ?? 0) + 1;
    if (name == #clipRect) {
      clip = inv.invocation.positionalArguments[0] as Rect;
    }
    if (name == #drawImageRect) {
      final a = inv.invocation.positionalArguments;
      blits.add((a[1] as Rect, a[2] as Rect));
    }
  }
  return _Paint(counts, clip, blits);
}

ui.Shader? _leafShader(RenderBookCanvas ro) {
  final canvas = TestRecordingCanvas();
  ro.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  for (final inv in canvas.invocations) {
    if (inv.invocation.memberName == #drawVertices) {
      final paint = inv.invocation.positionalArguments[2] as Paint;
      if (paint.shader != null) return paint.shader;
    }
  }
  return null;
}

Future<BookFlipController> _bootBook(WidgetTester tester) async {
  final controller = BookFlipController();
  final pages = <ui.Image>[for (var i = 0; i < 6; i++) await _solid(40, 56)];
  addTearDown(controller.dispose);
  addTearDown(() {
    for (final image in pages) {
      image.dispose();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 280,
            child: BookFlip(pages: pages, controller: controller),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return controller;
}

void main() {
  testWidgets(
      'idle paints exactly the two opaque base halves + binding AO, and '
      'NO leaf (no drawVertices, no wake clip)', (tester) async {
    await tester.runAsync(() async {
      await _bootBook(tester);
      final p = _record(_canvasOf(tester));
      expect(p(#drawImageRect), 2, reason: 'two opaque page halves');
      expect(p(#drawRect), 1, reason: 'binding ambient-occlusion band');
      expect(p(#drawVertices), 0, reason: 'no leaf is emitted at rest');
      expect(p(#clipPath), 0, reason: 'no wake clip at rest');
    });
  });

  testWidgets(
      'a committing forward flip composites the wake: 3 base blits + one '
      'wake clipPath + the leaf', (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      expect(controller.nextSpread(), isTrue);
      await tester.pump(const Duration(milliseconds: 120));
      expect(controller.isAnimating, isTrue, reason: 'mid-flight');
      final p = _record(_canvasOf(tester));
      expect(p(#drawImageRect), 3,
          reason: 'landing + clipped-outgoing + source-half blits');
      expect(p(#clipPath), 1, reason: 'the leaf wake clip');
      expect(p(#drawVertices), greaterThanOrEqualTo(2),
          reason: 'leaf main + sheen');
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets(
      'a boundary peel does NOT composite: plain 2-half base, no wake '
      'clip, yet the leaf still emits', (tester) async {
    await tester.runAsync(() async {
      await _bootBook(tester);

      final touch =
          tester.getTopLeft(find.byType(BookFlip)) + const Offset(40, 140);
      final gesture = await tester.startGesture(touch);
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
      final p = _record(_canvasOf(tester));
      expect(p(#drawImageRect), 2, reason: 'plain two-half base, no composite');
      expect(p(#clipPath), 0, reason: 'no wake clip for a non-committing peel');
      expect(p(#drawVertices), greaterThanOrEqualTo(2),
          reason: 'the peeling leaf is still drawn');
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets(
      'forward cast shadow clips to the SOURCE (right) half — never '
      'crosses the spine onto the exposed page', (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      expect(controller.nextSpread(), isTrue);
      Rect? clip;
      for (var ms = 0; ms < 800 && controller.isAnimating; ms += 24) {
        await tester.pump(const Duration(milliseconds: 24));
        final p = _record(_canvasOf(tester));
        if (p(#clipRect) > 0) {
          clip = p.clipRect;
          break;
        }
      }
      expect(clip, isNotNull, reason: 'the cast shadow must fire while lifted');

      expect(clip!.left, closeTo(200, 0.5), reason: 'clip starts at the spine');
      expect(clip.right, greaterThan(200), reason: 'and covers the right half');
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets(
      'a committing BACKWARD flip composites the wake AND clips its cast '
      'shadow to the SOURCE (left) half', (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      controller.goToSpread(2);
      await tester.pump();
      expect(controller.previousSpread(), isTrue);
      Rect? clip;
      var sawComposite = false;
      for (var ms = 0; ms < 800 && controller.isAnimating; ms += 24) {
        await tester.pump(const Duration(milliseconds: 24));
        final p = _record(_canvasOf(tester));
        if (p(#drawImageRect) == 3 && p(#clipPath) == 1) sawComposite = true;
        if (p(#clipRect) > 0) {
          clip = p.clipRect;
          break;
        }
      }
      expect(sawComposite, isTrue, reason: 'backward flip composites the wake');
      expect(clip, isNotNull, reason: 'the cast shadow must fire while lifted');

      expect(clip!.right, closeTo(200, 0.5), reason: 'clip ends at the spine');
      expect(clip.left, lessThan(200), reason: 'and covers the left half');
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('an active flip strokes the free-edge line (one drawPath)',
      (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      expect(controller.nextSpread(), isTrue);
      await tester.pump(const Duration(milliseconds: 120));
      final p = _record(_canvasOf(tester));
      expect(p(#drawPath), 1, reason: 'the free-edge stroke');
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets(
      'the two resting base halves blit DISTINCT page cells, left vs right',
      (tester) async {
    await tester.runAsync(() async {
      await _bootBook(tester);
      final p = _record(_canvasOf(tester));
      expect(p.blits.length, 2);
      final left = p.srcForDst((dst) => dst.left == 0);
      final right = p.srcForDst((dst) => dst.right == 400);
      expect(left, isNot(right),
          reason: 'left and right halves must sample different page cells');
    });
  });

  testWidgets('committing a forward flip advances the painted base pages',
      (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      final leftBefore =
          _record(_canvasOf(tester)).srcForDst((dst) => dst.left == 0);
      expect(controller.nextSpread(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.currentSpread, 1);
      final leftAfter =
          _record(_canvasOf(tester)).srcForDst((dst) => dst.left == 0);
      expect(leftAfter, isNot(leftBefore),
          reason: 'the left half must show a new page cell after the turn');
    });
  });

  testWidgets('the atlas shader is cached and reused across frames of a flip',
      (tester) async {
    await tester.runAsync(() async {
      final controller = await _bootBook(tester);
      expect(controller.nextSpread(), isTrue);
      await tester.pump(const Duration(milliseconds: 80));
      final shader1 = _leafShader(_canvasOf(tester));
      await tester.pump(const Duration(milliseconds: 80));
      final shader2 = _leafShader(_canvasOf(tester));
      expect(shader1, isNotNull);
      expect(identical(shader1, shader2), isTrue,
          reason: 'the atlas ImageShader must be cached and reused, '
              'not rebuilt every frame');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
