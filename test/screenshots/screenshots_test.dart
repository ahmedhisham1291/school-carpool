// Screenshots for the owner (no Mac needed). Written, not run here.
//
// Renders the tab shell and the component gallery in Arabic and English,
// light and dark (gallery also in design directions A and B) with the real
// bundled fonts, and writes PNGs to test/screenshots/goldens/. The shell is
// also rendered on a small 320 dp phone, at normal and at 200 percent text,
// to show that tab labels stay on one line.
//
// These tests only run with --update-goldens (they are skipped in a plain
// `flutter test`, so there are no committed images to compare against):
//
//   flutter test test/screenshots --update-goldens
//
// CI (.github/workflows/checks.yml) runs this and uploads the folder as the
// "screenshots" artifact.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/fonts.dart';
import '../helpers/test_app.dart';

Future<void> _pumpScreen(
  WidgetTester tester, {
  required String location,
  required String locale,
  required String themeMode,
  required String direction,
  required Size logicalSize,
  required double pixelRatio,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = pixelRatio
    ..physicalSize = logicalSize * pixelRatio;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final GoRouter router = buildAppRouter(showDevTools: true, initialLocation: location);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testDevConfig),
        settingsStoreProvider.overrideWithValue(
          InMemorySettingsStore(<String, String>{
            LocaleController.storageKey: locale,
            ThemeModeController.storageKey: themeMode,
            DesignDirectionController.storageKey: direction,
          }),
        ),
        routerProvider.overrideWithValue(router),
      ],
      child: const CarpoolApp(),
    ),
  );
  // The gallery has a looping skeleton animation: pump frames, do not settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadAppFonts);

  const List<String> locales = <String>['ar', 'en'];
  const List<String> modes = <String>['light', 'dark'];
  // Only render when asked to write images (see the header).
  final bool skip = !autoUpdateGoldenFiles;

  // Tab shell: Home and Profile (settings), direction A, iPhone 13 size.
  for (final String tab in <String>['home', 'profile']) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'shell_${tab}_a_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: '/$tab',
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Small phone (320 dp wide), Home tab, normal and 200 percent text: the
  // tab labels must stay on one line.
  for (final double scale in <double>[1, 2]) {
    for (final String locale in locales) {
      final String name = 'shell_home_a_${locale}_light_320_text${scale.round()}x';
      testWidgets(name, skip: skip, (WidgetTester tester) async {
        await _pumpScreen(
          tester,
          location: '/home',
          locale: locale,
          themeMode: 'light',
          direction: 'a',
          logicalSize: const Size(320, 640),
          pixelRatio: 3,
          textScale: scale,
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
      });
    }
  }

  // Gallery: every component, both directions. Tall canvas so the whole
  // list is in one image.
  for (final String direction in <String>['a', 'b']) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'gallery_${direction}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: AppRoutes.gallery,
            locale: locale,
            themeMode: mode,
            direction: direction,
            logicalSize: const Size(390, 6400),
            pixelRatio: 2,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }
}
