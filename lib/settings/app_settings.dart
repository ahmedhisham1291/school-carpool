import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/theme/design_direction.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// The language shown before the person has chosen one. Arabic for the app;
/// the admin panel starts in English (owner decision, 15 Nov 2026).
final Provider<Locale> defaultLocaleProvider = Provider<Locale>((Ref ref) => AppLocales.arabic);

/// App language. Arabic by default; the choice is saved on the phone.
class LocaleController extends Notifier<Locale> {
  static const String storageKey = 'settings.locale';

  @override
  Locale build() {
    final String? saved = ref.watch(settingsStoreProvider).read(storageKey);
    return saved == null ? ref.watch(defaultLocaleProvider) : AppLocales.fromCode(saved);
  }

  Future<void> setLocale(Locale locale) async {
    final Locale next = AppLocales.fromCode(locale.languageCode);
    state = next;
    await ref.read(settingsStoreProvider).write(storageKey, next.languageCode);
  }

  /// Switches between Arabic and English.
  Future<void> toggle() =>
      setLocale(state == AppLocales.arabic ? AppLocales.english : AppLocales.arabic);
}

final NotifierProvider<LocaleController, Locale> localeProvider =
    NotifierProvider<LocaleController, Locale>(LocaleController.new);

/// Light, dark or follow the phone. Follows the phone by default.
class ThemeModeController extends Notifier<ThemeMode> {
  static const String storageKey = 'settings.themeMode';

  @override
  ThemeMode build() {
    final String? saved = ref.watch(settingsStoreProvider).read(storageKey);
    return ThemeMode.values.firstWhere(
      (ThemeMode mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await ref.read(settingsStoreProvider).write(storageKey, mode.name);
  }
}

final NotifierProvider<ThemeModeController, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// Dev setting: which design direction (A or B) the app shows. Default A.
/// Staging and prod always use the chosen direction (A until the owner picks).
class DesignDirectionController extends Notifier<DesignDirection> {
  static const String storageKey = 'settings.designDirection';

  @override
  DesignDirection build() =>
      DesignDirection.fromName(ref.watch(settingsStoreProvider).read(storageKey));

  Future<void> setDirection(DesignDirection direction) async {
    state = direction;
    await ref.read(settingsStoreProvider).write(storageKey, direction.name);
  }
}

final NotifierProvider<DesignDirectionController, DesignDirection> designDirectionProvider =
    NotifierProvider<DesignDirectionController, DesignDirection>(DesignDirectionController.new);
