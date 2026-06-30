import 'package:book_page_flip/src/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const w = 412.0;
  const h = 732.0;
  const fov = kFovY;
  const dir = 1;

  group('shading | cast-fade C1 slope', () {
    test('bookFlipCastFade has ~ZERO slope at contact (not a linear ramp)', () {
      const eps = 1e-4;
      final f0 = bookFlipCastFade(0.0);
      expect(f0, closeTo(0.0, 1e-12), reason: 'fade is 0 exactly at contact');

      final slope0 = (bookFlipCastFade(eps) - f0) / eps;
      expect(
        slope0.abs(),
        lessThan(0.1),
        reason: 'contact slope must be ~0 (linear ramp would be ~1/kCastFade)',
      );

      const mid = kCastFade * 0.5;
      final slopeMid =
          (bookFlipCastFade(mid + eps) - bookFlipCastFade(mid - eps)) /
              (2 * eps);
      expect(
        slopeMid,
        greaterThan(10 * slope0.abs()),
        reason: 'C1 ease-in: mid slope >> contact slope (linear: equal)',
      );
    });
  });

  group('shading | translucency curvature-gate', () {
    test('translucency lift obeys the curl^2 gate (mutant drops *curl)', () {
      const mat = BookFlipMaterial(translucency: 1.0);
      final trans = bookFlipTranslucency(mat);
      expect(trans, greaterThan(0.0), reason: 'material must be translucent');

      const transOn = BookFlipEffects(grain: false);
      const transOff = BookFlipEffects(grain: false, translucency: false);
      final a = BookFlipMesh()
        ..computeWorld(w, h, 0.5, 0.5, dir, material: mat)
        ..computeNormals()
        ..computeShading(w, h, fov, material: mat, effects: transOn);
      final lumOn = List<double>.from(a.lum);
      final b = BookFlipMesh()
        ..computeWorld(w, h, 0.5, 0.5, dir, material: mat)
        ..computeNormals()
        ..computeShading(w, h, fov, material: mat, effects: transOff);
      final lumOff = List<double>.from(b.lum);

      var worstErr = 0.0;
      var worstCurl = 0.0;
      var maxLiftLow = 0.0;
      var minLiftHigh = double.infinity;
      var nLow = 0;
      var nHigh = 0;
      for (var i = 0; i < a.n; i++) {
        final curl = 1.0 - a.nrz[i].abs();
        final lift = lumOn[i] - lumOff[i];
        final expected = trans * (1.0 - kAmbient) * curl * curl;
        final err = (lift - expected).abs();
        if (err > worstErr) {
          worstErr = err;
          worstCurl = curl;
        }
        if (curl > 0.015 && curl < 0.1) {
          nLow++;
          if (lift > maxLiftLow) maxLiftLow = lift;
        }
        if (curl > 0.5) {
          nHigh++;
          if (lift < minLiftHigh) minLiftHigh = lift;
        }
      }

      expect(
        worstErr,
        lessThan(1e-9),
        reason: 'curl^2 translucency gate violated (worst at curl=$worstCurl)',
      );
      expect(nLow, greaterThan(0), reason: 'need low-curvature samples');
      expect(nHigh, greaterThan(0), reason: 'need curved samples');

      expect(
        maxLiftLow,
        lessThan(0.005),
        reason: 'low-curvature vertices must NOT be lit by translucency',
      );

      expect(
        minLiftHigh,
        greaterThan(0.05),
        reason: 'curved vertices must be lifted by translucency',
      );
    });
  });

  group('shading | coat magnitude', () {
    test('peak coat specular for magazine at mid-flip keeps its magnitude', () {
      const mag = BookFlipMaterial.magazine;
      final m = BookFlipMesh()
        ..computeWorld(w, h, 0.5, 0.5, dir, material: mag)
        ..computeNormals()
        ..computeShading(w, h, fov, material: mag);
      var peak = 0.0;
      var peakCurl = 0.0;
      for (var i = 0; i < m.n; i++) {
        final curl = 1.0 - m.nrz[i].abs();
        if (curl < 0.25 && m.spec[i] > peak) {
          peak = m.spec[i];
          peakCurl = curl;
        }
      }

      const goldenCoatPeak = 0.0589797;
      expect(
        peakCurl,
        lessThan(0.2),
        reason: 'coat glint must sit at low curvature (faces the light)',
      );
      expect(
        peak,
        greaterThan(0.9 * goldenCoatPeak),
        reason: 'coat glint must not be dimmed (mutant knee*4 -> ~0.0067)',
      );
      expect(
        peak,
        lessThan(1.1 * goldenCoatPeak),
        reason: 'coat glint magnitude pinned to the calibrated value',
      );
    });
  });

  group('shading | specular grain', () {
    test('grain perturbs the SPEC field on matte stock at mid-flip', () {
      const matte = BookFlipMaterial(gloss: 0.0);
      const noGrain = BookFlipEffects(grain: false);
      final on = BookFlipMesh()
        ..computeWorld(w, h, 0.5, 0.5, dir, material: matte)
        ..computeNormals()
        ..computeShading(w, h, fov, material: matte);
      final specOn = List<double>.from(on.spec);
      final off = BookFlipMesh()
        ..computeWorld(w, h, 0.5, 0.5, dir, material: matte)
        ..computeNormals()
        ..computeShading(w, h, fov, material: matte, effects: noGrain);
      final specOff = List<double>.from(off.spec);

      var maxAbsDiff = 0.0;
      var nUp = 0;
      var nDown = 0;
      for (var i = 0; i < on.n; i++) {
        final d = specOn[i] - specOff[i];
        if (d.abs() > maxAbsDiff) maxAbsDiff = d.abs();
        if (d > 1e-7) nUp++;
        if (d < -1e-7) nDown++;
      }

      expect(
        maxAbsDiff,
        greaterThan(1e-5),
        reason: 'grain must perturb the SPEC field (mutant zeroes it)',
      );
      expect(
        nUp,
        greaterThan(0),
        reason: 'some vertices must sparkle brighter (grain g>0)',
      );
      expect(
        nDown,
        greaterThan(0),
        reason: 'some vertices must sparkle dimmer (grain g<0)',
      );
    });
  });
}
