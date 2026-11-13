import 'package:material_ui/material_ui.dart';

/// Corner radii. Three steps, used consistently: controls (12), cards (16),
/// sheets and dialogs (24). Chips and the navigation indicator are pills.
abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));

  /// Inputs, buttons, icon tiles and snackbars.
  static const BorderRadius control = mdAll;

  /// Cards and list groups.
  static const BorderRadius card = lgAll;

  /// Dialogs.
  static const BorderRadius dialog = xlAll;

  /// Chips and the selected-tab indicator.
  static const BorderRadius chip = pillAll;

  /// Top corners of bottom sheets.
  static const BorderRadius sheetTop = BorderRadius.vertical(top: Radius.circular(xl));
}
