import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/notifications/push_messaging.dart';
import 'package:school_carpool/features/trips/geolocator_tracker.dart';
import 'package:school_carpool/features/trips/location_gate.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/observability/sentry_setup.dart';
import 'package:school_carpool/settings/settings_store.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Shared start-up for all flavors: Sentry first (so start-up errors are
/// reported), then Firebase (emulators in dev, App Check elsewhere), then
/// saved settings, then the app.
Future<void> bootstrap(Flavor flavor) async {
  final FlavorConfig config = FlavorConfig.fromEnvironment(flavor);

  await runWithSentry(
    config: config,
    appRunner: () async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await initFirebase(config);
      } on Object catch (error, stackTrace) {
        // Most likely: Firebase options not generated yet for this flavor.
        debugPrint('Firebase start-up failed: ${error.runtimeType}');
        if (config.sentryEnabled) {
          await Sentry.captureException(error, stackTrace: stackTrace);
        }
        runApp(const StartupErrorApp());
        return;
      }
      // Prompt 8: critical pushes schedule the app's own alarm while it is closed.
      registerPushBackgroundHandler();

      final SettingsStore store = await SharedPrefsSettingsStore.create();
      runApp(
        ProviderScope(
          overrides: [
            flavorConfigProvider.overrideWithValue(config),
            settingsStoreProvider.overrideWithValue(store),
            // Live location on the phone only (drivers never run a trip from
            // the website); tests and the web keep the fakes. Prompt 13: the
            // free geolocator plugin for every flavor (DECISIONS.md).
            if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android))
              locationTrackerProvider.overrideWithValue(GeolocatorTracker(store: store)),
            if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android))
              drivingReadinessProvider.overrideWithValue(const DeviceDrivingReadiness()),
            // Prompt 12: usage analytics on the phone (no PII; switch in Settings).
            if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android))
              analyticsSinkProvider.overrideWithValue(FirebaseAnalyticsSink()),
          ],
          child: const CarpoolApp(),
        ),
      );
    },
  );
}

/// Shown when Firebase cannot start. Arabic by default, like the app.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // No saved settings can be read here, so use the app default.
      locale: AppLocales.arabic,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.light(DesignDirection.a),
      darkTheme: AppTheme.dark(DesignDirection.a),
      home: const Scaffold(body: SafeArea(child: ErrorStateView())),
    );
  }
}
