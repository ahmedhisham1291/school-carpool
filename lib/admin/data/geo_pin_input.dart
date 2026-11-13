import 'package:school_carpool/admin/data/admin_models.dart';

/// A box around Egypt (same as EGYPT_BOUNDS in
/// functions/src/admin_panel/schools.ts): catches swapped or mistyped
/// coordinates.
abstract final class EgyptBounds {
  static const double minLat = 21.5;
  static const double maxLat = 31.8;
  static const double minLng = 24.5;
  static const double maxLng = 37.1;

  static bool contains(GeoPin pin) =>
      pin.lat >= minLat && pin.lat <= maxLat && pin.lng >= minLng && pin.lng <= maxLng;
}

enum PinError { format, outsideEgypt }

/// Reads "29.9602, 31.2569" (as copied from Google Maps), with Arabic
/// digits or an Arabic comma too. Returns the pin or why it is refused.
(GeoPin?, PinError?) parsePin(String input) {
  final String ascii = input.replaceAllMapped(RegExp('[٠-٩۰-۹]'), (Match m) {
    final int code = m[0]!.codeUnitAt(0);
    return String.fromCharCode((code >= 0x06F0 ? code - 0x06F0 : code - 0x0660) + 0x30);
  }).replaceAll('٫', '.').replaceAll('،', ',');
  final List<String> parts = ascii.split(RegExp(r'[,\s]+')).where((String p) => p.isNotEmpty).toList();
  if (parts.length != 2) {
    return (null, PinError.format);
  }
  final double? lat = double.tryParse(parts[0]);
  final double? lng = double.tryParse(parts[1]);
  if (lat == null || lng == null) {
    return (null, PinError.format);
  }
  final GeoPin pin = GeoPin(lat, lng);
  return EgyptBounds.contains(pin) ? (pin, null) : (null, PinError.outsideEgypt);
}

/// "29.96021, 31.2569" for the form field.
String formatPin(GeoPin pin) => '${pin.lat.toStringAsFixed(5)}, ${pin.lng.toStringAsFixed(5)}';
