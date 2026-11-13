import 'dart:math' as math;

import 'package:school_carpool/admin/data/admin_models.dart' show GeoPin;

export 'package:school_carpool/admin/data/admin_models.dart' show GeoPin;

/// Geometry helpers for the maps screens (Prompt 5). The server does the
/// privacy work (rounding, offsets); the app only measures and frames.
abstract final class Geo {
  /// Central Cairo: where the map opens before a home is set.
  static const GeoPin cairo = GeoPin(30.0444, 31.2357);

  /// Radii a parent can choose on the nearby map (same list as the server,
  /// functions/src/maps/geo.ts).
  static const List<int> radiusChoicesKm = <int>[1, 2, 3, 5, 10];
  static const int defaultRadiusKm = 3;

  /// Egypt's box (same as the server).
  static bool inEgypt(GeoPin p) => p.lat >= 21.5 && p.lat <= 31.8 && p.lng >= 24.5 && p.lng <= 37.1;

  /// Great-circle distance in km.
  static double distanceKm(GeoPin a, GeoPin b) {
    const double rad = math.pi / 180;
    final double dLat = (b.lat - a.lat) * rad;
    final double dLng = (b.lng - a.lng) * rad;
    final double h =
        math.pow(math.sin(dLat / 2), 2).toDouble() +
        math.cos(a.lat * rad) * math.cos(b.lat * rad) * math.pow(math.sin(dLng / 2), 2).toDouble();
    return 2 * 6371.0088 * math.asin(math.min(1, math.sqrt(h)));
  }

  /// Grid step of the server's rounding (functions/src/maps/geo.ts GRID_DEG).
  static const double gridDeg = 0.005;

  /// The centre of the grid cell holding [p], as the server rounds homes.
  /// Used only to draw the search ring where the server measures from.
  static GeoPin roundToGrid(GeoPin p) {
    double cell(double x) => ((x / gridDeg).floorToDouble() + 0.5) * gridDeg;
    return GeoPin(cell(p.lat), cell(p.lng));
  }

  static bool same(GeoPin? a, GeoPin? b) =>
      identical(a, b) || (a != null && b != null && a.lat == b.lat && a.lng == b.lng);
}
