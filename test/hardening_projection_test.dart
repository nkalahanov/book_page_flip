import 'package:book_page_flip/src/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const w = 400.0, h = 300.0, fov = kFovY;
  final camDist = BookFlipMesh.camDistFor(h, fov);

  group('project() firewall: grazing / non-finite / behind-camera w', () {
    test(
        'a near-camera grazing vertex (0 < clip-w <= kWEps) trips the firewall '
        'and rests flat — never blanks [mutant: cw<=kWEps -> cw<0]', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
      const idx = 17;
      final wx = m.wx[idx], wy = m.wy[idx];

      m.wz[idx] = camDist - 5e-7;
      m.project(w, h, fov);
      for (var i = 0; i < m.n; i++) {
        expect(
          m.sx[i].isFinite && m.sy[i].isFinite,
          isTrue,
          reason: 'vertex $i went non-finite',
        );
      }
      expect(m.lastBadCount, 1, reason: 'grazing w must trip the firewall');
      final rest = bookFlipProjectPoint(wx, wy, 0.0, w, h, fov);
      expect(m.sx[idx], closeTo(rest.$1, 1e-6));
      expect(m.sy[idx], closeTo(rest.$2, 1e-6));
    });

    test(
        'an enormous clip-x over a near-zero clip-w overflows ndc to +inf; the '
        'firewall catches the non-finite ndc and rests the vertex finite '
        '[mutant: drop !ndcX.isFinite]', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
      const idx = 17;

      m.wz[idx] = camDist - 2e-6;

      m.wx[idx] = 1e305;
      final wx = m.wx[idx], wy = m.wy[idx];
      m.project(w, h, fov);
      for (var i = 0; i < m.n; i++) {
        expect(
          m.sx[i].isFinite && m.sy[i].isFinite,
          isTrue,
          reason: 'vertex $i went non-finite — ndc overflow leaked',
        );
      }
      expect(m.lastBadCount, 1, reason: 'ndc overflow must trip the firewall');

      final rest = bookFlipProjectPoint(wx, wy, 0.0, w, h, fov);
      expect(m.sx[idx], closeTo(rest.$1, rest.$1.abs() * 1e-9));
      expect(m.sy[idx], closeTo(rest.$2, 1e-6));
    });

    test(
        'the firewall never emits a non-finite or blank vertex for ANY poison '
        'clip-w (grazing, on-plane, behind, ±inf, NaN) — all rest flat', () {
      for (final pokeZ in <double>[
        camDist - 5e-7,
        camDist,
        camDist * 2.0,
        double.infinity,
        double.negativeInfinity,
        double.nan,
      ]) {
        final m = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
        const idx = 17;
        final wx = m.wx[idx], wy = m.wy[idx];
        m.wz[idx] = pokeZ;
        m.project(w, h, fov);
        for (var i = 0; i < m.n; i++) {
          expect(
            m.sx[i].isFinite && m.sy[i].isFinite,
            isTrue,
            reason: 'pokeZ=$pokeZ vertex $i non-finite',
          );
        }
        expect(m.lastBadCount, 1, reason: 'pokeZ=$pokeZ must trip firewall');
        final rest = bookFlipProjectPoint(wx, wy, 0.0, w, h, fov);
        expect(m.sx[idx], closeTo(rest.$1, 1e-6), reason: 'pokeZ=$pokeZ sx');
        expect(m.sy[idx], closeTo(rest.$2, 1e-6), reason: 'pokeZ=$pokeZ sy');
      }
    });
  });

  group('_restProject fallback body', () {
    test(
        'runs on the fallback path and reproduces the flat-rest projection '
        'exactly for every forced vertex [mutant: throw in _restProject]', () {
      final m = BookFlipMesh()..computeWorld(w, h, 0.5, 0.5, 1);
      const idxs = <int>[5, 17, 230, 600, 900];
      final wx = <double>[for (final i in idxs) m.wx[i]];
      final wy = <double>[for (final i in idxs) m.wy[i]];
      for (final i in idxs) {
        m.wz[i] = camDist * 2.0;
      }

      m.project(w, h, fov);
      expect(m.lastBadCount, idxs.length);
      for (var k = 0; k < idxs.length; k++) {
        final rest = bookFlipProjectPoint(wx[k], wy[k], 0.0, w, h, fov);
        expect(m.sx[idxs[k]], closeTo(rest.$1, 1e-6));
        expect(m.sy[idxs[k]], closeTo(rest.$2, 1e-6));
      }
    });
  });

  group('bookFlipProjectPoint firewall', () {
    test(
        'rests an at-camera (clip-w == 0) and a grazing (0 < clip-w <= kWEps) '
        'point — finite, not /~0 garbage [mutant: cw<=kWEps -> cw<0]', () {
      final atCam = bookFlipProjectPoint(0.0, 0.0, camDist, w, h, fov);
      expect(atCam.$3, lessThanOrEqualTo(0.0), reason: 'clip-w must be <= 0');
      expect(atCam.$1.isFinite, isTrue, reason: 'at-camera /0 leaked through');
      expect(atCam.$2.isFinite, isTrue);

      final flat = bookFlipProjectPoint(0.0, 0.0, 0.0, w, h, fov);
      expect(atCam.$1, closeTo(flat.$1, 1e-9));
      expect(atCam.$2, closeTo(flat.$2, 1e-9));

      final graz = bookFlipProjectPoint(0.0, 0.0, camDist - 5e-7, w, h, fov);
      expect(graz.$3, greaterThan(0.0));
      expect(graz.$3, lessThanOrEqualTo(kWEps));
      expect(
        graz.$1,
        closeTo(flat.$1, 1e-6),
        reason: 'grazing point must rest, not blow up',
      );
      expect(graz.$2, closeTo(flat.$2, 1e-6));
    });
  });

  group('boundaryResist elastic term', () {
    test(
        'is a real, strictly-rising, bounded curve — not the constant 0 '
        '[mutant: 0.10*(1-exp(-3x)) -> 0]', () {
      expect(boundaryResist(0.0), 0.0, reason: 'anchored at 0 (no jump in)');

      expect(boundaryResist(0.3), closeTo(0.0593430340, 1e-9));
      expect(boundaryResist(0.6), closeTo(0.0834701112, 1e-9));

      expect(boundaryResist(0.6), greaterThan(boundaryResist(0.3)));
      expect(boundaryResist(0.3), greaterThan(0.001));

      expect(boundaryResist(3.0), lessThan(0.10));
      expect(boundaryResist(3.0), greaterThan(0.099));
    });
  });

  group('bookFlipFaceFront tie-break', () {
    test(
        'treats an edge-on triangle (signedArea == 0) as FRONT for dir>0 '
        '[mutant: signedArea >= 0 -> signedArea > 0]', () {
      expect(bookFlipFaceFront(0.0, 1), isTrue);

      expect(bookFlipFaceFront(0.0, -1), isFalse);

      expect(bookFlipFaceFront(1.0, 1), isTrue);
      expect(bookFlipFaceFront(-1.0, 1), isFalse);
      expect(bookFlipFaceFront(-1.0, -1), isTrue);
      expect(bookFlipFaceFront(1.0, -1), isFalse);
    });
  });
}
