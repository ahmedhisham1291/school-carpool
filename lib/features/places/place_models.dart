import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';

/// City -> Area -> District (F4 browse, F46 address). City is the
/// governorate code (kGovernorates); Area is a qism, markaz or new city;
/// District a neighbourhood inside it. Read from Firestore placeAreas and
/// placeDistricts (public names; written only by Cloud Functions).
@immutable
class PlaceArea {
  const PlaceArea({
    required this.id,
    required this.governorate,
    required this.nameAr,
    required this.nameEn,
    this.schoolCount = 0,
  });

  factory PlaceArea.fromMap(String id, Map<String, Object?> data) => PlaceArea(
    id: id,
    governorate: _text(data['governorate']),
    nameAr: _text(data['nameAr']),
    nameEn: _text(data['nameEn']),
    schoolCount: data['schoolCount'] is num ? (data['schoolCount']! as num).toInt() : 0,
  );

  final String id;
  final String governorate;
  final String nameAr;
  final String nameEn;
  final int schoolCount;

  String name(String languageCode) => placeName(languageCode, nameAr, nameEn);

  @override
  bool operator ==(Object other) =>
      other is PlaceArea && other.id == id && other.nameAr == nameAr && other.nameEn == nameEn && other.schoolCount == schoolCount;

  @override
  int get hashCode => Object.hash(id, nameAr, nameEn, schoolCount);
}

@immutable
class PlaceDistrict {
  const PlaceDistrict({required this.id, required this.areaId, required this.nameAr, required this.nameEn});

  factory PlaceDistrict.fromMap(String id, Map<String, Object?> data) => PlaceDistrict(
    id: id,
    areaId: _text(data['areaId']),
    nameAr: _text(data['nameAr']),
    nameEn: _text(data['nameEn']),
  );

  final String id;
  final String areaId;
  final String nameAr;
  final String nameEn;

  String name(String languageCode) => placeName(languageCode, nameAr, nameEn);

  @override
  bool operator ==(Object other) => other is PlaceDistrict && other.id == id && other.nameAr == nameAr && other.nameEn == nameEn;

  @override
  int get hashCode => Object.hash(id, nameAr, nameEn);
}

String _text(Object? v) => v is String ? v : '';

/// The name in the app's language, falling back to the other one.
String placeName(String languageCode, String ar, String en) {
  final String preferred = languageCode == 'ar' ? ar : en;
  return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? en : ar);
}

/// Sorted by the name in the app's language (normalized: hamza forms and
/// "ال" do not change the order), Arabic by default.
List<T> sortByName<T>(Iterable<T> items, String Function(T) nameOf) {
  String key(T item) {
    final String n = normalizeText(nameOf(item));
    return n.startsWith('ال') && n.length > 3 ? n.substring(2) : n;
  }

  return items.toList()..sort((T a, T b) => key(a).compareTo(key(b)));
}
