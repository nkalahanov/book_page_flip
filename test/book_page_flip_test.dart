import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:book_page_flip/src/engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void expectPermutation(List<int> order, int count) {
  expect(order.length, count);
  final seen = List<bool>.filled(count, false);
  for (final v in order) {
    expect(v, inInclusiveRange(0, count - 1));
    expect(seen[v], isFalse,
        reason: 'index $v appears twice — not a permutation');
    seen[v] = true;
  }
}

void main() {
  const w = 412.0, h = 732.0, fov = kFovY;

  group('easing primitives (C1 at rest = no velocity jump)', () {
    test('smoothstep01: clamped, endpoints exact, ~zero slope at ends', () {
      expect(bookSmoothstep01(0.0), 0.0);
      expect(bookSmoothstep01(1.0), closeTo(1.0, 1e-12));
      expect(bookSmoothstep01(-0.5), 0.0, reason: 'clamped below 0');
      expect(bookSmoothstep01(1.7), closeTo(1.0, 1e-12),
          reason: 'clamped above 1');
      expect(bookSmoothstep01(0.5), closeTo(0.5, 1e-9));
      final d0 = (bookSmoothstep01(1e-4) - bookSmoothstep01(0)) / 1e-4;
      final d1 = (bookSmoothstep01(1) - bookSmoothstep01(1 - 1e-4)) / 1e-4;
      expect(d0.abs(), lessThan(1e-2));
      expect(d1.abs(), lessThan(1e-2));
    });

    test('bumpC1 = sin²(πt): value AND slope are 0 at both ends [F4]', () {
      expect(bookBumpC1(0.0), closeTo(0.0, 1e-12));
      expect(bookBumpC1(1.0), closeTo(0.0, 1e-12));
      expect(bookBumpC1(0.5), closeTo(1.0, 1e-12));
      final d0 = (bookBumpC1(1e-4) - bookBumpC1(0)) / 1e-4;
      final d1 = (bookBumpC1(1) - bookBumpC1(1 - 1e-4)) / 1e-4;

      expect(
        d0.abs(),
        lessThan(1e-2),
        reason:
            'slope at t=0 must be ~0 — sin(πt) would be ~3.14 → velocity pop',
      );
      expect(d1.abs(), lessThan(1e-2));
    });
  });

  group('projection calibration', () {
    void chk(double px, double py, double ex, double ey) {
      final p = bookFlipProjectPoint(px, py, 0.0, w, h, fov);
      expect(p.$3, greaterThan(0),
          reason: 'clip w must be > 0 (point in front)');
      expect(p.$1, closeTo(ex, 0.5), reason: 'screenX for world ($px,$py,0)');
      expect(p.$2, closeTo(ey, 0.5), reason: 'screenY for world ($px,$py,0)');
    }

    test('four corners + center land on the screen rect', () {
      chk(0, 0, 0, 0);
      chk(w, 0, w, 0);
      chk(0, h, 0, h);
      chk(w, h, w, h);
      chk(w / 2, h / 2, w / 2, h / 2);
    });

    test('a point lifted toward the viewer has a smaller clip-w (perspective)',
        () {
      final flat = bookFlipProjectPoint(w, h / 2, 0.0, w, h, fov);
      final lifted = bookFlipProjectPoint(w, h / 2, 40.0, w, h, fov);
      expect(lifted.$3, lessThan(flat.$3));
    });
  });

  group('rest geometry & seamless commit', () {
    ({double minx, double maxx, double maxz}) span(BookFlipMesh m) {
      double minx = 1e9, maxx = -1e9, maxz = 0;
      for (var i = 0; i < m.n; i++) {
        minx = math.min(minx, m.wx[i]);
        maxx = math.max(maxx, m.wx[i]);
        maxz = math.max(maxz, m.wz[i].abs());
      }
      return (minx: minx, maxx: maxx, maxz: maxz);
    }

    test('t=0 forward leaf: flat (z≈0), covers RIGHT half exactly', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.0, 0.5, 1);
      final s = span(m);
      expect(s.maxz, lessThan(1e-9));
      expect(s.minx, closeTo(w / 2, 1e-6));
      expect(s.maxx, closeTo(w, 1e-6));
    });

    test('t=1 forward leaf: flat, covers LEFT half exactly (back == new left)',
        () {
      final m = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, 1);
      final s = span(m);
      expect(s.maxz, lessThan(1e-6));
      expect(s.minx, closeTo(0.0, 1e-6));
      expect(s.maxx, closeTo(w / 2, 1e-6));
    });

    test('t=1 backward leaf: flat AND covers RIGHT half exactly', () {
      final m = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, -1);
      final s = span(m);
      expect(s.maxz, lessThan(1e-6), reason: 'backward landing must be flat');
      expect(s.minx, closeTo(w / 2, 1e-6));
      expect(s.maxx, closeTo(w, 1e-6));
    });
  });

  group('top/bottom corner fold stays in-bounds [F4]', () {
    test('pre-clamp phi ∈ [0,π] for all grabV, t, v (hard clamp never needed)',
        () {
      for (final grabV in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        for (double t = 0; t <= 1.0001; t += 0.05) {
          final phiBase = math.pi * bookSmoothstep01(t);
          final tilt = kTiltMax * bookBumpC1(t);
          for (double v = 0; v <= 1.0001; v += 0.1) {
            final phi = phiBase + tilt * (v - grabV);
            expect(
              phi,
              greaterThanOrEqualTo(-1e-9),
              reason: 'phi<0 → row frozen-then-jump (grabV=$grabV t=$t v=$v)',
            );
            expect(
              phi,
              lessThanOrEqualTo(math.pi + 1e-9),
              reason: 'phi>π → overshoot (grabV=$grabV t=$t v=$v)',
            );
          }
        }
      }
    });
  });

  group('frame-walk gauntlet [L0]', () {
    test(
        'no NaN and no teleport across t∈[-0.1,1.1], grabV∈{0,.5,1}, both dirs',
        () {
      for (final dir in [1, -1]) {
        for (final grabV in [0.0, 0.5, 1.0]) {
          final m = BookFlipMesh();
          List<double>? px, py;
          for (var t = -0.1; t <= 1.1001; t += 0.02) {
            m
              ..computeWorld(w, h, t, grabV, dir)
              ..computeNormals()
              ..project(w, h, fov);
            for (var i = 0; i < m.n; i++) {
              expect(
                m.sx[i].isFinite,
                isTrue,
                reason: 'sx NaN/Inf @ t=$t dir=$dir grabV=$grabV i=$i',
              );
              expect(
                m.sy[i].isFinite,
                isTrue,
                reason: 'sy NaN/Inf @ t=$t dir=$dir grabV=$grabV i=$i',
              );
              expect(m.sx[i], inInclusiveRange(-w, 2 * w));
              expect(m.sy[i], inInclusiveRange(-h, 2 * h));
            }
            if (px != null) {
              double maxd = 0;
              for (var i = 0; i < m.n; i++) {
                final dx = m.sx[i] - px[i], dy = m.sy[i] - py![i];
                maxd = math.max(maxd, math.sqrt(dx * dx + dy * dy));
              }

              expect(
                maxd,
                lessThan(w * 0.15),
                reason: 'teleport @ t=$t dir=$dir grabV=$grabV maxd=$maxd',
              );
            }
            px = List<double>.from(m.sx);
            py = List<double>.from(m.sy);
          }
        }
      }
    });

    test('grabV = NaN sanitizes to 0.5 (no poison) [F11]', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.5, double.nan, 1);
      m.project(w, h, fov);
      for (var i = 0; i < m.n; i++) {
        expect(m.sx[i].isFinite, isTrue);
      }
      final ref = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
      for (var i = 0; i < m.n; i++) {
        expect(m.wx[i], closeTo(ref.wx[i], 1e-9));
      }
    });

    test('zero / non-finite viewport does not throw or emit NaN downstream',
        () {
      final m = BookFlipMesh();
      expect(
        () {
          m
            ..computeWorld(0, 0, 0.5, 0.5, 1)
            ..computeNormals()
            ..project(0, 0, fov)
            ..computeShading(0, 0, fov);
        },
        returnsNormally,
      );
      for (var i = 0; i < m.n; i++) {
        expect(m.sx[i].isFinite, isTrue,
            reason: 'zero-size fallback must be finite');
      }
    });
  });

  group('shading bounds [F8][F10]', () {
    test('luminance ≥ ambient and ≤ 1; spec ∈ [0, kSheen]', () {
      final m = BookFlipMesh();
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        m
          ..computeWorld(w, h, t, 0.5, 1)
          ..computeNormals()
          ..computeShading(w, h, fov);
        for (var i = 0; i < m.n; i++) {
          expect(m.lum[i].isFinite, isTrue);
          expect(
            m.lum[i],
            greaterThanOrEqualTo(kAmbient - 1e-9),
            reason: 'underside must not crush to black',
          );
          expect(m.lum[i], lessThanOrEqualTo(1.0 + 1e-9));
          expect(
            m.spec[i],
            inInclusiveRange(0.0, kSheen + 1e-9),
            reason: 'sheen must not blow out',
          );
        }
      }
    });
  });

  group('boundary resistance [#6/#28]', () {
    test('starts at 0, monotone non-decreasing, bounded below the commit point',
        () {
      expect(boundaryResist(0.0), closeTo(0.0, 1e-9));
      expect(boundaryResist(-5.0), 0.0);
      var prev = -1.0;
      for (double x = 0; x < 3; x += 0.05) {
        final y = boundaryResist(x);
        expect(y, greaterThanOrEqualTo(prev - 1e-12));
        expect(y, lessThan(0.105),
            reason: 'must never reach the 0.5 commit threshold');
        prev = y;
      }
    });
  });

  group('content orientation [180° mirror elimination]', () {
    bool allFaceFront(BookFlipMesh m, int dir, bool expectFront) {
      var ok = true;
      for (var tr = 0; tr < m.triCount; tr++) {
        final o = tr * 3;
        final a = m.triIdx[o], b = m.triIdx[o + 1], c = m.triIdx[o + 2];
        final ff = bookFlipFaceFront(m.signedArea(a, b, c), dir);
        if (ff != expectFront) ok = false;
      }
      return ok;
    }

    test('t=0 shows RECTO (front) for both directions', () {
      final fwd = BookFlipMesh()..computeWorld(w, h, 0.0, 0.5, 1);
      fwd.project(w, h, fov);
      expect(allFaceFront(fwd, 1, true), isTrue,
          reason: 'forward rest = recto');
      final back = BookFlipMesh()..computeWorld(w, h, 0.0, 0.5, -1);
      back.project(w, h, fov);
      expect(allFaceFront(back, -1, true), isTrue,
          reason: 'backward rest = recto');
    });

    test('t=1 shows VERSO (back) for both directions', () {
      final fwd = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, 1);
      fwd.project(w, h, fov);
      expect(allFaceFront(fwd, 1, false), isTrue);
      final back = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, -1);
      back.project(w, h, fov);
      expect(allFaceFront(back, -1, false), isTrue);
    });

    test('world-x↑ ⟺ texel-u↑ at all flat states (no horizontal mirror)', () {
      for (final dir in [1, -1]) {
        for (final t in [0.0, 1.0]) {
          final m = BookFlipMesh()..computeWorld(w, h, t, 0.5, dir);
          m.project(w, h, fov);
          for (var tr = 0; tr < m.triCount; tr++) {
            final o = tr * 3;
            final a = m.triIdx[o], b = m.triIdx[o + 1], c = m.triIdx[o + 2];
            final ff = bookFlipFaceFront(m.signedArea(a, b, c), dir);
            double uOf(int idx) => (idx % m.nu) / (m.nu - 1);
            for (final pair in [
              [a, b],
              [b, c],
              [a, c],
            ]) {
              final dwx = m.wx[pair[1]] - m.wx[pair[0]];
              if (dwx.abs() < 1e-6) continue;
              final dtu = bookFlipLeafTexU(uOf(pair[1]), dir, ff) -
                  bookFlipLeafTexU(uOf(pair[0]), dir, ff);
              expect(
                dwx.sign == dtu.sign || dtu == 0,
                isTrue,
                reason: 'mirror @ dir=$dir t=$t tri=$tr (dwx=$dwx dtu=$dtu)',
              );
            }
          }
        }
      }
    });

    test(
        't=1 forward verso texel-map == base drawImageRect map (seamless commit)',
        () {
      final m = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, 1);
      m.project(w, h, fov);
      for (var tr = 0; tr < m.triCount; tr++) {
        final o = tr * 3;
        final a = m.triIdx[o], b = m.triIdx[o + 1], c = m.triIdx[o + 2];
        final ff = bookFlipFaceFront(m.signedArea(a, b, c), 1);
        for (final idx in [a, b, c]) {
          final u = (idx % m.nu) / (m.nu - 1);
          final texNorm = bookFlipLeafTexU(u, 1, ff);

          final baseNorm = m.wx[idx] / (w / 2);
          expect(
            texNorm,
            closeTo(baseNorm, 1e-6),
            reason: 'verso texel ≠ base map → content snap at commit (tri=$tr)',
          );
        }
      }
    });

    test('t=1 backward verso texel-map == base map (seamless commit, dir=-1)',
        () {
      final m = BookFlipMesh()..computeWorld(w, h, 1.0, 0.5, -1);
      m.project(w, h, fov);
      for (var tr = 0; tr < m.triCount; tr++) {
        final o = tr * 3;
        final a = m.triIdx[o], b = m.triIdx[o + 1], c = m.triIdx[o + 2];
        final ff = bookFlipFaceFront(m.signedArea(a, b, c), -1);
        for (final idx in [a, b, c]) {
          final u = (idx % m.nu) / (m.nu - 1);
          final texNorm = bookFlipLeafTexU(u, -1, ff);

          final baseNorm = (m.wx[idx] - w / 2) / (w / 2);
          expect(
            texNorm,
            closeTo(baseNorm, 1e-6),
            reason: 'backward verso texel ≠ base map (tri=$tr)',
          );
        }
      }
    });
  });

  group('depth sort', () {
    test('depthOrder sorts triangles far→near (ascending mean world-z)', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
      final order = m.depthOrder();
      expect(order.length, m.triCount);
      var prev = -1e18;
      for (var oi = 0; oi < m.triCount; oi++) {
        final tr = order[oi];
        final o = tr * 3;
        final mz = (m.wz[m.triIdx[o]] +
                m.wz[m.triIdx[o + 1]] +
                m.wz[m.triIdx[o + 2]]) /
            3.0;
        expect(
          mz,
          greaterThanOrEqualTo(prev - 1e-9),
          reason: 'depth order not ascending at index $oi',
        );
        prev = mz;
      }
    });

    test(
        'depthOrder returns a valid permutation on BOTH paths (flat-skip + sort)',
        () {
      final m = BookFlipMesh();

      m.computeWorld(w, h, 0.0, 0.5, 1);
      expectPermutation(m.depthOrder(), m.triCount);

      m.computeWorld(w, h, 0.5, 0.5, 1);
      expectPermutation(m.depthOrder(), m.triCount);

      m.computeWorld(w, h, 0.52, 0.5, 1);
      final ord = m.depthOrder();
      expectPermutation(ord, m.triCount);

      var prev = -1e18;
      for (var oi = 0; oi < m.triCount; oi++) {
        final o = ord[oi] * 3;
        final mz = (m.wz[m.triIdx[o]] +
                m.wz[m.triIdx[o + 1]] +
                m.wz[m.triIdx[o + 2]]) /
            3.0;
        expect(mz, greaterThanOrEqualTo(prev - 1e-9));
        prev = mz;
      }
    });
  });

  group('render-state dedupe (repaint elision)', () {
    test('frame() notifies once per DISTINCT state, never on an exact repeat',
        () {
      final scene = FlipScene();
      var n = 0;
      scene.addListener(() => n++);

      scene.t = 0.3;
      scene.frame();
      expect(n, 1, reason: 'first distinct render state must notify');

      scene.frame();
      scene.frame();
      expect(n, 1, reason: 'identical render state must NOT repaint');

      scene.t = 0.4;
      scene.frame();
      expect(n, 2);

      scene.dir = -1;
      scene.frame();
      expect(n, 3, reason: 'dir change alters facing → must repaint');

      scene.grabV = 0.8;
      scene.frame();
      expect(n, 4, reason: 'grabV change alters geometry → must repaint');

      scene.active = true;
      scene.frame();
      expect(n, 5,
          reason: 'active toggle adds/removes the leaf → must repaint');

      scene.leafFront = 7;
      scene.frame();
      expect(n, 6, reason: 'page-index change swaps texture → must repaint');

      scene.dispose();
    });

    test('frame() returns whether it repainted (the controller-notify gate)',
        () {
      final scene = FlipScene();
      scene.t = 0.3;
      expect(scene.frame(), isTrue, reason: 'first distinct state repaints');
      expect(scene.frame(), isFalse, reason: 'exact repeat is suppressed');
      scene.t = 0.31;
      expect(scene.frame(), isTrue, reason: 'real motion repaints');
      scene.dispose();
    });
  });

  group('cast shadow geometry [umbra eased to 0 at contact, geometric vanish]',
      () {
    double maxZAt(double t) {
      final m = BookFlipMesh()..computeWorld(w, h, t, 0.5, 1);
      return m.maxAbsZ();
    }

    double maxOffsetAt(double t, int dir) {
      final m = BookFlipMesh()..computeWorld(w, h, t, 0.5, dir);
      const lxr = -0.16, lyr = -0.6, lzr = 0.72;
      final ll = math.sqrt(lxr * lxr + lyr * lyr + lzr * lzr);
      final lx = lxr / ll, lz = lzr / ll;
      var maxOff = 0.0;
      for (var i = 0; i < m.n; i++) {
        final off = (m.wz[i] / lz * lx).abs();
        if (off > maxOff) maxOff = off;
      }
      return maxOff;
    }

    test('leaf height is 0 when flat (t=0,1) and substantial mid-flip', () {
      expect(maxZAt(0.0), lessThan(1e-9),
          reason: 'flat at rest → no shadow source');
      expect(maxZAt(1.0), lessThan(1e-6),
          reason: 'flat at landing → shadow → 0');
      expect(maxZAt(0.5), greaterThan(0.1 * w), reason: 'page rises mid-flip');
    });

    test('cast OFFSET → 0 at both flat states (footprint tucks under the leaf)',
        () {
      for (final dir in [1, -1]) {
        expect(
          maxOffsetAt(0.0, dir),
          lessThan(1e-9),
          reason:
              'flat liftoff: shadow coincides with leaf → invisible (dir=$dir)',
        );
        expect(
          maxOffsetAt(1.0, dir),
          lessThan(1e-6),
          reason:
              'flat landing: shadow tucks under leaf → invisible (dir=$dir)',
        );
        expect(
          maxOffsetAt(0.5, dir),
          greaterThan(2.0),
          reason: 'mid-flip: shadow offsets out from under the leaf (dir=$dir)',
        );
      }
    });

    test('shadow EASES out at landing — slope→0, not a pop (C1 via sin²)', () {
      final z1 = maxZAt(1.0 - 1e-3);
      final z0 = maxZAt(1.0);
      final slope = ((z0 - z1) / 1e-3).abs();
      expect(
        slope,
        lessThan(0.05 * w),
        reason:
            'shadow must ease out at landing, not vanish sharply (slope=$slope)',
      );

      final l0 = maxZAt(0.0);
      final l1 = maxZAt(0.0 + 1e-3);
      expect(
        ((l1 - l0) / 1e-3).abs(),
        lessThan(0.05 * w),
        reason: 'shadow must ease in at liftoff too (slope at t=0)',
      );
    });

    test('cast offset is continuous across the flip (no sudden jump)', () {
      var prev = maxOffsetAt(0.0, 1);
      for (var t = 0.0; t <= 1.0001; t += 0.02) {
        final off = maxOffsetAt(t, 1);
        expect(off.isFinite, isTrue);
        expect(
          (off - prev).abs(),
          lessThan(0.10 * w),
          reason: 'cast offset jumped at t=$t (Δ=${(off - prev).abs()})',
        );
        prev = off;
      }
    });

    test(
        'cast umbra fade is continuous & monotone to 0 at contact — never a pop',
        () {
      expect(bookFlipCastFade(0.0), 0.0,
          reason: 'no cast shadow at flat contact');
      expect(
        bookFlipCastFade(kCastFade),
        closeTo(1.0, 1e-9),
        reason: 'full once lifted past the fade band',
      );
      expect(bookFlipCastFade(2 * kCastFade), 1.0,
          reason: 'clamped to full above band');
      var prev = bookFlipCastFade(0.0);
      for (var s = 1; s <= 90; s++) {
        final f = bookFlipCastFade(kCastFade * 1.5 * s / 90);
        expect(f, greaterThanOrEqualTo(prev - 1e-12),
            reason: 'fade must be monotone');
        expect(
          (f - prev).abs(),
          lessThan(0.05),
          reason: 'fade must be continuous (no opacity jump)',
        );
        prev = f;
      }
    });

    test(
        'cast umbra DISSOLVES into contact — the opacity step shrinks toward landing',
        () {
      double castFadeAt(double t, int dir) {
        final mm = BookFlipMesh()..computeWorld(w, h, t, 0.5, dir);
        final he = (mm.maxAbsZ() / (kShadowZRef * w)).clamp(0.0, 1.0);
        return bookFlipCastFade(he);
      }

      for (final dir in [1, -1]) {
        expect(
          castFadeAt(1.0, dir),
          lessThan(0.01),
          reason: 'shadow ~gone at landing (dir=$dir)',
        );
        expect(
          castFadeAt(0.5, dir),
          greaterThan(0.9),
          reason: 'shadow full mid-flip (dir=$dir)',
        );
        final stepFar = (castFadeAt(0.90, dir) - castFadeAt(0.91, dir)).abs();
        final stepNear = (castFadeAt(0.98, dir) - castFadeAt(0.99, dir)).abs();
        expect(
          stepNear,
          lessThan(stepFar),
          reason: 'opacity step must shrink toward contact (dir=$dir)',
        );
      }
    });
  });

  group('spine alignment [no center seam between pages]', () {
    test('leaf hinge column (u=0) projects EXACTLY to spineX for all t & dirs',
        () {
      for (final dir in [1, -1]) {
        for (var t = 0.0; t <= 1.0001; t += 0.1) {
          final m = BookFlipMesh()..computeWorld(w, h, t, 0.5, dir);
          m.project(w, h, fov);
          for (var j = 0; j < m.nv; j++) {
            final idx = j * m.nu;

            expect(
              m.sx[idx],
              closeTo(w / 2, 1e-6),
              reason:
                  'hinge vertex off-center → leaf/base seam (t=$t dir=$dir j=$j)',
            );

            expect(
              m.wz[idx].abs(),
              lessThan(1e-9),
              reason: 'hinge lifted off the spine (t=$t dir=$dir j=$j)',
            );
          }
        }
      }
    });
  });

  group('seamless commit [leaf covers destination at landing → empty wake]',
      () {
    double maxFreeEdgeGap(double t, double grabV, int dir) {
      final m = BookFlipMesh()..computeWorld(w, h, t, grabV, dir);
      m.project(w, h, fov);
      final far = dir > 0 ? 0.0 : w;
      final i = m.nu - 1;
      var gap = 0.0;
      for (var j = 0; j < m.nv; j++) {
        final g = (m.sx[j * m.nu + i] - far).abs();
        if (g > gap) gap = g;
      }
      return gap;
    }

    test(
        'free edge reaches the page edge EXACTLY at t=1 (wake collapses to nothing)',
        () {
      for (final dir in [1, -1]) {
        expect(
          maxFreeEdgeGap(1.0, 0.5, dir),
          lessThan(1e-4),
          reason:
              'leaf must fully cover the destination half at t=1 (dir=$dir)',
        );
      }
    });

    test('wake is sub-pixel at the real commit point (t≈0.999), for any grab',
        () {
      for (final dir in [1, -1]) {
        for (final grabV in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          expect(
            maxFreeEdgeGap(0.9992, grabV, dir),
            lessThan(1.0),
            reason: 'outgoing page must be <1px (invisible) at commit '
                '(dir=$dir grabV=$grabV)',
          );
        }
      }
    });
  });

  group('binding-shadow sharpness [middle shadow stays soft]', () {
    test('peak darkness is SCALE-INVARIANT — same α at every render width', () {
      const widths = [60.0, 120.0, 400.0, 1000.0, 2000.0];
      final peak0 = bookFlipBindingSharpness(widths.first).peakAlpha;
      for (final w in widths) {
        expect(
          bookFlipBindingSharpness(w).peakAlpha,
          closeTo(peak0, 1e-9),
          reason: 'binding darkness must not depend on size (w=$w)',
        );
      }

      expect(peak0, greaterThan(0.05));
      expect(peak0, lessThan(kBindingAO));
    });

    test('softer as the book grows — maxGrad strictly decreases with width',
        () {
      var prev = double.infinity;
      for (final w in [100.0, 200.0, 400.0, 800.0, 1600.0]) {
        final g = bookFlipBindingSharpness(w).maxGrad;
        expect(g, lessThan(prev), reason: 'a wider book must be softer (w=$w)');
        prev = g;
      }
    });

    test('SOFT at every realistic render width (≥ 250px)', () {
      for (var w = 250.0; w <= 4000.0; w += 50.0) {
        final r = bookFlipBindingSharpness(w);
        expect(
          r.verdict,
          0,
          reason:
              'spine must be soft at w=$w (σ=${r.sigmaPx} maxGrad=${r.maxGrad})',
        );

        expect(r.sigmaPx, greaterThan(1.6),
            reason: 'σ went near-pixel at w=$w');
        expect(r.fwhmPx * 0.5, greaterThan(1.0),
            reason: 'band too thin at w=$w');
      }
    });

    test('flags SHARP when a tiny render drives σ sub-pixel', () {
      final tiny = bookFlipBindingSharpness(30);
      expect(tiny.sigmaPx, lessThan(1.0));
      expect(tiny.maxGrad, greaterThan(0.02));
      expect(tiny.verdict, 2, reason: 'sub-pixel σ must be reported SHARP');
    });

    test('degenerate width is reported SHARP, never NaN', () {
      for (final w in [0.0, -10.0, double.nan, double.infinity]) {
        expect(
          bookFlipBindingSharpness(w).verdict,
          2,
          reason: 'non-positive / non-finite width → SHARP (w=$w)',
        );
      }
    });

    test('guards the tuning: a sub-pixel σ retune fails the soft contract', () {
      expect(bookFlipBindingSharpness(800).verdict, 0,
          reason: 'default → soft');
      expect(
        bookFlipBindingSharpness(800, sigma: 0.001).verdict,
        2,
        reason: 'σ = 800·0.001 = 0.8px sub-pixel → must fail as SHARP',
      );
    });
  });

  group('lighting continuity to base [no long-press / landing jump]', () {
    test('flat leaf is FULLY lit (lum=1.0) and glint-free (spec=0) == base',
        () {
      for (final t in [0.0, 1.0]) {
        for (final dir in [1, -1]) {
          final m = BookFlipMesh()
            ..computeWorld(w, h, t, 0.5, dir)
            ..computeNormals()
            ..computeShading(w, h, fov);
          for (var i = 0; i < m.n; i++) {
            expect(
              m.lum[i],
              closeTo(1.0, 1e-9),
              reason:
                  'flat leaf must equal unlit base brightness (t=$t dir=$dir)',
            );
            expect(
              m.spec[i],
              closeTo(0.0, 1e-9),
              reason: 'flat leaf must have no sheen (t=$t dir=$dir)',
            );
          }
        }
      }
    });

    test(
        'luminance is continuous across the flip (shape-driven, no shading step)',
        () {
      for (final dir in [1, -1]) {
        final m = BookFlipMesh();
        List<double>? prev;
        for (var t = 0.0; t <= 1.0001; t += 0.02) {
          m
            ..computeWorld(w, h, t, 0.5, dir)
            ..computeNormals()
            ..computeShading(w, h, fov);
          if (prev != null) {
            for (var i = 0; i < m.n; i++) {
              expect(
                (m.lum[i] - prev[i]).abs(),
                lessThan(0.18),
                reason: 'luminance step too large at t=$t dir=$dir',
              );
            }
          }
          prev = List<double>.from(m.lum);
        }
      }
    });
  });

  group('public API', () {
    test('BookFlipController reports safe defaults and never throws detached',
        () {
      final c = BookFlipController(initialSpread: 3);
      expect(c.currentSpread, 3, reason: 'opens at initialSpread');
      expect(c.isAnimating, isFalse);
      expect(c.flipProgress, 0.0);

      c.nextSpread();
      c.previousSpread();
      c.goToSpread(1);
      expect(c.currentSpread, 3, reason: 'detached drives change nothing');
      c.dispose();
    });

    test('BookFlipPhysics is const-canonicalized with the documented defaults',
        () {
      const p = BookFlipPhysics();
      expect(p.springStiffness, kSpringStiffness);
      expect(p.springDampingRatio, 1.0);
      expect(p.commitThreshold, 0.5);
      expect(p.commitVelocity, 1.2);
      expect(p.settleEpsilon, kCommitEps);

      expect(
          identical(const BookFlipPhysics(), const BookFlipPhysics()), isTrue);
    });

    test('BookFlipPhysics has value equality (== and hashCode)', () {
      const a = BookFlipPhysics(springStiffness: 300);
      const b = BookFlipPhysics(springStiffness: 300);
      const c = BookFlipPhysics(springStiffness: 301);
      expect(a, equals(b), reason: 'same fields → equal even when non-const');
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('FlipDirection has exactly the two reading directions', () {
      expect(FlipDirection.values,
          [FlipDirection.forward, FlipDirection.backward]);
    });

    testWidgets(
        'BookFlip boots to ready and a controller flip commits a spread',
        (tester) async {
      final pages = <ui.Image>[];
      await tester.runAsync(() async {
        for (var i = 0; i < 4; i++) {
          final rec = ui.PictureRecorder();
          Canvas(rec).drawColor(const Color(0xFF203040), BlendMode.src);
          final pic = rec.endRecording();
          pages.add(await pic.toImage(16, 16));
          pic.dispose();
        }
      });
      final controller = BookFlipController();
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
        controller.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BookFlip(pages: pages, controller: controller)),
        ),
      );

      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 32)));
      await tester.pump();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'reached ready — the loading placeholder is gone',
      );
      expect(controller.currentSpread, 0);
      expect(controller.totalSpreads, 2, reason: '4 pages → 2 spreads');

      controller.nextSpread();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.currentSpread, 1,
          reason: 'programmatic flip committed');
      expect(controller.isAnimating, isFalse);
    });
  });

  group('layout — finite size for any constraints, never distorts', () {
    Future<List<ui.Image>> makePages(
      WidgetTester tester, {
      int n = 4,
      int w = 30,
      int h = 40,
    }) async {
      final pages = <ui.Image>[];
      await tester.runAsync(() async {
        for (var i = 0; i < n; i++) {
          final rec = ui.PictureRecorder();
          Canvas(rec).drawColor(const Color(0xFF334455), BlendMode.src);
          final pic = rec.endRecording();
          pages.add(await pic.toImage(w, h));
          pic.dispose();
        }
      });
      return pages;
    }

    Future<RenderAspectFitBox> pumpBooted(
        WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 32)));
      await tester.pump();
      return tester.renderObject<RenderAspectFitBox>(find.byType(BookFlip));
    }

    testWidgets('unbounded HEIGHT (Column) → finite size, no exception',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box =
          await pumpBooted(tester, Column(children: [BookFlip(pages: pages)]));
      expect(tester.takeException(), isNull);
      expect(box.size.isFinite, isTrue);
      expect(box.size.shortestSide, greaterThan(0));

      expect(box.size.height, closeTo(box.size.width / 1.5, 1e-3));
      expect(
          box.contentRect.width / box.contentRect.height, closeTo(1.5, 1e-6));
    });

    testWidgets('unbounded WIDTH (horizontal scroll) → finite, no exception',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: BookFlip(pages: pages),
        ),
      );
      expect(tester.takeException(), isNull);

      expect(box.size.width, closeTo(box.size.height * 1.5, 1e-3));
      expect(box.size.shortestSide, greaterThan(0));
    });

    testWidgets('fully UNBOUNDED both axes → intrinsic content size',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        UnconstrainedBox(child: BookFlip(pages: pages)),
      );
      expect(tester.takeException(), isNull);

      expect(
        box.size,
        const Size(60, 40),
        reason: 'unbounded → intrinsic content size',
      );
    });

    testWidgets('tight SQUARE box, contain → letterboxed, never stretched',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        Center(
          child:
              SizedBox(width: 300, height: 300, child: BookFlip(pages: pages)),
        ),
      );
      expect(box.size, const Size(300, 300), reason: 'fills the tight box');
      final c = box.contentRect;
      expect(c.width / c.height, closeTo(1.5, 1e-6), reason: 'no distortion');
      expect(c.width, lessThanOrEqualTo(300));
      expect(c.height, lessThanOrEqualTo(300));
      expect(c.center, const Offset(150, 150), reason: 'centred letterbox');
    });

    testWidgets('BookFit.fill stretches the book to the whole box',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: BookFlip(pages: pages, fit: BookFit.fill),
          ),
        ),
      );
      expect(box.contentRect, const Rect.fromLTWH(0, 0, 200, 200));
    });

    testWidgets('pageAspectRatio override drives the natural shape',
        (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        Column(children: [BookFlip(pages: pages, pageAspectRatio: 1)]),
      );
      expect(box.aspectRatio, closeTo(2.0, 1e-9), reason: 'spread = 2 × page');
      expect(box.size.height, closeTo(box.size.width / 2.0, 1e-3));
    });

    testWidgets('sub-pixel size does not throw', (tester) async {
      final pages = await makePages(tester);
      addTearDown(() {
        for (final p in pages) {
          p.dispose();
        }
      });
      final box = await pumpBooted(
        tester,
        Center(
          child: SizedBox(width: 1, height: 1, child: BookFlip(pages: pages)),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(box.size.width, lessThanOrEqualTo(1));
    });

    testWidgets('swapping to pages of a new shape updates the layout aspect',
        (tester) async {
      final wide = await makePages(tester, w: 80);
      final tall = await makePages(tester, h: 60);
      addTearDown(() {
        for (final p in [...wide, ...tall]) {
          p.dispose();
        }
      });
      await tester
          .pumpWidget(MaterialApp(home: Scaffold(body: BookFlip(pages: wide))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 32)));
      await tester.pump();
      var box = tester.renderObject<RenderAspectFitBox>(find.byType(BookFlip));
      expect(box.aspectRatio, closeTo(4.0, 1e-9));

      await tester
          .pumpWidget(MaterialApp(home: Scaffold(body: BookFlip(pages: tall))));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 32)));
      await tester.pump();
      box = tester.renderObject<RenderAspectFitBox>(find.byType(BookFlip));
      expect(
        box.aspectRatio,
        closeTo(1.0, 1e-9),
        reason: 'layout aspect must follow the new pages, not stay stale',
      );
    });
  });

  group('atlas cell sizing [bookFlipAtlasCell]', () {
    test('a small book keeps full image resolution (no needless downscale)',
        () {
      final (cw, ch) = bookFlipAtlasCell(512, 720, 2, 1, 4096);
      expect(cw, 512);
      expect(ch, 720);
    });

    test('a large book scales down uniformly to fit the cap', () {
      final (cw, ch) = bookFlipAtlasCell(1000, 1000, 8, 8, 4096);
      expect(8 * cw, lessThanOrEqualTo(4096),
          reason: 'atlas width fits the cap');
      expect(8 * ch, lessThanOrEqualTo(4096),
          reason: 'atlas height fits the cap');
      expect(cw, ch, reason: 'square pages stay square (uniform scale)');
    });

    test('aspect ratio is preserved under downscale (no distortion)', () {
      final (cw, ch) = bookFlipAtlasCell(800, 400, 6, 6, 2048);
      expect(cw / ch, closeTo(2.0, 0.02));
    });

    test('a lower cap (a weaker GPU) yields a strictly smaller cell', () {
      final (bigW, _) = bookFlipAtlasCell(1000, 1000, 4, 4, 4096);
      final (smallW, _) = bookFlipAtlasCell(1000, 1000, 4, 4, 2048);
      expect(smallW, lessThan(bigW),
          reason: 'the retry-halve path shrinks cells');
    });

    test('a zero-dimension image falls back to the default cell shape', () {
      final (cw, ch) = bookFlipAtlasCell(0, 0, 1, 1, 4096);
      expect(cw, kPageTexW);
      expect(ch, kPageTexH);
    });

    test('cells are never zero, even at an absurdly small cap', () {
      final (cw, ch) = bookFlipAtlasCell(1000, 1000, 8, 8, 16);
      expect(cw, greaterThanOrEqualTo(1));
      expect(ch, greaterThanOrEqualTo(1));
    });
  });

  group('mesh resolution', () {
    test('a custom resolution sizes the mesh buffers', () {
      final m = BookFlipMesh(nu: 80, nv: 56);
      expect(m.n, 80 * 56);
      expect(m.triCount, (80 - 1) * (56 - 1) * 2);
      expect(m.wx.length, 80 * 56);
    });

    test('a mesh that would overflow a 16-bit index is rejected', () {
      expect(
        () => BookFlipMesh(nu: 400, nv: 400),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('material', () {
    final presets = <(String, BookFlipMaterial)>[
      ('paper', BookFlipMaterial.paper),
      ('magazine', BookFlipMaterial.magazine),
      (
        'matteLimp',
        const BookFlipMaterial(
            stiffness: 0.18,
            weight: 0.62,
            gloss: 0.0,
            translucency: 0.28,
            thickness: 0.35)
      ),
      (
        'boardStiff',
        const BookFlipMaterial(
            stiffness: 0.95, weight: 0.08, gloss: 0.5, thickness: 3.2)
      ),
      (
        'extremeFloppy',
        const BookFlipMaterial(
            stiffness: 0, weight: 1, gloss: 1, translucency: 1, thickness: 6)
      ),
      (
        'extremeStiff',
        const BookFlipMaterial(stiffness: 1, gloss: 0, thickness: 0)
      ),
    ];

    test(
        'default material maps to the engine constants EXACTLY (no regression)',
        () {
      const makeDefault = BookFlipMaterial.new;
      final d = makeDefault();
      expect(bookFlipAmax(d), kAmax);
      expect(bookFlipTilt(d), kTiltMax);
      expect(bookFlipSheen(d), kSheen);
      expect(bookFlipShininess(d), kShininess);
      expect(bookFlipSagAmp(d), 0.0);
      expect(bookFlipTranslucency(d), 0.0);
      expect(bookFlipUmbra(d), kShadowMax);
      expect(bookFlipEdgeWidth(d), 1.2);

      expect(bookFlipTooth(d), kTooth);
      expect(bookFlipCoat(d), 0.0);
      expect(bookFlipSpecMax(d), kSheen);
    });

    test(
        'EVERY material is flat-invariant at rest (t=0,1) — never a landing pop',
        () {
      for (final (name, m) in presets) {
        for (final t in [0.0, 1.0]) {
          for (final dir in [1, -1]) {
            final mesh = BookFlipMesh()
              ..computeWorld(w, h, t, 0.5, dir, material: m)
              ..computeNormals()
              ..computeShading(w, h, fov, material: m);
            for (var j = 0; j < mesh.nv; j++) {
              for (var i = 0; i < mesh.nu; i++) {
                final idx = j * mesh.nu + i;
                expect(
                  mesh.wz[idx].abs(),
                  lessThan(1e-6),
                  reason: '$name must be coplanar at rest (t=$t)',
                );
                final expectedY = (j / (mesh.nv - 1)) * h;
                expect(
                  (mesh.wy[idx] - expectedY).abs(),
                  lessThan(1e-6),
                  reason: '$name must not sag at rest (t=$t)',
                );
                expect(
                  mesh.spec[idx],
                  lessThan(1e-9),
                  reason: '$name must be glint-free at rest',
                );
                expect(
                  (mesh.lum[idx] - 1.0).abs(),
                  lessThan(1e-9),
                  reason: '$name flat leaf must equal the base (lum=1)',
                );
              }
            }
          }
        }
      }
    });

    test('the spine hinge (u=0) never moves, for any material, t or grab', () {
      for (final (name, m) in presets) {
        for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          for (final dir in [1, -1]) {
            final mesh = BookFlipMesh()
              ..computeWorld(w, h, t, 0.15, dir, material: m);
            for (var j = 0; j < mesh.nv; j++) {
              final idx = j * mesh.nu;
              expect(
                (mesh.wx[idx] - w * 0.5).abs(),
                lessThan(1e-6),
                reason: '$name hinge x stays on the spine (t=$t)',
              );
              final expectedY = (j / (mesh.nv - 1)) * h;
              expect(
                (mesh.wy[idx] - expectedY).abs(),
                lessThan(1e-6),
                reason: '$name hinge y must not droop (t=$t)',
              );
            }
          }
        }
      }
    });

    test('dials are monotonic AND reach the geometry/shading (not dead params)',
        () {
      const limp = BookFlipMaterial(stiffness: 0.18, weight: 0.62, gloss: 0.0);
      const board = BookFlipMaterial(stiffness: 0.95, weight: 0.08, gloss: 0.5);
      expect(bookFlipAmax(limp), greaterThan(bookFlipAmax(board)));
      expect(
        bookFlipSheen(BookFlipMaterial.magazine),
        greaterThan(bookFlipSheen(limp)),
      );
      expect(
        bookFlipShininess(BookFlipMaterial.magazine),
        greaterThan(bookFlipShininess(limp)),
        reason: 'glossy = a tighter, higher-shininess highlight',
      );
      expect(bookFlipSagAmp(limp), greaterThan(bookFlipSagAmp(board)));

      double maxMeshDelta(BookFlipMaterial a, BookFlipMaterial b) {
        final ma = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1, material: a);
        final mb = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1, material: b);
        var d = 0.0;
        for (var i = 0; i < ma.n; i++) {
          final e = (ma.wz[i] - mb.wz[i]).abs();
          if (e > d) d = e;
        }
        return d;
      }

      expect(
        maxMeshDelta(board, limp),
        greaterThan(5.0),
        reason: 'stiffness must visibly change the bend',
      );

      double minLum(BookFlipMaterial m) {
        final mesh = BookFlipMesh()
          ..computeWorld(w, h, 0.5, 0.5, 1, material: m)
          ..computeNormals()
          ..computeShading(w, h, fov, material: m);
        var lo = 1.0;
        for (var i = 0; i < mesh.n; i++) {
          if (mesh.lum[i] < lo) lo = mesh.lum[i];
        }
        return lo;
      }

      expect(
        minLum(const BookFlipMaterial(stiffness: 0.5, translucency: 1.0)),
        greaterThan(minLum(const BookFlipMaterial(stiffness: 0.5))),
        reason: 'translucency lifts the curl shadows',
      );

      double peakSpec(BookFlipMaterial m) {
        var hi = 0.0;
        for (var t = 0.05; t < 0.96; t += 0.05) {
          final mesh = BookFlipMesh(nu: 120, nv: 84)
            ..computeWorld(w, h, t, 0.5, 1, material: m)
            ..computeNormals()
            ..computeShading(w, h, fov, material: m);
          for (var i = 0; i < mesh.n; i++) {
            if (mesh.spec[i] > hi) hi = mesh.spec[i];
          }
        }
        return hi;
      }

      const glossy = BookFlipMaterial(stiffness: 0.5, gloss: 1.0);
      const matte = BookFlipMaterial(stiffness: 0.5, gloss: 0.0);
      expect(
        peakSpec(glossy),
        greaterThan(0),
        reason: 'gloss reaches the rendered field',
      );
      expect(
        peakSpec(glossy),
        greaterThan(peakSpec(matte)),
        reason: 'coated white gloss = a brighter peak than matte',
      );
      expect(
        peakSpec(glossy),
        greaterThan(bookFlipSheen(matte)),
        reason: 'the coat lifts the highlight above the plain matte sheen cap',
      );
      expect(bookFlipCoat(glossy), greaterThan(0.0),
          reason: 'high gloss engages the coat');
      expect(bookFlipCoat(matte), 0.0, reason: 'matte paper carries no coat');
    });

    test('NO material yields NaN, out-of-range shading, or a screen teleport',
        () {
      for (final (name, m) in presets) {
        final sheenCap = bookFlipSpecMax(m);
        for (final dir in [1, -1]) {
          double? px, py;
          for (var t = -0.1; t <= 1.1001; t += 0.05) {
            final mesh = BookFlipMesh()
              ..computeWorld(w, h, t, 0.3, dir, material: m)
              ..computeNormals()
              ..project(w, h, fov)
              ..computeShading(w, h, fov, material: m);
            for (var idx = 0; idx < mesh.n; idx++) {
              expect(
                mesh.wx[idx].isFinite &&
                    mesh.wy[idx].isFinite &&
                    mesh.wz[idx].isFinite,
                isTrue,
                reason: '$name world finite at t=$t',
              );
              expect(
                mesh.sx[idx].isFinite && mesh.sy[idx].isFinite,
                isTrue,
                reason: '$name screen finite at t=$t',
              );
              expect(
                mesh.lum[idx],
                inInclusiveRange(kAmbient - 1e-9, 1 + 1e-9),
                reason: '$name lum in [ambient,1] at t=$t',
              );
              expect(
                mesh.spec[idx],
                inInclusiveRange(-1e-9, sheenCap + 1e-9),
                reason: '$name spec within its own spec ceiling at t=$t',
              );
            }
            final tip = (mesh.nv ~/ 2) * mesh.nu + (mesh.nu - 1);
            if (px != null) {
              expect(
                (mesh.sx[tip] - px).abs(),
                lessThan(w * 0.4),
                reason: '$name no x teleport at t=$t',
              );
              expect(
                (mesh.sy[tip] - py!).abs(),
                lessThan(h * 0.4),
                reason: '$name no y teleport at t=$t',
              );
            }
            px = mesh.sx[tip];
            py = mesh.sy[tip];
          }
        }
      }
    });

    test('lerp blends endpoints and the midpoint', () {
      const a = BookFlipMaterial.paper;
      const b = BookFlipMaterial.magazine;
      expect(BookFlipMaterial.lerp(a, b, 0), a);
      expect(BookFlipMaterial.lerp(a, b, 1), b);
      final mid = BookFlipMaterial.lerp(a, b, 0.5);
      expect(mid.stiffness, closeTo((a.stiffness + b.stiffness) / 2, 1e-12));
      expect(mid.gloss, closeTo((a.gloss + b.gloss) / 2, 1e-12));
      expect(mid.thickness, closeTo((a.thickness + b.thickness) / 2, 1e-12));
    });

    test('value equality, hashCode and copyWith', () {
      const a = BookFlipMaterial(stiffness: 0.4, gloss: 0.8);
      const b = BookFlipMaterial(stiffness: 0.4, gloss: 0.8);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(
        a.copyWith(gloss: 0.1),
        const BookFlipMaterial(stiffness: 0.4, gloss: 0.1),
      );
      expect(a, isNot(equals(a.copyWith(stiffness: 0.5))));
    });

    test('asserts reject out-of-range dials but accept the [0,1] edges', () {
      expect(() => BookFlipMaterial(stiffness: 1.2), throwsAssertionError);
      expect(() => BookFlipMaterial(gloss: -0.1), throwsAssertionError);
      expect(() => BookFlipMaterial(weight: 2), throwsAssertionError);
      expect(() => BookFlipMaterial(thickness: -1), throwsAssertionError);
      expect(
        const BookFlipMaterial(
          stiffness: 0,
          gloss: 1,
          weight: 1,
          thickness: 0,
        ),
        isNotNull,
      );
    });
  });

  group('paper texture [grain — visible, material-driven, pop-free]', () {
    test(
        'grain field is bounded, deterministic, varied, ~zero-mean (a real field)',
        () {
      var lo = 1e9, hi = -1e9, sum = 0.0, sumSq = 0.0, count = 0.0;
      for (var iu = 0; iu <= 90; iu++) {
        for (var iv = 0; iv <= 90; iv++) {
          final u = iu / 90.0, v = iv / 90.0;
          final g = bookFlipGrainAt(u, v);
          expect(g, inInclusiveRange(-1.0, 1.0),
              reason: 'grain must stay in [-1,1]');
          expect(g, bookFlipGrainAt(u, v),
              reason: 'grain must be deterministic');
          lo = math.min(lo, g);
          hi = math.max(hi, g);
          sum += g;
          sumSq += g * g;
          count += 1;
        }
      }
      final mean = sum / count;
      final std = math.sqrt(sumSq / count - mean * mean);
      expect(hi - lo, greaterThan(0.8),
          reason: 'grain must actually vary (not flat)');
      expect(std, greaterThan(0.2),
          reason: 'grain must carry real texture energy');
      expect(
        mean.abs(),
        lessThan(0.12),
        reason: 'grain must be ~zero-mean → no DC brightness bias',
      );
    });

    test(
        'tooth mapping: default == kTooth, matte > glossy, monotone down in gloss',
        () {
      expect(bookFlipTooth(BookFlipMaterial.paper), kTooth);
      expect(
        bookFlipTooth(const BookFlipMaterial(gloss: 0.0)),
        greaterThan(bookFlipTooth(BookFlipMaterial.magazine)),
        reason: 'matte stock is toothier than coated magazine',
      );
      var prev = 2.0;
      for (var gl = 0.0; gl <= 1.0001; gl += 0.1) {
        final tooth =
            bookFlipTooth(BookFlipMaterial(gloss: gl.clamp(0.0, 1.0)));
        expect(
          tooth,
          lessThanOrEqualTo(prev + 1e-12),
          reason: 'tooth must fall as gloss rises (gloss=$gl)',
        );
        prev = tooth;
      }
    });

    test(
        'grain is TRULY VISIBLE mid-flip, and rougher stock shows strictly more',
        () {
      ({double rms, double maxd}) lumDiff(
          BookFlipMaterial a, BookFlipMaterial b) {
        final ma = BookFlipMesh(nu: 120, nv: 84)
          ..computeWorld(w, h, 0.5, 0.5, 1, material: a)
          ..computeNormals()
          ..computeShading(w, h, fov, material: a);
        final mb = BookFlipMesh(nu: 120, nv: 84)
          ..computeWorld(w, h, 0.5, 0.5, 1, material: b)
          ..computeNormals()
          ..computeShading(w, h, fov, material: b);
        var ss = 0.0, mx = 0.0;
        for (var i = 0; i < ma.n; i++) {
          final d = (ma.lum[i] - mb.lum[i]).abs();
          ss += d * d;
          if (d > mx) mx = d;
        }
        return (rms: math.sqrt(ss / ma.n), maxd: mx);
      }

      const rough = BookFlipMaterial(stiffness: 0.5, gloss: 0.05);
      const smooth = BookFlipMaterial(stiffness: 0.5, gloss: 0.95);
      final d = lumDiff(rough, smooth);
      expect(
        d.maxd,
        greaterThan(0.03),
        reason: 'grain must be genuinely visible somewhere (>3% brightness)',
      );
      expect(
        d.rms,
        greaterThan(0.008),
        reason:
            'material-driven grain must be a real, broad signal (not a dead param)',
      );
    });

    test(
        'grain adds NOTHING at the flat rest states (pop-free, even toothiest stock)',
        () {
      for (final m in [
        const BookFlipMaterial(gloss: 0.0),
        BookFlipMaterial.paper,
        BookFlipMaterial.magazine,
      ]) {
        for (final t in [0.0, 1.0]) {
          final mesh = BookFlipMesh()
            ..computeWorld(w, h, t, 0.5, 1, material: m)
            ..computeNormals()
            ..computeShading(w, h, fov, material: m);
          for (var i = 0; i < mesh.n; i++) {
            expect(
              mesh.lum[i],
              closeTo(1.0, 1e-9),
              reason: 'grain must vanish when flat (lum=1 == base)',
            );
          }
        }
      }
    });
  });

  group('coated white gloss [optional, magazine-tier, pop-free]', () {
    test('coat is OFF for matte/semigloss & default, ON for glossy magazine',
        () {
      expect(bookFlipCoat(BookFlipMaterial.paper), 0.0,
          reason: 'default → no coat');
      for (final m in [
        const BookFlipMaterial(gloss: 0.0),
        const BookFlipMaterial(gloss: 0.3),
        const BookFlipMaterial(gloss: 0.5),
        const BookFlipMaterial(gloss: 0.61),
      ]) {
        expect(bookFlipCoat(m), 0.0,
            reason: 'non-magazine stock must carry no coat');
      }
      expect(
        bookFlipCoat(BookFlipMaterial.magazine),
        greaterThan(0.5),
        reason: 'glossy magazine must engage a strong coat',
      );
    });

    test('coat is monotone non-decreasing & continuous in gloss (smoothstep)',
        () {
      var prev = -1.0;
      double? pf;
      for (var gl = 0.0; gl <= 1.0001; gl += 0.02) {
        final c = bookFlipCoat(BookFlipMaterial(gloss: gl.clamp(0.0, 1.0)));
        expect(c, inInclusiveRange(0.0, 1.0));
        expect(c, greaterThanOrEqualTo(prev - 1e-12),
            reason: 'coat must be monotone');
        if (pf != null) {
          expect((c - pf).abs(), lessThan(0.1),
              reason: 'coat must be continuous');
        }
        prev = c;
        pf = c;
      }
    });

    test(
        'coat lifts the highlight above the matte sheen cap (the bright white gloss)',
        () {
      double peakSpec(BookFlipMaterial m) {
        var hi = 0.0;
        for (var t = 0.05; t < 0.96; t += 0.05) {
          final mesh = BookFlipMesh(nu: 120, nv: 84)
            ..computeWorld(w, h, t, 0.5, 1, material: m)
            ..computeNormals()
            ..computeShading(w, h, fov, material: m);
          for (var i = 0; i < mesh.n; i++) {
            if (mesh.spec[i] > hi) hi = mesh.spec[i];
          }
        }
        return hi;
      }

      const coated = BookFlipMaterial(stiffness: 0.5, gloss: 1.0);
      const matte = BookFlipMaterial(stiffness: 0.5, gloss: 0.0);
      expect(
        peakSpec(coated),
        greaterThan(peakSpec(matte)),
        reason: 'coated gloss must out-peak matte',
      );
      expect(
        peakSpec(coated),
        greaterThan(bookFlipSheen(matte)),
        reason: 'the coat must exceed the plain matte sheen ceiling',
      );

      expect(
          peakSpec(coated), lessThanOrEqualTo(bookFlipSpecMax(coated) + 1e-9));
    });

    test(
        'coat stays a COMPACT highlight across the flip, never a form-washing glow',
        () {
      var curled = 0, hot = 0;
      for (var t = 0.2; t <= 0.8001; t += 0.1) {
        final mesh = BookFlipMesh(nu: 120, nv: 84)
          ..computeWorld(w, h, t, 0.5, 1, material: BookFlipMaterial.magazine)
          ..computeNormals()
          ..computeShading(w, h, fov, material: BookFlipMaterial.magazine);
        for (var i = 0; i < mesh.n; i++) {
          final curl = 1.0 - mesh.nrz[i].abs().clamp(0.0, 1.0);
          if (curl > 0.15) {
            curled++;
            if (mesh.spec[i] > 0.30) hot++;
          }
        }
      }
      expect(
        curled,
        greaterThan(500),
        reason: 'the flip must present a substantially curved page',
      );
      expect(
        hot / curled,
        lessThan(0.25),
        reason:
            'a broad wash lights most curled vertices; the coat must stay compact',
      );
    });

    test('specMax: default == kSheen; coated magazine > kSheen', () {
      expect(bookFlipSpecMax(BookFlipMaterial.paper), kSheen);
      expect(bookFlipSpecMax(BookFlipMaterial.magazine), greaterThan(kSheen));
    });

    test('coat vanishes at the flat rest states (optional gloss never pops)',
        () {
      for (final t in [0.0, 1.0]) {
        for (final dir in [1, -1]) {
          final mesh = BookFlipMesh()
            ..computeWorld(
              w,
              h,
              t,
              0.5,
              dir,
              material: BookFlipMaterial.magazine,
            )
            ..computeNormals()
            ..computeShading(w, h, fov, material: BookFlipMaterial.magazine);
          for (var i = 0; i < mesh.n; i++) {
            expect(
              mesh.spec[i],
              closeTo(0.0, 1e-9),
              reason: 'glossy coat must be 0 when flat (t=$t dir=$dir)',
            );
          }
        }
      }
    });
  });
}
