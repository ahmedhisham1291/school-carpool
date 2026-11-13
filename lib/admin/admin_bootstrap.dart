import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/admin_app.dart';
import 'package:school_carpool/bootstrap.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/observability/sentry_setup.dart';
import 'package:school_carpool/settings/settings_store.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Start-up of the admin web panel (F14), like the app's bootstrap():
/// Sentry, Firebase (emulators in dev, App Check elsewhere), settings.
///
/// Short sessions: on the web the sign-in lives only as long as the browser
/// tab (Persistence.SESSION); the panel also signs out after 15 idle
/// minutes, and the functions refuse sessions older than 8 hours. The
/// browser's own context menu is turned off, so images cannot be saved
/// from it.
Future<void> adminBootstrap(Flavor flavor) async {
  final FlavorConfig config = FlavorConfig.fromEnvironment(flavor);

  await runWithSentry(
    config: config,
    appRunner: () async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await initFirebase(config);
        if (kIsWeb) {
          await FirebaseAuth.instance.setPersistence(Persistence.SESSION);
          await BrowserContextMenu.disableContextMenu();
        }
      } on Object catch (error, stackTrace) {
        debugPrint('Admin panel start-up failed: ${error.runtimeType}');
        if (config.sentryEnabled) {
          await Sentry.captureException(error, stackTrace: stackTrace);
        }
        runApp(const StartupErrorApp());
        return;
      }

      final SettingsStore store = await SharedPrefsSettingsStore.create();
      runApp(
        ProviderScope(
          overrides: [
            flavorConfigProvider.overrideWithValue(config),
            settingsStoreProvider.overrideWithValue(store),
          ],
          child: const AdminApp(),
        ),
      );
    },
  );
}
