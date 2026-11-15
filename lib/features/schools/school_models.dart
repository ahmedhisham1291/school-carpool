import 'package:cloud_firestore/cloud_firestore.dart' show GeoPoint;
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';

/// A school a parent can pick for a child (F4): from the list (active) or
/// the parent's own school typed under "Other" that awaits review.
@immutable
class SchoolOption {
  const SchoolOption({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.governorate,
    this.city = '',
    this.cityAr = '',
    this.pending = false,
    this.location,
    this.placeAreaId = '',
    this.placeAreaNameAr = '',
    this.placeAreaNameEn = '',
  });

  /// From Firestore (schools/{id}) or an Algolia hit (same field names).
  factory SchoolOption.fromMap(String id, Map<String, Object?> data) {
    String text(String key) {
      final Object? v = data[key];
      return v is String ? v : '';
    }

    return SchoolOption(
      id: id,
      nameAr: text('nameAr'),
      nameEn: text('nameEn'),
      governorate: text('governorate'),
      city: text('city'),
      cityAr: text('cityAr'),
      pending: data['status'] == 'awaiting_review',
      location: _locationOf(data['location']) ?? _locationOf(data['_geoloc']),
      placeAreaId: text('placeAreaId'),
      placeAreaNameAr: text('placeAreaNameAr'),
      placeAreaNameEn: text('placeAreaNameEn'),
    );
  }

  /// A Firestore GeoPoint or Algolia's `_geoloc` ({lat, lng}).
  static GeoPin? _locationOf(Object? value) {
    if (value is GeoPoint) {
      return GeoPin(value.latitude, value.longitude);
    }
    if (value is Map<Object?, Object?>) {
      final Object? lat = value['lat'];
      final Object? lng = value['lng'];
      if (lat is num && lng is num) {
        return GeoPin(lat.toDouble(), lng.toDouble());
      }
    }
    return null;
  }

  final String id;
  final String nameAr;
  final String nameEn;

  /// Governorate code (kGovernorates).
  final String governorate;
  final String city;
  final String cityAr;

  /// Typed under "Other" by this parent, waiting for an admin.
  final bool pending;

  /// The school's pin set by the admin (F40), or null.
  final GeoPin? location;

  /// City -> Area (placeAreas id, F4 browse), or empty when unknown.
  final String placeAreaId;
  final String placeAreaNameAr;
  final String placeAreaNameEn;

  /// The area's name in the app's language, or empty.
  String areaName(String languageCode) {
    final String preferred = languageCode == 'ar' ? placeAreaNameAr : placeAreaNameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? placeAreaNameEn : placeAreaNameAr);
  }

  /// The name in the app's language, falling back to the other one.
  String name(String languageCode) {
    final String preferred = languageCode == 'ar' ? nameAr : nameEn;
    final String other = languageCode == 'ar' ? nameEn : nameAr;
    return preferred.isNotEmpty ? preferred : other;
  }

  /// The city or district in the app's language, or empty.
  String place(String languageCode) {
    final String preferred = languageCode == 'ar' ? cityAr : city;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? city : cityAr);
  }

  @override
  bool operator ==(Object other) =>
      other is SchoolOption &&
      other.id == id &&
      other.nameAr == nameAr &&
      other.nameEn == nameEn &&
      other.governorate == governorate &&
      other.city == city &&
      other.cityAr == cityAr &&
      other.pending == pending &&
      other.placeAreaId == placeAreaId &&
      Geo.same(other.location, location);

  @override
  int get hashCode =>
      Object.hash(id, nameAr, nameEn, governorate, city, cityAr, pending, location?.lat, location?.lng, placeAreaId);
}

/// The shortest query that is searched (one letter matches too much).
const int kMinSchoolQueryLength = 2;

/// Most results shown at once (the index returns the same number).
const int kMaxSchoolResults = 20;

/// Spelling-tolerant matching on the phone, for the fake search in
/// development and for the parent's own pending schools. The real search
/// (Algolia) does the same on the server, typo tolerance included.
///
/// Every word of the query must match a word of the school's names or
/// place: the start of the word, or (from 4 letters) the whole word with
/// one letter wrong. Results are ranked by how many words start the same
/// way, then by name.
class SchoolMatcher {
  SchoolMatcher(Iterable<SchoolOption> schools)
    : _entries = <_Entry>[for (final SchoolOption s in schools) _Entry(s)];

  final List<_Entry> _entries;

  /// Schools with a pin, nearest to [around] first.
  List<SchoolOption> nearest(GeoPin around, {int limit = kMaxSchoolResults}) {
    final List<(double, SchoolOption)> withPin = <(double, SchoolOption)>[
      for (final _Entry e in _entries)
        if (e.school.location case final GeoPin at) (Geo.distanceKm(around, at), e.school),
    ]..sort(((double, SchoolOption) a, (double, SchoolOption) b) => a.$1.compareTo(b.$1));
    return <SchoolOption>[for (final (double _, SchoolOption s) in withPin.take(limit)) s];
  }

  List<SchoolOption> search(String query, {String? governorate, String? areaId, int limit = kMaxSchoolResults}) {
    final List<String> words = normalizeText(query).split(' ').where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      return const <SchoolOption>[];
    }
    final List<(int, _Entry)> hits = <(int, _Entry)>[];
    for (final _Entry entry in _entries) {
      if (governorate != null && entry.school.governorate != governorate) {
        continue;
      }
      if (areaId != null && entry.school.placeAreaId != areaId) {
        continue;
      }
      final int? score = entry.score(words);
      if (score != null) {
        hits.add((score, entry));
      }
    }
    hits.sort(((int, _Entry) a, (int, _Entry) b) {
      final int byScore = b.$1.compareTo(a.$1);
      return byScore != 0 ? byScore : a.$2.key.compareTo(b.$2.key);
    });
    return <SchoolOption>[for (final (int _, _Entry e) in hits.take(limit)) e.school];
  }
}

class _Entry {
  _Entry(this.school)
    : key = normalizeText(school.nameAr.isNotEmpty ? school.nameAr : school.nameEn),
      words = <String>{
        for (final String text in <String>[school.nameAr, school.nameEn, school.city, school.cityAr])
          ...normalizeText(text).split(' ').where((String w) => w.isNotEmpty),
      }.toList();

  final SchoolOption school;
  final String key;
  final List<String> words;

  /// Null when a query word matches nothing; otherwise higher is better.
  int? score(List<String> query) {
    int score = 0;
    for (final String q in query) {
      int best = -1;
      for (final String w in words) {
        // "ال" is part of the word in Arabic: "النيل" starts with "نيل" too.
        final String bare = w.startsWith('ال') && w.length > 3 ? w.substring(2) : w;
        if (w == q || bare == q) {
          best = 3;
          break;
        }
        if (w.startsWith(q) || bare.startsWith(q)) {
          best = best < 2 ? 2 : best;
        } else if (q.length >= 4 && (withinOneEdit(q, w) || withinOneEdit(q, bare) || _prefixWithinOneEdit(q, w))) {
          best = best < 1 ? 1 : best;
        }
      }
      if (best < 0) {
        return null;
      }
      score += best;
    }
    return score;
  }

  /// "Victorai" still finds "Victoria" while it is being typed.
  static bool _prefixWithinOneEdit(String q, String w) => w.length > q.length && withinOneEdit(q, w.substring(0, q.length));
}
