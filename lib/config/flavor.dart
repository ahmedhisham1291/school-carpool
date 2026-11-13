import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum Flavor { dev, staging, prod }

/// Build-time configuration for one flavor.
///
/// Values come from `--dart-define` (or `--dart-define-from-file`), never from
/// files in the repository. See README.md for the full list of defines.
@immutable
class FlavorConfig {
  const FlavorConfig({
    required this.flavor,
    required this.useEmulators,
    required this.emulatorHost,
    required this.sentryDsn,
    required this.sentrySampleRate,
    required this.recaptchaSiteKey,
    required this.appCheckDebugToken,
    required this.mapsEnabled,
  });

  /// Reads the defines for [flavor]. Emulators are only allowed in dev.
  factory FlavorConfig.fromEnvironment(Flavor flavor) {
    const bool useEmulatorsDefine = bool.fromEnvironment('USE_EMULATORS', defaultValue: true);
    const String emulatorHost = String.fromEnvironment('EMULATOR_HOST');
    const String sentryDsn = String.fromEnvironment('SENTRY_DSN');
    const String sentrySampleRate = String.fromEnvironment('SENTRY_SAMPLE_RATE', defaultValue: '1.0');
    const String recaptchaSiteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');
    const String appCheckDebugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
    const bool mapsEnabled = bool.fromEnvironment('MAPS_ENABLED');

    final bool useEmulators = flavor == Flavor.dev && useEmulatorsDefine;
    return FlavorConfig(
      flavor: flavor,
      useEmulators: useEmulators,
      emulatorHost: emulatorHost.isNotEmpty ? emulatorHost : _defaultEmulatorHost(),
      sentryDsn: sentryDsn,
      sentrySampleRate: (double.tryParse(sentrySampleRate) ?? 1.0).clamp(0.0, 1.0),
      recaptchaSiteKey: recaptchaSiteKey,
      appCheckDebugToken: appCheckDebugToken,
      mapsEnabled: mapsEnabled,
    );
  }

  final Flavor flavor;

  /// Dev only: talk to the local Firebase emulators instead of a project.
  final bool useEmulators;

  /// Host of the emulators. A physical iPhone needs the Mac's LAN address,
  /// passed as `--dart-define=EMULATOR_HOST=192.168.x.x`.
  final String emulatorHost;

  /// Empty means Sentry is off for this build.
  final String sentryDsn;

  /// Share of error events sent to Sentry (free Developer plan: keep low in
  /// prod, see docs/COSTS.md).
  final double sentrySampleRate;

  /// reCAPTCHA Enterprise site key for App Check on the web.
  final String recaptchaSiteKey;

  /// Optional App Check debug token for debug builds on real devices.
  final String appCheckDebugToken;

  /// True when this build has a Google Maps key (`--dart-define=MAPS_ENABLED=true`,
  /// set together with the key; SETUP.md section 15). Without a key the
  /// maps show a sketch preview (dev) or a "map unavailable" note, never a
  /// crash.
  final bool mapsEnabled;

  bool get isDev => flavor == Flavor.dev;
  bool get isProd => flavor == Flavor.prod;

  /// Developer tools (gallery, design switch, test errors) are dev only.
  bool get showDevTools => flavor == Flavor.dev;

  bool get sentryEnabled => sentryDsn.isNotEmpty;

  static String _defaultEmulatorHost() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // The Android emulator reaches the host machine through this address.
      return '10.0.2.2';
    }
    return 'localhost';
  }
}

/// Overridden in `bootstrap.dart` with the real config for the flavor.
final Provider<FlavorConfig> flavorConfigProvider = Provider<FlavorConfig>(
  (Ref ref) => throw StateError('flavorConfigProvider must be overridden in bootstrap()'),
);
