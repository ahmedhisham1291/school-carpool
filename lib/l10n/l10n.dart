import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/l10n/gen/app_localizations.dart';

export 'package:school_carpool/l10n/gen/app_localizations.dart';

/// Locales the app supports. Arabic is the default and is listed first.
abstract final class AppLocales {
  static const Locale arabic = Locale('ar');
  static const Locale english = Locale('en');

  static const List<Locale> supported = <Locale>[arabic, english];

  /// Our strings plus Material, Cupertino and widgets localizations from
  /// `material_ui` (which replaced the copies in `flutter_localizations`).
  static const List<LocalizationsDelegate<dynamic>> delegates = <LocalizationsDelegate<dynamic>>[
    AppLocalizations.delegate,
    ...GlobalMaterialLocalizations.delegates,
  ];

  static Locale fromCode(String? code) => code == english.languageCode ? english : arabic;
}

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
