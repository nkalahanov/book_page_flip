import 'package:book_page_flip/src/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookFlipCurl', () {
    test('value equality, hashCode and copyWith', () {
      const a = BookFlipCurl(bend: 0.3, foldTilt: 0.6, droop: 0.2);
      const b = BookFlipCurl(bend: 0.3, foldTilt: 0.6, droop: 0.2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a.copyWith(bend: 0.9),
        const BookFlipCurl(bend: 0.9, foldTilt: 0.6, droop: 0.2),
      );
    });

    test('asserts reject out-of-range dials but accept the [0,1] edges', () {
      expect(() => BookFlipCurl(bend: -0.01), throwsAssertionError);
      expect(() => BookFlipCurl(bend: 1.01), throwsAssertionError);
      expect(() => BookFlipCurl(foldTilt: 1.01), throwsAssertionError);
      expect(() => BookFlipCurl(droop: 1.01), throwsAssertionError);
      expect(const BookFlipCurl(bend: 0, foldTilt: 0), isNotNull);
      expect(const BookFlipCurl(bend: 1, foldTilt: 1, droop: 1), isNotNull);
    });

    test('lerp blends endpoints and the midpoint', () {
      const a = BookFlipCurl(bend: 0.2, foldTilt: 0.2);
      const b = BookFlipCurl(bend: 0.8, foldTilt: 0.6, droop: 1.0);
      expect(BookFlipCurl.lerp(a, b, 0), a);
      expect(BookFlipCurl.lerp(a, b, 1), b);
      final mid = BookFlipCurl.lerp(a, b, 0.5);
      expect(mid.bend, closeTo(0.5, 1e-9));
      expect(mid.droop, closeTo(0.5, 1e-9));
    });

    test('dial → engine mappings are monotonic and finite across [0,1]', () {
      expect(
        bookFlipCurlAmax(const BookFlipCurl(bend: 1)),
        greaterThan(bookFlipCurlAmax(const BookFlipCurl(bend: 0))),
      );
      expect(
        bookFlipCurlTilt(const BookFlipCurl(foldTilt: 1)),
        greaterThan(bookFlipCurlTilt(const BookFlipCurl(foldTilt: 0))),
      );
      expect(
        bookFlipCurlSag(const BookFlipCurl(droop: 1)),
        greaterThan(bookFlipCurlSag(const BookFlipCurl())),
      );
      expect(bookFlipCurlSag(const BookFlipCurl()), 0.0);
      for (final d in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
        final c = BookFlipCurl(bend: d, foldTilt: d, droop: d);
        expect(bookFlipCurlAmax(c).isFinite && bookFlipCurlAmax(c) > 0, isTrue);
        expect(bookFlipCurlTilt(c).isFinite && bookFlipCurlTilt(c) > 0, isTrue);
        expect(bookFlipCurlSag(c).isFinite && bookFlipCurlSag(c) >= 0, isTrue);
      }
    });

    test('curl reaches the geometry — it reshapes the leaf (not a dead param)',
        () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      mesh.computeWorld(w, h, 0.5, 0.5, 1, curl: const BookFlipCurl(bend: 0));
      final zGentle = List<double>.of(mesh.wz);
      mesh.computeWorld(w, h, 0.5, 0.5, 1, curl: const BookFlipCurl(bend: 1));
      var maxDelta = 0.0;
      for (var i = 0; i < mesh.n; i++) {
        final d = (mesh.wz[i] - zGentle[i]).abs();
        if (d > maxDelta) maxDelta = d;
      }
      expect(maxDelta, greaterThan(1.0));
    });

    test('EVERY curl is flat-invariant at rest (t=0 and t=1) — never a pop',
        () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      for (final t in <double>[0.0, 1.0]) {
        for (final d in <double>[0.0, 0.5, 1.0]) {
          final c = BookFlipCurl(bend: d, foldTilt: d, droop: d);
          mesh.computeWorld(w, h, t, 0.5, 1, curl: c);
          for (var i = 0; i < mesh.n; i++) {
            expect(
              mesh.wz[i].abs(),
              lessThan(1e-9),
              reason: 'curl $c at t=$t must lie flat (z=0)',
            );
          }
        }
      }
    });

    test('NO curl yields a non-finite vertex anywhere across the flip', () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      for (final d in <double>[0.0, 0.5, 1.0]) {
        final c = BookFlipCurl(bend: d, foldTilt: d, droop: d);
        for (var k = 0; k <= 10; k++) {
          mesh.computeWorld(w, h, k / 10, 0.5, 1, curl: c);
          for (var i = 0; i < mesh.n; i++) {
            expect(
              mesh.wx[i].isFinite && mesh.wy[i].isFinite && mesh.wz[i].isFinite,
              isTrue,
            );
          }
        }
      }
    });

    test('a non-null curl FULLY overrides the material geometry', () {
      final a = BookFlipMesh();
      final b = BookFlipMesh();
      const w = 400.0, h = 300.0;
      const curl = BookFlipCurl(bend: 0.7, foldTilt: 0.3, droop: 0.4);
      for (final t in <double>[0.0, 0.3, 0.7, 1.0]) {
        a.computeWorld(
          w,
          h,
          t,
          0.5,
          1,
          material: BookFlipMaterial.magazine,
          curl: curl,
        );
        b.computeWorld(
          w,
          h,
          t,
          0.5,
          1,
          material: const BookFlipMaterial(stiffness: 0.1),
          curl: curl,
        );
        for (var i = 0; i < a.n; i++) {
          expect(a.wx[i], b.wx[i]);
          expect(a.wy[i], b.wy[i]);
          expect(a.wz[i], b.wz[i]);
        }
      }
    });

    test('scene repaint dedupe tracks curl changes', () {
      final scene = FlipScene();
      addTearDown(scene.dispose);
      var n = 0;
      scene.addListener(() => n++);
      scene.frame();
      final base = n;
      scene.frame();
      expect(n, base);
      scene.curl = const BookFlipCurl(bend: 0.9);
      scene.frame();
      expect(n, base + 1);
    });

    test(
        'named presets are pop-free, finite and continuous — every grab, both '
        'directions', () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      for (final c in const <BookFlipCurl>[
        BookFlipCurl.gentle,
        BookFlipCurl.tight,
        BookFlipCurl.floppy,
      ]) {
        for (final dir in const <int>[1, -1]) {
          for (final grabV in const <double>[0.0, 0.5, 1.0]) {
            for (final t in const <double>[0.0, 1.0]) {
              mesh.computeWorld(w, h, t, grabV, dir, curl: c);
              for (var i = 0; i < mesh.n; i++) {
                expect(mesh.wz[i].abs(), lessThan(1e-9),
                    reason: 'preset $c flat at t=$t (grabV=$grabV dir=$dir)');
              }
            }

            List<double>? px, pz;
            for (var k = 0; k <= 20; k++) {
              mesh.computeWorld(w, h, k / 20, grabV, dir, curl: c);
              for (var i = 0; i < mesh.n; i++) {
                expect(
                  mesh.wx[i].isFinite &&
                      mesh.wy[i].isFinite &&
                      mesh.wz[i].isFinite,
                  isTrue,
                  reason: 'preset $c finite at t=${k / 20} (grabV=$grabV)',
                );
              }
              if (px != null) {
                for (var i = 0; i < mesh.n; i++) {
                  expect((mesh.wx[i] - px[i]).abs(), lessThan(w * 0.4),
                      reason: 'preset $c x-continuous (grabV=$grabV)');
                  expect((mesh.wz[i] - pz![i]).abs(), lessThan(h * 0.4),
                      reason: 'preset $c z-continuous (grabV=$grabV)');
                }
              }
              px = List<double>.of(mesh.wx);
              pz = List<double>.of(mesh.wz);
            }
          }
        }
      }
    });

    test(
        'the full curl envelope (all dials 1.0, tiltMax 0.42) stays finite and '
        'continuous at every grab — the phi guard never kinks the leaf', () {
      final mesh = BookFlipMesh();
      const w = 400.0, h = 300.0;
      const extreme = BookFlipCurl(bend: 1, foldTilt: 1, droop: 1);
      for (final dir in const <int>[1, -1]) {
        for (final grabV in const <double>[0.0, 0.5, 1.0]) {
          List<double>? px, pz;
          for (var k = 0; k <= 40; k++) {
            mesh.computeWorld(w, h, k / 40, grabV, dir, curl: extreme);
            for (var i = 0; i < mesh.n; i++) {
              expect(
                mesh.wx[i].isFinite &&
                    mesh.wy[i].isFinite &&
                    mesh.wz[i].isFinite,
                isTrue,
                reason:
                    'envelope finite at t=${k / 40} (grabV=$grabV dir=$dir)',
              );
            }
            if (px != null) {
              for (var i = 0; i < mesh.n; i++) {
                expect((mesh.wx[i] - px[i]).abs(), lessThan(w * 0.4),
                    reason: 'envelope x-continuous (grabV=$grabV)');
                expect((mesh.wz[i] - pz![i]).abs(), lessThan(h * 0.4),
                    reason: 'envelope z-continuous (grabV=$grabV)');
              }
            }
            px = List<double>.of(mesh.wx);
            pz = List<double>.of(mesh.wz);
          }
        }
      }
    });

    test('preset magnitudes are ordered and distinct — not collapsed', () {
      expect(
        bookFlipCurlAmax(BookFlipCurl.gentle),
        lessThan(bookFlipCurlAmax(BookFlipCurl.floppy)),
      );
      expect(
        bookFlipCurlAmax(BookFlipCurl.floppy),
        lessThan(bookFlipCurlAmax(BookFlipCurl.tight)),
      );

      expect(bookFlipCurlSag(BookFlipCurl.tight), 0.0);
      expect(
        bookFlipCurlSag(BookFlipCurl.floppy),
        greaterThan(bookFlipCurlSag(BookFlipCurl.gentle)),
      );
    });
  });
}
