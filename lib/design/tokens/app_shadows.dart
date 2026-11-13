import 'package:material_ui/material_ui.dart';

/// Elevation levels. The refined look separates surfaces with hairline
/// borders (see `AppBorders`), not shadows. A shadow is a single soft layer
/// and only for things that float: [medium] for a card that must stand out,
/// [high] for menus and floating panels. Dark theme relies on surface tone.
enum AppElevation { none, low, medium, high }

abstract final class AppShadows {
  static const List<BoxShadow> _none = <BoxShadow>[];

  // Shadow color is the near-black ink of direction A at low opacity, so
  // shadows look like soft shade rather than grey smudges.
  static const List<BoxShadow> _lightLow = <BoxShadow>[
    BoxShadow(color: Color(0x0A141A19), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> _lightMedium = <BoxShadow>[
    BoxShadow(color: Color(0x12141A19), blurRadius: 24, offset: Offset(0, 8)),
  ];
  static const List<BoxShadow> _lightHigh = <BoxShadow>[
    BoxShadow(color: Color(0x1A141A19), blurRadius: 40, offset: Offset(0, 16)),
  ];

  static const List<BoxShadow> _darkMedium = <BoxShadow>[
    BoxShadow(color: Color(0x52000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
  static const List<BoxShadow> _darkHigh = <BoxShadow>[
    BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 16)),
  ];

  static List<BoxShadow> of(Brightness brightness, AppElevation elevation) {
    final bool light = brightness == Brightness.light;
    return switch (elevation) {
      AppElevation.none => _none,
      AppElevation.low => light ? _lightLow : _none,
      AppElevation.medium => light ? _lightMedium : _darkMedium,
      AppElevation.high => light ? _lightHigh : _darkHigh,
    };
  }
}
