import 'dart:math' as math;

import 'package:book_page_flip/src/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const w = 400.0, h = 300.0;

  group('geometry hardening - sag field shape', () {
    test('[G1] sag pins the held row to v*h while a far row droops', () {
      final mesh = BookFlipMesh();
      const heldJ = 15;

      final grabV = heldJ / (mesh.nv - 1);
      mesh.computeWorld(
        w,
        h,
        0.5,
        grabV,
        1,
        curl: const BookFlipCurl(bend: 0, foldTilt: 0, droop: 1),
      );
      final edge = mesh.nu - 1;
      final heldFreeEdge = mesh.wy[heldJ * mesh.nu + edge];

      expect(heldFreeEdge, closeTo(grabV * h, 1e-6));

      final farFreeEdge = mesh.wy[0 * mesh.nu + edge];
      expect(farFreeEdge, greaterThan(5.0));
    });

    test('[G2] sag is symmetric about the held row - both sides droop down',
        () {
      final mesh = BookFlipMesh();
      const heldJ = 15, aboveJ = 25, belowJ = 5;
      final grabV = heldJ / (mesh.nv - 1);
      mesh.computeWorld(
        w,
        h,
        0.5,
        grabV,
        1,
        curl: const BookFlipCurl(bend: 0, foldTilt: 0, droop: 1),
      );
      final edge = mesh.nu - 1;
      double sagOf(int j) {
        final v = j / (mesh.nv - 1);
        return mesh.wy[j * mesh.nu + edge] - v * h;
      }

      final sagAbove = sagOf(aboveJ);
      final sagBelow = sagOf(belowJ);

      expect(sagAbove, greaterThan(1.0));
      expect(sagBelow, greaterThan(1.0));

      expect(sagBelow, closeTo(sagAbove, 1e-6));
    });
  });

  group('geometry hardening - developable arc-length isometry', () {
    test('[G3] a bent u-row preserves arc length == leafW (texture lock)', () {
      final mesh = BookFlipMesh();
      const leafW = w * 0.5;

      mesh.computeWorld(
        w,
        h,
        0.5,
        0.5,
        1,
        curl: const BookFlipCurl(bend: 1, foldTilt: 0),
      );
      const row = 15;
      var arc = 0.0;
      for (var i = 1; i < mesh.nu; i++) {
        final a = row * mesh.nu + (i - 1);
        final b = row * mesh.nu + i;
        final dx = mesh.wx[b] - mesh.wx[a];
        final dz = mesh.wz[b] - mesh.wz[a];
        arc += math.sqrt(dx * dx + dz * dz);
      }

      expect(arc, closeTo(leafW, leafW * 0.01));
    });
  });

  group('geometry hardening - corner-fold direction', () {
    test(
        '[G4] off-center grab folds rows below the grab toward the viewer '
        'more than rows above', () {
      final mesh = BookFlipMesh();
      const grabV = 0.2;
      mesh.computeWorld(
        w,
        h,
        0.5,
        grabV,
        1,
        curl: const BookFlipCurl(bend: 1, foldTilt: 1),
      );
      final edge = mesh.nu - 1;
      final wzBelow = mesh.wz[0 * mesh.nu + edge];
      final wzAbove = mesh.wz[(mesh.nv - 1) * mesh.nu + edge];

      expect(wzBelow - wzAbove, greaterThan(20.0));
    });
  });

  group('geometry hardening - paper grain spectrum', () {
    test('[G5] grain is zero-mean - no DC brightness bias', () {
      const n = 200;
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          sum += bookFlipGrainAt(i / (n - 1), j / (n - 1));
        }
      }
      final mean = sum / (n * n);

      expect(mean.abs(), lessThan(0.02));
    });

    test(
        '[G6] grain is band-limited - the render mesh resolves it (no '
        'aliasing along v)', () {
      final mesh = BookFlipMesh();
      final nu = mesh.nu, nv = mesh.nv;

      var maxMidErr = 0.0;
      for (var i = 0; i < nu; i++) {
        final u = i / (nu - 1);
        for (var j = 0; j < nv - 1; j++) {
          final v0 = j / (nv - 1);
          final v1 = (j + 1) / (nv - 1);
          final g0 = mesh.grain[j * nu + i];
          final g1 = mesh.grain[(j + 1) * nu + i];
          final mid = bookFlipGrainAt(u, 0.5 * (v0 + v1));
          final err = (mid - 0.5 * (g0 + g1)).abs();
          if (err > maxMidErr) maxMidErr = err;
        }
      }

      expect(maxMidErr, lessThan(0.10));
    });
  });
}
