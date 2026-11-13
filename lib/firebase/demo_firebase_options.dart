import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Options for the local emulators.
///
/// A project id starting with `demo-` tells the Firebase SDKs and the
/// emulators that no real project exists: nothing can reach the cloud, and
/// no credentials are needed. The ids below are fake but well-formed (the
/// iOS SDK checks the app id format).
abstract final class DemoFirebaseOptions {
  static const String projectId = 'demo-school-carpool';

  static FirebaseOptions get currentPlatform {
    final String platform = kIsWeb
        ? 'web'
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => 'android',
            _ => 'ios',
          };
    return FirebaseOptions(
      apiKey: 'demo-api-key',
      appId: '1:123456789012:$platform:0123456789abcdef',
      messagingSenderId: '123456789012',
      projectId: projectId,
      storageBucket: '$projectId.appspot.com',
      authDomain: '$projectId.firebaseapp.com',
    );
  }
}
