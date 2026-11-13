import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small key-value store for device-only preferences (language, theme).
///
/// Never store personal data here: it is not encrypted.
abstract interface class SettingsStore {
  String? read(String key);
  Future<void> write(String key, String? value);
}

/// Production store backed by `shared_preferences`.
class SharedPrefsSettingsStore implements SettingsStore {
  SharedPrefsSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPrefsSettingsStore> create() async =>
      SharedPrefsSettingsStore(await SharedPreferences.getInstance());

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }
}

/// Store used in tests and as a safe default before bootstrap overrides it.
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([Map<String, String>? initial]) : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }
}

/// Overridden in `bootstrap.dart` with [SharedPrefsSettingsStore].
final Provider<SettingsStore> settingsStoreProvider = Provider<SettingsStore>(
  (Ref ref) => InMemorySettingsStore(),
);
