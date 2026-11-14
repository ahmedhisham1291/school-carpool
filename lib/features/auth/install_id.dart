import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Random ID for this app install, used only for the server's limit on
/// sign-in codes per device. It says nothing about the parent or the phone
/// (no hardware ID) and is reset by reinstalling. The server stores only a
/// keyed hash of it.
abstract final class InstallId {
  static const String storageKey = 'device.installId';
  static final RegExp pattern = RegExp(r'^[0-9a-f]{32}$');

  /// 16 random bytes as 32 lowercase hex characters.
  static String generate([Random? random]) {
    final Random source = random ?? Random.secure();
    return List<String>.generate(
      16,
      (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

final Provider<String> installIdProvider = Provider<String>((Ref ref) {
  final SettingsStore store = ref.watch(settingsStoreProvider);
  final String? saved = store.read(InstallId.storageKey);
  if (saved != null && InstallId.pattern.hasMatch(saved)) {
    return saved;
  }
  final String id = InstallId.generate();
  unawaited(store.write(InstallId.storageKey, id));
  return id;
});

/// "ios", "android" or "web": shown in the parent's list of phones
/// (Prompt 12). Never a model name or a hardware ID.
String platformName() {
  if (kIsWeb) {
    return 'web';
  }
  return defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios';
}
