import 'package:material_ui/material_ui.dart';

/// Elevation levels. Shadows stay soft; dark theme relies on surface tone
/// instead of shadow, so its shadows are near-invisible.
enum AppElevation { none, low, medium, high }

abstract final class AppShadows {
  static const List<BoxShadow> _none = <BoxShadow>[];

  static const List<BoxShadow> _lightLow = <BoxShadow>[
    BoxShadow(color: Color(0x0F101828), blurRadius: 4, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A101828), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> _lightMedium = <BoxShadow>[
    BoxShadow(color: Color(0x14101828), blurRadius: 16, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0A101828), blurRadius: 4, offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> _lightHigh = <BoxShadow>[
    BoxShadow(color: Color(0x1F101828), blurRadius: 32, offset: Offset(0, 16)),
    BoxShadow(color: Color(0x0F101828), blurRadius: 8, offset: Offset(0, 4)),
  ];

  static const List<BoxShadow> _darkLow = <BoxShadow>[
    BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> _darkMedium = <BoxShadow>[
    BoxShadow(color: Color(0x4D000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const List<BoxShadow> _darkHigh = <BoxShadow>[
    BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
  ];

  static List<BoxShadow> of(Brightness brightness, AppElevation elevation) {
    final bool light = brightness == Brightness.light;
    return switch (elevation) {
      AppElevation.none => _none,
      AppElevation.low => light ? _lightLow : _darkLow,
      AppElevation.medium => light ? _lightMedium : _darkMedium,
      AppElevation.high => light ? _lightHigh : _darkHigh,
    };
  }
}
