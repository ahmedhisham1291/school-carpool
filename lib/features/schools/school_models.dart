import 'package:flutter/foundation.dart';
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
    );
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
      other.pending == pending;

  @override
  int get hashCode => Object.hash(id, nameAr, nameEn, governorate, city, cityAr, pending);
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

  List<SchoolOption> search(String query, {String? governorate, int limit = kMaxSchoolResults}) {
    final List<String> words = normalizeText(query).split(' ').where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      return const <SchoolOption>[];
    }
    final List<(int, _Entry)> hits = <(int, _Entry)>[];
    for (final _Entry entry in _entries) {
      if (governorate != null && entry.school.governorate != governorate) {
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
