// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI on Codemagic: `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

double contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('spacing', () {
    test('every value sits on the 8-point grid (4 is the only half step)', () {
      for (final double value in AppSpacing.all) {
        expect(value % 4, 0, reason: '$value is not a multiple of 4');
        if (value != AppSpacing.s4) {
          expect(value % 8, 0, reason: '$value is not a multiple of 8');
        }
      }
    });

    test('touch targets are at least 48', () {
      expect(AppSpacing.minTouchTarget, greaterThanOrEqualTo(48));
      expect(AppSpacing.driverTouchTarget, greaterThan(AppSpacing.minTouchTarget));
    });
  });

  group('type scale', () {
    final TextTheme text = AppTypeScale.textTheme('IBMPlexSansArabic');

    test('body text is at least 16', () {
      expect(text.bodyMedium!.fontSize, greaterThanOrEqualTo(AppTypeScale.minBodySize));
      expect(text.bodyLarge!.fontSize, greaterThanOrEqualTo(AppTypeScale.minBodySize));
      expect(text.labelLarge!.fontSize, greaterThanOrEqualTo(AppTypeScale.minBodySize));
    });

    test('no letter spacing (it breaks Arabic joins)', () {
      final List<TextStyle?> styles = <TextStyle?>[
        text.displayLarge, text.headlineMedium, text.titleLarge, text.titleMedium,
        text.bodyLarge, text.bodyMedium, text.bodySmall, text.labelLarge,
      ];
      for (final TextStyle? style in styles) {
        expect(style!.letterSpacing, 0);
        expect(style.fontFamily, 'IBMPlexSansArabic');
      }
    });
  });

  group('colors meet WCAG AA in both directions and brightnesses', () {
    for (final DesignDirection direction in DesignDirection.values) {
      for (final Brightness brightness in Brightness.values) {
        final AppPalette p = direction.palette(brightness);
        final ColorScheme c = p.scheme;
        final StatusColors s = p.status;

        test('${direction.name} ${brightness.name}', () {
          final Map<String, (Color, Color, double)> pairs = <String, (Color, Color, double)>{
            'onPrimary/primary': (c.onPrimary, c.primary, 4.5),
            'onPrimaryContainer': (c.onPrimaryContainer, c.primaryContainer, 4.5),
            'onSecondaryContainer': (c.onSecondaryContainer, c.secondaryContainer, 4.5),
            'onSurface/surface': (c.onSurface, c.surface, 4.5),
            'onSurfaceVariant/surface': (c.onSurfaceVariant, c.surface, 4.5),
            'onSurfaceVariant/highest': (c.onSurfaceVariant, c.surfaceContainerHighest, 4.5),
            'onSurfaceVariant/lowest': (c.onSurfaceVariant, c.surfaceContainerLowest, 4.5),
            'primary text/surface': (c.primary, c.surface, 4.5),
            'primary text/lowest': (c.primary, c.surfaceContainerLowest, 4.5),
            'onError/error': (c.onError, c.error, 4.5),
            'onErrorContainer': (c.onErrorContainer, c.errorContainer, 4.5),
            'error text/surface': (c.error, c.surface, 4.5),
            'success text/surface': (s.success, c.surface, 4.5),
            'warning text/surface': (s.warning, c.surface, 4.5),
            'onSuccessContainer': (s.onSuccessContainer, s.successContainer, 4.5),
            'onWarningContainer': (s.onWarningContainer, s.warningContainer, 4.5),
            // Borders of inputs are UI components: 3:1.
            'outline/surface': (c.outline, c.surface, 3.0),
          };
          pairs.forEach((String name, (Color, Color, double) pair) {
            final double ratio = contrast(pair.$1, pair.$2);
            expect(ratio, greaterThanOrEqualTo(pair.$3), reason: '$name is ${ratio.toStringAsFixed(2)}');
          });
        });
      }
    }
  });

  group('theme', () {
    for (final DesignDirection direction in DesignDirection.values) {
      test('${direction.name} builds light and dark Material 3 themes', () {
        final ThemeData light = AppTheme.light(direction);
        final ThemeData dark = AppTheme.dark(direction);
        expect(light.useMaterial3, isTrue);
        expect(light.brightness, Brightness.light);
        expect(dark.brightness, Brightness.dark);
        expect(light.extension<AppColors>(), isNotNull);
        expect(dark.extension<AppColors>(), isNotNull);
        expect(light.colorScheme.primary, direction.light.scheme.primary);
        expect(light.textTheme.bodyMedium!.fontFamily, direction.fontFamily);
      });
    }

    test('the two directions really differ', () {
      expect(
        DesignDirection.a.light.scheme.primary,
        isNot(DesignDirection.b.light.scheme.primary),
      );
      expect(DesignDirection.a.fontFamily, isNot(DesignDirection.b.fontFamily));
    });

    test('unknown saved direction falls back to A', () {
      expect(DesignDirection.fromName('z'), DesignDirection.a);
      expect(DesignDirection.fromName(null), DesignDirection.a);
      expect(DesignDirection.fromName('b'), DesignDirection.b);
    });
  });

  group('motion', () {
    testWidgets('durations collapse to zero when the phone reduces motion', (WidgetTester tester) async {
      late Duration reduced;
      late Duration iosReduced;
      late Duration normal;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
          children: <Widget>[
            MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Builder(
                builder: (BuildContext context) {
                  reduced = AppMotion.resolve(context, AppMotion.normal);
                  return const SizedBox();
                },
              ),
            ),
            // iOS "Reduce Motion" arrives as reduceMotion, not disableAnimations.
            MediaQuery(
              data: const MediaQueryData(reduceMotion: true),
              child: Builder(
                builder: (BuildContext context) {
                  iosReduced = AppMotion.resolve(context, AppMotion.normal);
                  return const SizedBox();
                },
              ),
            ),
            MediaQuery(
              data: const MediaQueryData(),
              child: Builder(
                builder: (BuildContext context) {
                  normal = AppMotion.resolve(context, AppMotion.normal);
                  return const SizedBox();
                },
              ),
            ),
          ],
          ),
        ),
      );
      expect(reduced, Duration.zero);
      expect(iosReduced, Duration.zero);
      expect(normal, AppMotion.normal);
    });

    test('reduced-motion theme has no page transitions or button animation', () {
      final ThemeData theme = AppTheme.light(DesignDirection.a, reduceMotion: true);
      expect(
        theme.pageTransitionsTheme.builders[TargetPlatform.iOS],
        isA<NoMotionPageTransitionsBuilder>(),
      );
      expect(
        theme.filledButtonTheme.style!.animationDuration,
        Duration.zero,
      );
      expect(AppTheme.light(DesignDirection.a).filledButtonTheme.style!.animationDuration, AppMotion.fast);
    });
  });
}
