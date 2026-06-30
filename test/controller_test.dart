import 'dart:ui' as ui;

import 'package:book_page_flip/book_page_flip.dart';
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

void main() {
  testWidgets('controller exposes page-level navigation', (tester) async {
    await tester.runAsync(() async {
      final controller = BookFlipController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 280,
                child: BookFlip.builder(
                  controller: controller,
                  pageCount: 6,
                  pageSize: const Size(200, 280),
                  pageBuilder: (context, i) =>
                      const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(controller.totalPages, 6);
      expect(controller.currentPage, 0);

      controller.goToPage(4);
      await tester.pump();
      expect(controller.currentSpread, 2);
      expect(controller.currentPage, 4);
    });
  });

  testWidgets('nextSpread/previousSpread report whether a flip started',
      (tester) async {
    await tester.runAsync(() async {
      final controller = BookFlipController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 280,
                child: BookFlip.builder(
                  controller: controller,
                  pageCount: 6,
                  pageSize: const Size(200, 280),
                  pageBuilder: (context, i) =>
                      const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(controller.previousSpread(), isFalse,
          reason: 'at the first spread → backward is an inert no-op');

      expect(controller.nextSpread(), isTrue,
          reason: 'a real forward flip started');

      expect(controller.nextSpread(), isFalse,
          reason: 'a flip already in progress → dropped, reported as false');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.currentSpread, 1);

      expect(controller.previousSpread(), isTrue,
          reason: 'a real backward flip started');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.currentSpread, 0);

      controller.goToSpread(2);
      await tester.pump();
      expect(controller.nextSpread(), isFalse,
          reason: 'at the last spread → forward is an inert no-op');
    });
  });

  testWidgets(
      'a jump balances onFlipEnd on interrupt and emits no no-op onSpreadChanged',
      (tester) async {
    await tester.runAsync(() async {
      var starts = 0, ends = 0, changes = 0;
      final controller = BookFlipController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 280,
                child: BookFlip.builder(
                  controller: controller,
                  pageCount: 6,
                  pageSize: const Size(200, 280),
                  onFlipStart: (_, __) => starts++,
                  onFlipEnd: (_) => ends++,
                  onSpreadChanged: (_) => changes++,
                  pageBuilder: (context, i) =>
                      const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      controller.goToSpread(0);
      await tester.pump();
      expect(changes, 0, reason: 'no-op jump emits no onSpreadChanged');
      expect(ends, 0, reason: 'no active flip → no onFlipEnd');

      expect(controller.nextSpread(), isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.isAnimating, isTrue, reason: 'flip is mid-flight');
      expect(starts, 1, reason: 'the flip fired onFlipStart');

      controller.goToSpread(2);
      await tester.pump();
      expect(starts, 1, reason: 'a jump starts no new flip');
      expect(ends, 1,
          reason: 'the interrupted flip is balanced by exactly one onFlipEnd');
      expect(changes, 1, reason: 'the jump moved 0 → 2, one onSpreadChanged');
      expect(controller.currentSpread, 2);

      controller.goToSpread(2);
      await tester.pump();
      expect(changes, 1,
          reason: 'no-op jump at spread 2 → no new onSpreadChanged');
      expect(ends, 1,
          reason: 'no active flip at the no-op jump → no onFlipEnd');
    });
  });

  testWidgets('a pages reload interrupting a live flip fires one onFlipEnd',
      (tester) async {
    await tester.runAsync(() async {
      var starts = 0, ends = 0;
      final controller = BookFlipController();
      addTearDown(controller.dispose);

      final pagesA = <ui.Image>[
        for (var i = 0; i < 6; i++) await _solid(40, 56),
      ];
      final pagesB = <ui.Image>[
        for (var i = 0; i < 6; i++) await _solid(40, 56),
      ];
      addTearDown(() {
        for (final image in <ui.Image>[...pagesA, ...pagesB]) {
          image.dispose();
        }
      });

      Widget build(List<ui.Image> pages) => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip(
                    pages: pages,
                    controller: controller,
                    onFlipStart: (_, __) => starts++,
                    onFlipEnd: (_) => ends++,
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(pagesA));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      await tester.pumpWidget(build(pagesB));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(starts, 0, reason: 'no flip has started yet');
      expect(ends, 0, reason: 'an idle reload ends no flip');

      expect(controller.nextSpread(), isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.isAnimating, isTrue, reason: 'flip is mid-flight');
      expect(starts, 1, reason: 'the flip fired onFlipStart');

      await tester.pumpWidget(build(pagesA));
      await tester.pump();
      expect(ends, 1,
          reason: 'a reload interrupting a live flip fires one onFlipEnd');
      expect(starts, 1, reason: 'a reload starts no new flip');
    });
  });

  test('BookFlip.builder rejects a sub-floor maxTextureDimension', () {
    expect(
      () => BookFlip.builder(
        pageCount: 2,
        pageSize: const Size(10, 10),
        maxTextureDimension: 255,
        pageBuilder: (context, i) => const SizedBox(),
      ),
      throwsAssertionError,
    );
  });

  test('BookFlip.builder rejects an out-of-range meshResolution', () {
    expect(
      () => BookFlip.builder(
        pageCount: 2,
        pageSize: const Size(10, 10),
        meshResolution: 7,
        pageBuilder: (context, i) => const SizedBox(),
      ),
      throwsAssertionError,
    );
    expect(
      () => BookFlip.builder(
        pageCount: 2,
        pageSize: const Size(10, 10),
        meshResolution: 301,
        pageBuilder: (context, i) => const SizedBox(),
      ),
      throwsAssertionError,
    );
  });
}
