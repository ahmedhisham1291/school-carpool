// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI on Codemagic: `flutter test`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/test_app.dart';

void main() {
  group('LocaleController', () {
    test('defaults to Arabic', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(localeProvider), AppLocales.arabic);
    });

    test('saves the choice and restores it on the next start', () async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final ProviderContainer first = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(first.dispose);

      await first.read(localeProvider.notifier).setLocale(AppLocales.english);
      expect(first.read(localeProvider), AppLocales.english);
      expect(store.read(LocaleController.storageKey), 'en');

      final ProviderContainer second = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(second.dispose);
      expect(second.read(localeProvider), AppLocales.english);
    });

    test('toggle switches between the two languages', () async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(localeProvider.notifier).toggle();
      expect(container.read(localeProvider), AppLocales.english);
      await container.read(localeProvider.notifier).toggle();
      expect(container.read(localeProvider), AppLocales.arabic);
    });

    test('an unsupported locale falls back to Arabic', () async {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(localeProvider.notifier).setLocale(const Locale('fr'));
      expect(container.read(localeProvider), AppLocales.arabic);
    });
  });

  group('ThemeModeController', () {
    test('follows the phone by default and saves a choice', () async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      expect(container.read(themeModeProvider), ThemeMode.system);
      await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark);
      expect(store.read(ThemeModeController.storageKey), 'dark');
    });
  });

  group('language switch in the app', () {
    Future<void> pumpCarpoolApp(WidgetTester tester, InMemorySettingsStore store) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            flavorConfigProvider.overrideWithValue(testDevConfig),
            settingsStoreProvider.overrideWithValue(store),
          ],
          child: const CarpoolApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    TextDirection directionOfShell(WidgetTester tester) =>
        Directionality.of(tester.element(find.byType(HomeShell)));

    testWidgets('starts in Arabic, right to left', (WidgetTester tester) async {
      await pumpCarpoolApp(tester, InMemorySettingsStore());
      expect(directionOfShell(tester), TextDirection.rtl);
      expect(find.text('الرئيسية'), findsWidgets);
    });

    testWidgets('switching to English flips the layout and is saved', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      await pumpCarpoolApp(tester, store);

      // Open the Profile tab, where the language switch lives.
      await tester.tap(find.byIcon(Icons.person_outline_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(directionOfShell(tester), TextDirection.ltr);
      expect(find.text('Profile'), findsWidgets);
      expect(store.read(LocaleController.storageKey), 'en');

      await tester.tap(find.text('العربية'));
      await tester.pumpAndSettle();
      expect(directionOfShell(tester), TextDirection.rtl);
    });

    testWidgets('a saved English choice is used at start', (WidgetTester tester) async {
      await pumpCarpoolApp(
        tester,
        InMemorySettingsStore(<String, String>{LocaleController.storageKey: 'en'}),
      );
      expect(directionOfShell(tester), TextDirection.ltr);
      expect(find.text('Home'), findsWidgets);
    });
  });
}
