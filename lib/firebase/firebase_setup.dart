import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/firebase/demo_firebase_options.dart';
import 'package:school_carpool/firebase/firebase_options_dev.dart' as dev;
import 'package:school_carpool/firebase/firebase_options_prod.dart' as prod;
import 'package:school_carpool/firebase/firebase_options_staging.dart' as staging;

/// Region of our Cloud Functions. Must match `REGION` in functions/src.
/// Open question for the owner and the lawyer (hosting abroad), see
/// docs/progress/prompt-01.md.
const String kFunctionsRegion = 'europe-west1';

/// Emulator ports, kept in sync with firebase.json.
abstract final class EmulatorPorts {
  static const int auth = 9099;
  static const int firestore = 8080;
  static const int functions = 5001;
  static const int storage = 9199;
}

FirebaseOptions firebaseOptionsFor(FlavorConfig config) => switch (config.flavor) {
  Flavor.dev when config.useEmulators => DemoFirebaseOptions.currentPlatform,
  Flavor.dev => dev.DefaultFirebaseOptions.currentPlatform,
  Flavor.staging => staging.DefaultFirebaseOptions.currentPlatform,
  Flavor.prod => prod.DefaultFirebaseOptions.currentPlatform,
};

/// Initializes Firebase for the flavor.
///
/// Dev with emulators: every SDK points at the local emulators and App Check
/// stays off. Everything else: App Check is activated before any call, so the
/// backend can enforce it (staging and prod enforce it on Functions,
/// Firestore and Storage; see SETUP.md).
Future<void> initFirebase(FlavorConfig config) async {
  await Firebase.initializeApp(options: firebaseOptionsFor(config));

  if (config.useEmulators) {
    await _useEmulators(config.emulatorHost);
    return;
  }
  await _activateAppCheck(config);
}

Future<void> _useEmulators(String host) async {
  await FirebaseAuth.instance.useAuthEmulator(host, EmulatorPorts.auth);
  FirebaseFirestore.instance.useFirestoreEmulator(host, EmulatorPorts.firestore);
  await FirebaseStorage.instance.useStorageEmulator(host, EmulatorPorts.storage);
  FirebaseFunctions.instanceFor(
    region: kFunctionsRegion,
  ).useFunctionsEmulator(host, EmulatorPorts.functions);
}

Future<void> _activateAppCheck(FlavorConfig config) async {
  if (kIsWeb && config.recaptchaSiteKey.isEmpty) {
    // Web App Check needs a reCAPTCHA Enterprise key; Stage 2 sets it up.
    return;
  }
  final String? debugToken = config.appCheckDebugToken.isEmpty ? null : config.appCheckDebugToken;
  await FirebaseAppCheck.instance.activate(
    providerApple: kDebugMode
        ? AppleDebugProvider(debugToken: debugToken)
        : const AppleAppAttestWithDeviceCheckFallbackProvider(),
    providerAndroid: kDebugMode
        ? AndroidDebugProvider(debugToken: debugToken)
        : const AndroidPlayIntegrityProvider(),
    providerWeb: config.recaptchaSiteKey.isEmpty
        ? null
        : ReCaptchaEnterpriseProvider(config.recaptchaSiteKey),
  );
}

/// Callable functions client in our region.
FirebaseFunctions functionsClient() => FirebaseFunctions.instanceFor(region: kFunctionsRegion);
