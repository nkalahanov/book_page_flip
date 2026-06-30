import 'package:book_page_flip/src/engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapping sign (slope direction)', () {
    test('tilt: a floppy page folds its corners harder than a stiff one', () {
      const floppy = BookFlipMaterial(stiffness: 0.2);
      const stiff = BookFlipMaterial(stiffness: 0.9);
      expect(
        bookFlipTilt(floppy),
        greaterThan(bookFlipTilt(stiff)),
        reason: 'lower stiffness must give a larger per-row fold tilt',
      );
    });

    test('umbra: a thicker page casts a firmer shadow than a thin one', () {
      expect(
        bookFlipUmbra(const BookFlipMaterial(thickness: 2)),
        greaterThan(bookFlipUmbra(const BookFlipMaterial(thickness: 0.5))),
        reason: 'thicker stock must give a denser cast-shadow umbra',
      );
    });
  });

  group('mapping slope magnitude (span sensitivity)', () {
    test('bend-span sets bookFlipAmax (pinned off-default, unclamped)', () {
      expect(
        bookFlipAmax(const BookFlipMaterial(stiffness: 0.3)),
        closeTo(1.55232, 1e-6),
      );
    });

    test('sheen-span sets bookFlipSheen (pinned off-default, unclamped)', () {
      expect(
        bookFlipSheen(const BookFlipMaterial(gloss: 0.5)),
        closeTo(0.2376, 1e-6),
      );
    });

    test('shin-span sets bookFlipShininess (pinned off-default, unclamped)',
        () {
      expect(
        bookFlipShininess(const BookFlipMaterial(gloss: 0.5)),
        closeTo(33.072, 1e-6),
      );
    });
  });

  group('mapping clamp bands bind at the extremes', () {
    test('bookFlipAmax saturates at _kAmaxHi (1.72) for the floppiest stock',
        () {
      expect(bookFlipAmax(const BookFlipMaterial(stiffness: 0)), 1.72);
    });

    test('bookFlipSheen saturates at _kSheenHardCap (0.30) at full gloss', () {
      expect(bookFlipSheen(const BookFlipMaterial(gloss: 1)), 0.30);
    });

    test('bookFlipUmbra saturates at _kShadowHardCap (0.66) for thick stock',
        () {
      expect(bookFlipUmbra(const BookFlipMaterial(thickness: 6)), 0.66);
    });
  });

  group('BookFlipMaterial value contract', () {
    test('== separates EVERY field (no field dropped from ==)', () {
      const base = BookFlipMaterial.paper;

      expect(base, isNot(equals(const BookFlipMaterial(stiffness: 0.9))));
      expect(base, isNot(equals(const BookFlipMaterial(weight: 0.9))));
      expect(base, isNot(equals(const BookFlipMaterial(gloss: 0.9))));
      expect(base, isNot(equals(const BookFlipMaterial(translucency: 0.9))));
      expect(base, isNot(equals(const BookFlipMaterial(thickness: 9))));

      expect(base, equals(BookFlipMaterial.paper));
    });

    test('hashCode folds in EVERY field (none dropped from Object.hash)', () {
      const base = BookFlipMaterial.paper;

      expect(
        base.hashCode,
        isNot(equals(const BookFlipMaterial(stiffness: 0.9).hashCode)),
      );
      expect(
        base.hashCode,
        isNot(equals(const BookFlipMaterial(weight: 0.9).hashCode)),
      );
      expect(
        base.hashCode,
        isNot(equals(const BookFlipMaterial(gloss: 0.9).hashCode)),
      );
      expect(
        base.hashCode,
        isNot(equals(const BookFlipMaterial(translucency: 0.9).hashCode)),
      );
      expect(
        base.hashCode,
        isNot(equals(const BookFlipMaterial(thickness: 2).hashCode)),
      );
    });

    test('copyWith carries EVERY field through (none ignored)', () {
      const base = BookFlipMaterial.paper;

      expect(base.copyWith(stiffness: 0.9).stiffness, 0.9);
      expect(base.copyWith(weight: 0.7).weight, 0.7);
      expect(base.copyWith(gloss: 0.9).gloss, 0.9);
      expect(base.copyWith(translucency: 0.4).translucency, 0.4);
      expect(base.copyWith(thickness: 3).thickness, 3.0);

      expect(base.copyWith(thickness: 3).stiffness, base.stiffness);
    });

    test('lerp interpolates weight and translucency to the true midpoint', () {
      const a = BookFlipMaterial(weight: 0.2, translucency: 0.2);
      const b = BookFlipMaterial(weight: 0.8, translucency: 0.8);
      final mid = BookFlipMaterial.lerp(a, b, 0.5);
      expect(mid.weight, closeTo(0.5, 1e-12));
      expect(mid.translucency, closeTo(0.5, 1e-12));
    });

    test('translucency assert rejects values outside [0, 1]', () {
      expect(
        () => BookFlipMaterial(translucency: 1.01),
        throwsAssertionError,
      );
      expect(
        () => BookFlipMaterial(translucency: -0.01),
        throwsAssertionError,
      );

      expect(const BookFlipMaterial(translucency: 1), isNotNull);
    });
  });

  group('BookFlipCurl value contract', () {
    test('copyWith carries EVERY dial through (none ignored)', () {
      const base = BookFlipCurl();
      expect(base.copyWith(bend: 0.9).bend, 0.9);
      expect(base.copyWith(foldTilt: 0.9).foldTilt, 0.9);
      expect(base.copyWith(droop: 0.9).droop, 0.9);
    });

    test('lerp interpolates EVERY channel to the true midpoint', () {
      const a = BookFlipCurl(bend: 0.2, foldTilt: 0.2, droop: 0.2);
      const b = BookFlipCurl(bend: 0.8, foldTilt: 0.8, droop: 0.8);
      final mid = BookFlipCurl.lerp(a, b, 0.5);
      expect(mid.bend, closeTo(0.5, 1e-12));
      expect(mid.foldTilt, closeTo(0.5, 1e-12));
      expect(mid.droop, closeTo(0.5, 1e-12));
    });
  });

  group('BookFlipEffects value contract', () {
    test('== separates EVERY flag (no flag dropped from ==)', () {
      const base = BookFlipEffects.all;
      expect(base, isNot(equals(const BookFlipEffects(gloss: false))));
      expect(base, isNot(equals(const BookFlipEffects(grain: false))));
      expect(base, isNot(equals(const BookFlipEffects(castShadow: false))));
      expect(base, isNot(equals(const BookFlipEffects(spineShadow: false))));
      expect(base, isNot(equals(const BookFlipEffects(edge: false))));
      expect(base, isNot(equals(const BookFlipEffects(translucency: false))));
      expect(base, equals(BookFlipEffects.all));
    });

    test('copyWith carries EVERY flag through (none ignored)', () {
      const base = BookFlipEffects.all;
      expect(base.copyWith(gloss: false).gloss, isFalse);
      expect(base.copyWith(grain: false).grain, isFalse);
      expect(base.copyWith(castShadow: false).castShadow, isFalse);
      expect(base.copyWith(spineShadow: false).spineShadow, isFalse);
      expect(base.copyWith(edge: false).edge, isFalse);
      expect(base.copyWith(translucency: false).translucency, isFalse);
    });
  });

  group('BookFlipPhysics value contract', () {
    test('== separates EVERY field (no field dropped from ==)', () {
      const base = BookFlipPhysics();
      expect(
        base,
        isNot(equals(const BookFlipPhysics(springStiffness: 300))),
      );
      expect(
        base,
        isNot(equals(const BookFlipPhysics(springDampingRatio: 0.5))),
      );
      expect(
        base,
        isNot(equals(const BookFlipPhysics(commitThreshold: 0.7))),
      );
      expect(
        base,
        isNot(equals(const BookFlipPhysics(commitVelocity: 2))),
      );
      expect(
        base,
        isNot(equals(const BookFlipPhysics(velocityLookAhead: 0.3))),
      );
      expect(
        base,
        isNot(equals(const BookFlipPhysics(settleEpsilon: 0.01))),
      );
      expect(base, equals(const BookFlipPhysics()));
    });

    test('copyWith replaces EVERY field independently', () {
      const base = BookFlipPhysics();
      expect(
        base.copyWith(springStiffness: 99),
        equals(const BookFlipPhysics(springStiffness: 99)),
      );
      expect(
        base.copyWith(springDampingRatio: 0.6),
        equals(const BookFlipPhysics(springDampingRatio: 0.6)),
      );
      expect(
        base.copyWith(commitThreshold: 0.3),
        equals(const BookFlipPhysics(commitThreshold: 0.3)),
      );
      expect(
        base.copyWith(commitVelocity: 3),
        equals(const BookFlipPhysics(commitVelocity: 3)),
      );
      expect(
        base.copyWith(velocityLookAhead: 0.2),
        equals(const BookFlipPhysics(velocityLookAhead: 0.2)),
      );
      expect(
        base.copyWith(settleEpsilon: 0.02),
        equals(const BookFlipPhysics(settleEpsilon: 0.02)),
      );
      expect(base.copyWith(), equals(base));
    });

    test('asserts guard the documented ranges', () {
      expect(() => BookFlipPhysics(springStiffness: 0), throwsAssertionError);
      expect(
          () => BookFlipPhysics(springDampingRatio: 0), throwsAssertionError);
      expect(
          () => BookFlipPhysics(commitThreshold: -0.1), throwsAssertionError);
      expect(() => BookFlipPhysics(commitThreshold: 1.1), throwsAssertionError);
      expect(() => BookFlipPhysics(commitVelocity: 0), throwsAssertionError);
      expect(
        () => BookFlipPhysics(velocityLookAhead: -0.1),
        throwsAssertionError,
      );
      expect(() => BookFlipPhysics(settleEpsilon: 0), throwsAssertionError);
    });
  });
}
