import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Dev config for tests: no emulators, no Sentry.
const FlavorConfig testDevConfig = FlavorConfig(
  flavor: Flavor.dev,
  useEmulators: false,
  emulatorHost: 'localhost',
  sentryDsn: '',
  sentrySampleRate: 1,
  recaptchaSiteKey: '',
  appCheckDebugToken: '',
);

/// Same as [testDevConfig] but for staging (no developer tools).
const FlavorConfig testStagingConfig = FlavorConfig(
  flavor: Flavor.staging,
  useEmulators: false,
  emulatorHost: 'localhost',
  sentryDsn: '',
  sentrySampleRate: 1,
  recaptchaSiteKey: '',
  appCheckDebugToken: '',
);

/// Wraps [home] in a MaterialApp with our localizations and theme.
Widget buildTestApp(
  Widget home, {
  Locale locale = AppLocales.arabic,
  Brightness brightness = Brightness.light,
  DesignDirection direction = DesignDirection.a,
  FlavorConfig config = testDevConfig,
  SettingsStore? store,
}) {
  return ProviderScope(
    overrides: [
      flavorConfigProvider.overrideWithValue(config),
      settingsStoreProvider.overrideWithValue(store ?? InMemorySettingsStore()),
    ],
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.build(direction, brightness),
      home: home,
    ),
  );
}
