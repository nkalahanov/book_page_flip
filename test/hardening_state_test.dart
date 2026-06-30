import 'dart:ui' as ui;

import 'package:book_page_flip/src/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _solidImage(int w, int h) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  return recorder.endRecording().toImage(w, h);
}

Widget _stablePage(BuildContext context, int index) =>
    const ColoredBox(color: Colors.white);

Future<List<ui.Image>> _sixPages() async =>
    <ui.Image>[for (var i = 0; i < 6; i++) await _solidImage(40, 56)];

void _disposeAll(List<ui.Image> pages) {
  for (final image in pages) {
    image.dispose();
  }
}

void main() {
  testWidgets(
    'a committed flip fires onFlipEnd once and onSpreadChanged once, each '
    'with the new spread',
    (tester) async {
      await tester.runAsync(() async {
        var starts = 0;
        final ended = <int>[];
        final changed = <int>[];
        final controller = BookFlipController();
        addTearDown(controller.dispose);

        final pages = await _sixPages();
        addTearDown(() => _disposeAll(pages));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip(
                    pages: pages,
                    controller: controller,
                    onFlipStart: (_, __) => starts++,
                    onFlipEnd: ended.add,
                    onSpreadChanged: changed.add,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.currentSpread, 0, reason: 'opens on spread 0');

        expect(controller.nextSpread(), isTrue, reason: 'a forward flip began');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(controller.currentSpread, 1, reason: 'committed to spread 1');
        expect(starts, 1, reason: 'exactly one onFlipStart');

        expect(
          ended,
          <int>[1],
          reason: 'onFlipEnd fired ONCE on commit, reporting the new spread',
        );

        expect(
          changed,
          <int>[1],
          reason: 'onSpreadChanged fired ONCE on commit with the new spread',
        );
      });
    },
  );

  testWidgets(
    'a spring-back (sub-commit drag) fires onFlipEnd and changes no spread',
    (tester) async {
      await tester.runAsync(() async {
        var starts = 0;
        final ended = <int>[];
        final changed = <int>[];
        final controller = BookFlipController();
        addTearDown(controller.dispose);

        final pages = await _sixPages();
        addTearDown(() => _disposeAll(pages));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip(
                    pages: pages,
                    controller: controller,
                    physics: const BookFlipPhysics(
                      commitThreshold: 0.99,
                      commitVelocity: 1000,
                    ),
                    onFlipStart: (_, __) => starts++,
                    onFlipEnd: ended.add,
                    onSpreadChanged: changed.add,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final center = tester.getCenter(find.byType(BookFlip));
        final gesture = await tester.startGesture(center + const Offset(80, 0));
        await tester.pump();
        for (var i = 0; i < 5; i++) {
          await gesture.moveBy(const Offset(-16, 0));
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(starts, 1, reason: 'the drag activated exactly one flip');

        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(
          ended,
          <int>[0],
          reason: 'a spring-back still concludes: one onFlipEnd at spread 0',
        );
        expect(
          changed,
          isEmpty,
          reason: 'a spring-back moves nothing → no onSpreadChanged',
        );
        expect(controller.currentSpread, 0, reason: 'sprang back to spread 0');
      });
    },
  );

  testWidgets(
    'goToSpread past the end clamps to the last spread, not one past it',
    (tester) async {
      await tester.runAsync(() async {
        final controller = BookFlipController();
        addTearDown(controller.dispose);

        final pages = await _sixPages();
        addTearDown(() => _disposeAll(pages));

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
        expect(controller.totalSpreads, 3, reason: '6 pages → 3 spreads');

        controller.goToSpread(9999);
        await tester.pump();

        expect(
          controller.currentSpread,
          2,
          reason: 'clamps to the last spread index (totalSpreads - 1 == 2)',
        );
        expect(controller.currentPage, 4, reason: 'spread 2 → left page 4');
        expect(tester.takeException(), isNull, reason: 'no RangeError');
      });
    },
  );

  test(
    'FlipScene.frame() repaints on leafBack / w / h / baseLeft / baseRight / '
    'material — each field gates a repaint',
    () {
      final scene = FlipScene();
      addTearDown(scene.dispose);

      expect(scene.frame(), isTrue, reason: 'first frame primes + notifies');
      expect(scene.frame(), isFalse, reason: 'identical state → no repaint');

      scene.leafBack = 99;
      expect(scene.frame(), isTrue, reason: 'leafBack changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');

      scene.w = 123.0;
      expect(scene.frame(), isTrue, reason: 'w changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');

      scene.h = 456.0;
      expect(scene.frame(), isTrue, reason: 'h changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');

      scene.baseLeft = 7;
      expect(scene.frame(), isTrue, reason: 'baseLeft changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');

      scene.baseRight = 8;
      expect(scene.frame(), isTrue, reason: 'baseRight changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');

      scene.material = BookFlipMaterial.magazine;
      expect(scene.frame(), isTrue, reason: 'material changed → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');
    },
  );

  testWidgets('FlipScene.frame() repaints when the atlas swaps',
      (tester) async {
    await tester.runAsync(() async {
      final scene = FlipScene();
      addTearDown(scene.dispose);
      expect(scene.frame(), isTrue, reason: 'first frame primes + notifies');
      expect(scene.frame(), isFalse, reason: 'identical state → no repaint');

      final atlas = await _solidImage(8, 8);
      addTearDown(atlas.dispose);
      scene.atlas = atlas;

      expect(scene.frame(), isTrue, reason: 'atlas swap → repaint');
      expect(scene.frame(), isFalse, reason: 're-primed → no repaint');
    });
  });

  testWidgets(
    'a pageCount change with a STABLE builder re-captures the new count',
    (tester) async {
      await tester.runAsync(() async {
        final controller = BookFlipController();
        addTearDown(controller.dispose);

        Widget build(int count) => MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 400,
                    height: 280,
                    child: BookFlip.builder(
                      controller: controller,
                      pageCount: count,
                      pageSize: const Size(40, 56),
                      pageBuilder: _stablePage,
                    ),
                  ),
                ),
              ),
            );

        await tester.pumpWidget(build(4));
        for (var i = 0; i < 70; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.totalPages, 4, reason: 'first book has 4 pages');

        await tester.pumpWidget(build(6));
        for (var i = 0; i < 90; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(tester.takeException(), isNull, reason: 'no RangeError');

        expect(
          controller.totalPages,
          6,
          reason: 'the pageCount clause re-captured to the new 6-page book',
        );
      });
    },
  );
}
