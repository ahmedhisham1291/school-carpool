import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/places/place_models.dart';

/// F46: a home address in short parts (City -> Area -> District, street,
/// building, optional floor, apartment and landmark). The server checks the
/// IDs and keeps the address with the exact pin in homes/{uid}, which only
/// the parent can read; other parents see the rounded point and the area.
@immutable
class HomeAddress {
  const HomeAddress({
    required this.governorate,
    required this.placeAreaId,
    required this.street,
    required this.building,
    this.placeAreaNameAr = '',
    this.placeAreaNameEn = '',
    this.placeDistrictId,
    this.placeDistrictNameAr = '',
    this.placeDistrictNameEn = '',
    this.districtText = '',
    this.floor = '',
    this.apartment = '',
    this.landmark = '',
  });

  /// homes/{uid}.address, or null for an older home without one (the
  /// address screen then asks for it; nothing else changes).
  static HomeAddress? fromMap(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    String s(String key) {
      final Object? v = value[key];
      return v is String ? v : '';
    }

    final String area = s('placeAreaId');
    // A city with no areas yet: no area, but a governorate and a street.
    if (area.isEmpty && (s('governorate').isEmpty || s('street').isEmpty)) {
      return null;
    }
    final String district = s('placeDistrictId');
    return HomeAddress(
      governorate: s('governorate'),
      placeAreaId: area,
      placeAreaNameAr: s('placeAreaNameAr'),
      placeAreaNameEn: s('placeAreaNameEn'),
      placeDistrictId: district.isEmpty ? null : district,
      placeDistrictNameAr: s('placeDistrictNameAr'),
      placeDistrictNameEn: s('placeDistrictNameEn'),
      districtText: s('districtText'),
      street: s('street'),
      building: s('building'),
      floor: s('floor'),
      apartment: s('apartment'),
      landmark: s('landmark'),
    );
  }

  final String governorate;
  final String placeAreaId;
  final String placeAreaNameAr;
  final String placeAreaNameEn;

  /// Null when the parent typed a district that is not listed ([districtText]).
  final String? placeDistrictId;
  final String placeDistrictNameAr;
  final String placeDistrictNameEn;
  final String districtText;
  final String street;
  final String building;
  final String floor;
  final String apartment;
  final String landmark;

  /// What the server needs (IDs and the typed text; the names come from the places).
  Map<String, Object?> toJson() => <String, Object?>{
    'governorate': governorate,
    'placeAreaId': placeAreaId,
    'placeDistrictId': placeDistrictId,
    if (placeDistrictId == null) 'districtText': districtText,
    'street': street,
    'building': building,
    'floor': floor,
    'apartment': apartment,
    'landmark': landmark,
  };

  /// "12 Road 9, Degla, Maadi" in the app's language.
  String label(String languageCode) {
    final String district = placeDistrictId == null ? districtText : placeName(languageCode, placeDistrictNameAr, placeDistrictNameEn);
    return <String>[
      '$building $street'.trim(),
      district,
      placeName(languageCode, placeAreaNameAr, placeAreaNameEn),
    ].where((String p) => p.isNotEmpty).join(languageCode == 'ar' ? '، ' : ', ');
  }

  @override
  bool operator ==(Object other) =>
      other is HomeAddress &&
      other.governorate == governorate &&
      other.placeAreaId == placeAreaId &&
      other.placeDistrictId == placeDistrictId &&
      other.districtText == districtText &&
      other.street == street &&
      other.building == building &&
      other.floor == floor &&
      other.apartment == apartment &&
      other.landmark == landmark;

  @override
  int get hashCode => Object.hash(governorate, placeAreaId, placeDistrictId, districtText, street, building, floor, apartment, landmark);
}

/// Why a field is not accepted yet, so the screen can say how to fix it.
enum AddressFieldProblem { required, tooShort, tooLong, characters }

/// Same rules as functions/src/places/address.ts.
abstract final class AddressRules {
  static final RegExp _text = RegExp(r"^[\p{L}\p{M}\p{N} .,'’()&/#\-،]+$", unicode: true);
  static final RegExp _building = RegExp(r'^[\p{L}\p{N}][\p{L}\p{N} /\-]{0,9}$', unicode: true);

  static String _clean(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ');

  static AddressFieldProblem? _textRule(String value, int min, int max, {bool optional = false}) {
    final String v = _clean(value);
    if (v.isEmpty) {
      return optional ? null : AddressFieldProblem.required;
    }
    if (v.length < min) {
      return AddressFieldProblem.tooShort;
    }
    if (v.length > max) {
      return AddressFieldProblem.tooLong;
    }
    return _text.hasMatch(v) ? null : AddressFieldProblem.characters;
  }

  static AddressFieldProblem? street(String v) => _textRule(v, 2, 120);
  static AddressFieldProblem? districtText(String v) => _textRule(v, 2, 80);
  static AddressFieldProblem? landmark(String v) => _textRule(v, 2, 120, optional: true);
  static AddressFieldProblem? shortExtra(String v) => _textRule(v, 1, 10, optional: true);

  static AddressFieldProblem? building(String value) {
    final String v = _clean(value);
    if (v.isEmpty) {
      return AddressFieldProblem.required;
    }
    if (v.length > 10) {
      return AddressFieldProblem.tooLong;
    }
    return _building.hasMatch(v) ? null : AddressFieldProblem.characters;
  }

  static String clean(String v) => _clean(v);
}

/// Where a point is (after "Search instead"): the City, Area and District
/// to fill in, each null when unknown.
@immutable
class PlaceHit {
  const PlaceHit({this.governorate, this.placeAreaId, this.placeDistrictId});

  final String? governorate;
  final String? placeAreaId;
  final String? placeDistrictId;
}
