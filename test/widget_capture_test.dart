import 'dart:ui' as ui;

import 'package:book_page_flip/src/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<ui.Image>> _capture(
  WidgetTester tester,
  List<Widget> pages, {
  Size logicalSize = const Size(120, 160),
  double pixelRatio = 2.0,
}) async {
  List<ui.Image>? captured;
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookFlipPageRasterizer(
          key: UniqueKey(),
          pages: pages,
          logicalSize: logicalSize,
          pixelRatio: pixelRatio,
          onCaptured: (images) => captured = images,
        ),
      ),
    );
    for (var i = 0; i < 30 && captured == null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  return captured ?? <ui.Image>[];
}

Future<int> _opaquePixels(ui.Image image) async {
  final data = await image.toByteData();
  if (data == null) return 0;
  final bytes = data.buffer.asUint8List();
  var count = 0;
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] != 0) count++;
  }
  return count;
}

void main() {
  testWidgets(
      'rasterises Text / TextSpan / Icon / subtree to sized, real images',
      (tester) async {
    final images = await _capture(tester, const <Widget>[
      Text('Page one'),
      Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: 'rich '),
            TextSpan(text: 'span'),
          ],
        ),
      ),
      Icon(Icons.star, size: 64),
      ColoredBox(color: Colors.indigo, child: Center(child: Text('subtree'))),
    ]);

    expect(images.length, 4, reason: 'one image per page, in order');
    for (final image in images) {
      expect(image.width, 240, reason: 'logicalSize.width 120 * pixelRatio 2');
      expect(image.height, 320,
          reason: 'logicalSize.height 160 * pixelRatio 2');
    }

    await tester.runAsync(() async {
      final solid = await _opaquePixels(images[3]);
      expect(
        solid,
        greaterThan(240 * 320 * 9 ~/ 10),
        reason: 'an opaque page captures as a full, non-blank image',
      );
      for (var i = 0; i < 3; i++) {
        expect(
          await _opaquePixels(images[i]),
          greaterThan(0),
          reason: 'page $i (text/icon) must capture real glyph pixels',
        );
      }
    });

    for (final image in images) {
      image.dispose();
    }
  });

  testWidgets('pixelRatio scales the captured resolution', (tester) async {
    final one = await _capture(
      tester,
      const <Widget>[SizedBox.shrink()],
      logicalSize: const Size(100, 150),
      pixelRatio: 1,
    );
    final three = await _capture(
      tester,
      const <Widget>[SizedBox.shrink()],
      logicalSize: const Size(100, 150),
      pixelRatio: 3,
    );

    expect(one.single.width, 100);
    expect(one.single.height, 150);
    expect(three.single.width, 300);
    expect(three.single.height, 450);

    one.single.dispose();
    three.single.dispose();
  });
}
