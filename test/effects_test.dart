import 'package:book_page_flip/src/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookFlipEffects', () {
    test('value equality, hashCode and copyWith', () {
      const a = BookFlipEffects(gloss: false, edge: false);
      const b = BookFlipEffects(gloss: false, edge: false);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        BookFlipEffects.all.copyWith(grain: false),
        const BookFlipEffects(grain: false),
      );
    });

    BookFlipMesh shaded(
      BookFlipEffects fx, {
      double t = 0.5,
      BookFlipMaterial material = BookFlipMaterial.magazine,
    }) {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      mesh.computeWorld(w, h, t, 0.5, 1, material: material);
      mesh.computeNormals();
      mesh.computeShading(w, h, kFovY, material: material, effects: fx);
      return mesh;
    }

    test('gloss off → zero specular everywhere', () {
      final mesh = shaded(const BookFlipEffects(gloss: false));
      for (var i = 0; i < mesh.n; i++) {
        expect(mesh.spec[i], 0.0);
      }
    });

    test('grain off changes the luminance vs grain on (it really contributes)',
        () {
      final on = shaded(BookFlipEffects.all, material: BookFlipMaterial.paper);
      final lumOn = List<double>.of(on.lum);
      final off = shaded(
        const BookFlipEffects(grain: false),
        material: BookFlipMaterial.paper,
      );
      var maxDelta = 0.0;
      for (var i = 0; i < off.n; i++) {
        final d = (off.lum[i] - lumOn[i]).abs();
        if (d > maxDelta) maxDelta = d;
      }
      expect(maxDelta, greaterThan(1e-6));
    });

    test('EVERY effects combo is pop-free at flat rest (lum=1, spec=0)', () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      mesh.computeWorld(w, h, 0, 0.5, 1, material: BookFlipMaterial.magazine);
      mesh.computeNormals();
      const combos = <BookFlipEffects>[
        BookFlipEffects.all,
        BookFlipEffects(
          gloss: false,
          grain: false,
          castShadow: false,
          spineShadow: false,
          edge: false,
          translucency: false,
        ),
        BookFlipEffects(grain: false),
        BookFlipEffects(gloss: false),
      ];
      for (final fx in combos) {
        mesh.computeShading(
          w,
          h,
          kFovY,
          material: BookFlipMaterial.magazine,
          effects: fx,
        );
        for (var i = 0; i < mesh.n; i++) {
          expect(mesh.lum[i], closeTo(1.0, 1e-9));
          expect(mesh.spec[i], closeTo(0.0, 1e-9));
        }
      }
    });

    test('scene repaint dedupe tracks effects changes', () {
      final scene = FlipScene();
      addTearDown(scene.dispose);
      var n = 0;
      scene.addListener(() => n++);
      scene.frame();
      final base = n;
      scene.frame();
      expect(n, base);
      scene.effects = const BookFlipEffects(grain: false);
      scene.frame();
      expect(n, base + 1);
    });
  });

  testWidgets(
    'BookFlip.builder with every effect off builds without error',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 280,
                  child: BookFlip.builder(
                    pageCount: 4,
                    pageSize: const Size(200, 280),
                    pageBuilder: (context, i) =>
                        const ColoredBox(color: Colors.white),
                    effects: const BookFlipEffects(
                      gloss: false,
                      grain: false,
                      castShadow: false,
                      spineShadow: false,
                      edge: false,
                      translucency: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.byType(BookFlip), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
