import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// The result of a fresh Face ID, fingerprint or passcode check.
enum DeviceAuthResult {
  /// The parent confirmed.
  ok,

  /// The parent cancelled or the check failed: nothing is sent.
  cancelled,

  /// The phone has no passcode, Face ID or fingerprint: the parent must set
  /// one before money can be sent (MONEY rules: no transfer without it).
  unavailable,
}

/// A fresh check right before every transfer and withdrawal (MONEY rules).
/// Never cached: each call asks the phone again.
abstract interface class DeviceAuth {
  Future<DeviceAuthResult> confirm(String reason);
}

/// iPhone: Face ID or Touch ID, falling back to the phone passcode
/// (NSFaceIDUsageDescription in Info.plist, tool/patch_native.py).
/// Android: fingerprint, face or the screen lock (MainActivity is a
/// FlutterFragmentActivity, tool/patch_native.py). The website has no
/// such check: the wallet asks for the phone app there (Stage 2).
class LocalDeviceAuth implements DeviceAuth {
  LocalDeviceAuth([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<DeviceAuthResult> confirm(String reason) async {
    if (kIsWeb) {
      return DeviceAuthResult.unavailable;
    }
    try {
      if (!await _auth.isDeviceSupported()) {
        return DeviceAuthResult.unavailable;
      }
      // Biometrics or the phone passcode (biometricOnly is false by default).
      final bool ok = await _auth.authenticate(localizedReason: reason);
      return ok ? DeviceAuthResult.ok : DeviceAuthResult.cancelled;
    } on Object {
      // LocalAuthException (no passcode set, locked out, cancelled) and
      // platform errors: fail closed, nothing is sent.
      debugPrint('wallet: device check failed');
      return DeviceAuthResult.cancelled;
    }
  }
}

final Provider<DeviceAuth> deviceAuthProvider = Provider<DeviceAuth>((Ref ref) => LocalDeviceAuth());
