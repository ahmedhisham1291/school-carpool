import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// `#rrggbb` of a color (map styles have no alpha).
String mapHex(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Google Maps style built from the theme's tokens, so the map follows the
/// light and dark themes and the calm palette: land on the page color,
/// roads on the raised surface with hairline edges, water in the accent
/// wash, labels in the secondary text color. Shops, businesses, transit
/// and icons are hidden so our own markers are the only things that stand
/// out (and no business is promoted).
String mapStyleJson(ColorScheme colors, AppColors app) {
  Map<String, Object> rule(String? feature, String? element, List<Map<String, Object>> stylers) => <String, Object>{
    'featureType': ?feature,
    'elementType': ?element,
    'stylers': stylers,
  };
  Map<String, Object> color(Color c) => <String, Object>{'color': mapHex(c)};
  const Map<String, Object> off = <String, Object>{'visibility': 'off'};
  const Map<String, Object> on = <String, Object>{'visibility': 'on'};

  return jsonEncode(<Map<String, Object>>[
    rule(null, 'geometry', <Map<String, Object>>[color(colors.surface)]),
    rule(null, 'labels.text.fill', <Map<String, Object>>[color(colors.onSurfaceVariant)]),
    rule(null, 'labels.text.stroke', <Map<String, Object>>[color(colors.surface)]),
    rule(null, 'labels.icon', <Map<String, Object>>[off]),
    rule('poi', null, <Map<String, Object>>[off]),
    rule('poi.park', 'geometry', <Map<String, Object>>[on, color(colors.secondaryContainer)]),
    rule('road', 'geometry.fill', <Map<String, Object>>[color(app.surfaceRaised)]),
    rule('road', 'geometry.stroke', <Map<String, Object>>[color(colors.outlineVariant)]),
    rule('road.highway', 'geometry.fill', <Map<String, Object>>[color(colors.outlineVariant)]),
    rule('transit', null, <Map<String, Object>>[off]),
    rule('water', 'geometry', <Map<String, Object>>[color(colors.primaryContainer)]),
    rule('water', 'labels.text.fill', <Map<String, Object>>[color(colors.onPrimaryContainer)]),
    rule('administrative', 'geometry.stroke', <Map<String, Object>>[color(colors.outline)]),
  ]);
}
