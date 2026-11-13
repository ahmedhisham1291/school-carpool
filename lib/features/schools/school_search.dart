import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientRequest, HttpClientResponse, HttpException, SocketException;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// School search (F4) as the parent types, in Arabic or English, spelling
/// tolerant, with an optional governorate filter.
///
/// - Staging and prod: Algolia, with a one-hour key from the
///   getSchoolSearchKey function that can only search the schools index.
///   The index holds school names and places only.
/// - Dev on the emulators (and any project where the server says
///   "fake"): [FirestoreSchoolSearch] reads the emulator's schools and
///   matches on the phone. No Algolia account is needed.
abstract interface class SchoolSearch {
  /// Throws [SchoolSearchFailure].
  Future<List<SchoolOption>> search(String query, {String? governorate});

  /// Schools nearest to [around] (the parent's home), nearest first
  /// (Prompt 5). Throws [SchoolSearchFailure].
  Future<List<SchoolOption>> nearest(GeoPin around);
}

enum SchoolSearchFailureKind { offline, unavailable }

class SchoolSearchFailure implements Exception {
  const SchoolSearchFailure(this.kind);

  final SchoolSearchFailureKind kind;

  bool get isOffline => kind == SchoolSearchFailureKind.offline;

  @override
  String toString() => 'SchoolSearchFailure(${kind.name})';
}

/// Matches in memory: tests, the gallery, and the base of the Firestore fake.
class InMemorySchoolSearch implements SchoolSearch {
  InMemorySchoolSearch(Iterable<SchoolOption> schools) : _matcher = SchoolMatcher(schools);

  final SchoolMatcher _matcher;

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) async =>
      _matcher.search(query, governorate: governorate);

  @override
  Future<List<SchoolOption>> nearest(GeoPin around) async => _matcher.nearest(around);
}

/// The fake search for development: loads the active schools from
/// Firestore once (the emulator's seed and the sample import, at most
/// [limit], as firestore.rules allow) and matches on the phone.
class FirestoreSchoolSearch implements SchoolSearch {
  FirestoreSchoolSearch(this._db, {this._now = DateTime.now});

  final FirebaseFirestore _db;
  final DateTime Function() _now;

  /// The most a list query may read (firestore.rules).
  static const int limit = 200;

  /// Read again after this long, so a school an admin just approved shows up.
  static const Duration maxAge = Duration(minutes: 1);

  Future<SchoolMatcher>? _matcher;
  DateTime? _loadedAt;

  Future<SchoolMatcher> _load() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await _db
          .collection('schools')
          .where('status', isEqualTo: 'active')
          .limit(limit)
          .get();
      return SchoolMatcher(<SchoolOption>[
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) SchoolOption.fromMap(doc.id, doc.data()),
      ]);
    } on FirebaseException catch (error) {
      throw SchoolSearchFailure(
        error.code == 'unavailable' ? SchoolSearchFailureKind.offline : SchoolSearchFailureKind.unavailable,
      );
    }
  }

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) async =>
      (await _current()).search(query, governorate: governorate);

  @override
  Future<List<SchoolOption>> nearest(GeoPin around) async => (await _current()).nearest(around);

  Future<SchoolMatcher> _current() async {
    final DateTime? loadedAt = _loadedAt;
    if (loadedAt == null || _now().difference(loadedAt) > maxAge) {
      _matcher = null;
    }
    if (_matcher == null) {
      _loadedAt = _now();
    }
    final Future<SchoolMatcher> loading = _matcher ??= _load();
    try {
      return await loading;
    } on SchoolSearchFailure {
      _matcher = null; // Try again next time.
      rethrow;
    }
  }
}

/// A search key from getSchoolSearchKey.
@immutable
class SearchKey {
  const SearchKey({required this.provider, this.appId = '', this.indexName = '', this.key = '', this.validUntil});

  final String provider;
  final String appId;
  final String indexName;
  final String key;
  final DateTime? validUntil;

  bool get isAlgolia => provider == 'algolia' && appId.isNotEmpty && key.isNotEmpty;
}

/// Sends one search to Algolia and returns the decoded answer.
typedef AlgoliaTransport =
    Future<Map<String, Object?>> Function(Uri url, Map<String, String> headers, String body);

/// Algolia's search API over HTTPS. iPhone and Android only for now: the
/// website's search arrives with its platform work (Stage 2).
Future<Map<String, Object?>> httpAlgoliaTransport(Uri url, Map<String, String> headers, String body) async {
  if (kIsWeb) {
    throw const SchoolSearchFailure(SchoolSearchFailureKind.unavailable);
  }
  final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final HttpClientRequest request = await client.postUrl(url);
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final HttpClientResponse response = await request.close().timeout(const Duration(seconds: 10));
    final String text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw const SchoolSearchFailure(SchoolSearchFailureKind.unavailable);
    }
    final Object? data = jsonDecode(text);
    return data is Map<String, Object?> ? data : const <String, Object?>{};
  } on SocketException {
    throw const SchoolSearchFailure(SchoolSearchFailureKind.offline);
  } on TimeoutException {
    throw const SchoolSearchFailure(SchoolSearchFailureKind.offline);
  } on HttpException {
    throw const SchoolSearchFailure(SchoolSearchFailureKind.offline);
  } finally {
    client.close();
  }
}

/// Algolia search with a secured key (names and places come back, nothing
/// else). The key is fetched again shortly before it expires. The query is
/// normalized like the index's `searchKeys`, and recent answers are kept
/// for a few minutes, so typing back and forth costs no extra requests
/// (COST MODE: Algolia's free plan counts every request).
class AlgoliaSchoolSearch implements SchoolSearch {
  AlgoliaSchoolSearch({
    required this._fetchKey,
    this._transport = httpAlgoliaTransport,
    this._now = DateTime.now,
  });

  final Future<SearchKey> Function() _fetchKey;
  final AlgoliaTransport _transport;
  final DateTime Function() _now;
  SearchKey? _key;

  /// Most recent answers, oldest first (a small LRU).
  final Map<String, (DateTime, List<SchoolOption>)> _cache = <String, (DateTime, List<SchoolOption>)>{};
  static const int cacheSize = 50;
  static const Duration cacheAge = Duration(minutes: 10);

  Future<SearchKey> _validKey() async {
    final SearchKey? key = _key;
    final DateTime? until = key?.validUntil;
    if (key != null && until != null && _now().isBefore(until.subtract(const Duration(minutes: 1)))) {
      return key;
    }
    return _key = await _fetchKey();
  }

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) {
    final String normalized = normalizeText(query);
    return _cached('$normalized|${governorate ?? ''}', <String, String>{
      'query': normalized,
      'hitsPerPage': '$kMaxSchoolResults',
      if (governorate != null) 'filters': 'governorate:$governorate',
    });
  }

  /// One search with no text, ranked by distance (Algolia's geo ranking on
  /// `_geoloc`), with the same per-parent key and cache as [search]. The
  /// picker asks once per opening (free plan, COSTS.md).
  @override
  Future<List<SchoolOption>> nearest(GeoPin around) => _cached('@${around.lat},${around.lng}', <String, String>{
    'query': '',
    'hitsPerPage': '$kMaxSchoolResults',
    'aroundLatLng': '${around.lat},${around.lng}',
    'aroundRadius': 'all',
  });

  Future<List<SchoolOption>> _cached(String cacheKey, Map<String, String> query) async {
    final (DateTime, List<SchoolOption>)? cached = _cache.remove(cacheKey);
    if (cached != null && _now().difference(cached.$1) < cacheAge) {
      _cache[cacheKey] = cached;
      return cached.$2;
    }
    final List<SchoolOption> found = await _ask(query);
    _cache[cacheKey] = (_now(), found);
    if (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return found;
  }

  Future<List<SchoolOption>> _ask(Map<String, String> query) async {
    final SearchKey key = await _validKey();
    final Uri url = Uri.https('${key.appId}-dsn.algolia.net', '/1/indexes/${key.indexName}/query');
    final String params = Uri(queryParameters: query).query;
    final Map<String, Object?> answer = await _transport(url, <String, String>{
      'X-Algolia-Application-Id': key.appId,
      'X-Algolia-API-Key': key.key,
      'Content-Type': 'application/json',
    }, jsonEncode(<String, String>{'params': params}));
    final Object? hits = answer['hits'];
    if (hits is! List<Object?>) {
      return const <SchoolOption>[];
    }
    return <SchoolOption>[
      for (final Object? hit in hits)
        if (hit is Map<String, Object?> && hit['objectID'] is String)
          SchoolOption.fromMap(hit['objectID'] as String, <String, Object?>{...hit, 'status': 'active'}),
    ];
  }
}

/// Prod never falls back to the fake search (it would quietly search only
/// the first 200 schools): it says search is unavailable instead. The
/// server refuses and reports the fake search in prod too.
class UnavailableSchoolSearch implements SchoolSearch {
  const UnavailableSchoolSearch();

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) =>
      Future<List<SchoolOption>>.error(const SchoolSearchFailure(SchoolSearchFailureKind.unavailable));

  @override
  Future<List<SchoolOption>> nearest(GeoPin around) =>
      Future<List<SchoolOption>>.error(const SchoolSearchFailure(SchoolSearchFailureKind.unavailable));
}

/// Outside the emulators: asks the server which search to use once
/// (Algolia when it is set up for this project, else the Firestore fake).
class ServerSelectedSchoolSearch implements SchoolSearch {
  ServerSelectedSchoolSearch({required this.fetchKey, required this.fallback, AlgoliaTransport? transport})
    : _transport = transport ?? httpAlgoliaTransport;

  final Future<SearchKey> Function() fetchKey;
  final SchoolSearch fallback;
  final AlgoliaTransport _transport;
  SchoolSearch? _chosen;

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) async =>
      (await _choose()).search(query, governorate: governorate);

  @override
  Future<List<SchoolOption>> nearest(GeoPin around) async => (await _choose()).nearest(around);

  Future<SchoolSearch> _choose() async {
    SchoolSearch? chosen = _chosen;
    if (chosen == null) {
      final SearchKey first = await fetchKey();
      bool used = false;
      chosen = _chosen = first.isAlgolia
          ? AlgoliaSchoolSearch(
              fetchKey: () async {
                if (!used) {
                  used = true;
                  return first;
                }
                return fetchKey();
              },
              transport: _transport,
            )
          : fallback;
    }
    return chosen;
  }
}

/// Calls getSchoolSearchKey.
Future<SearchKey> fetchSearchKey(FirebaseFunctions functions) async {
  try {
    final HttpsCallableResult<Object?> result = await functions.httpsCallable('getSchoolSearchKey').call<Object?>();
    final Object? data = result.data;
    if (data is! Map<Object?, Object?>) {
      return const SearchKey(provider: 'fake');
    }
    final Map<Object?, Object?> map = data;
    String text(String k) {
      final Object? v = map[k];
      return v is String ? v : '';
    }

    final Object? until = map['validUntil'];
    return SearchKey(
      provider: text('provider'),
      appId: text('appId'),
      indexName: text('indexName'),
      key: text('key'),
      validUntil: until is num ? DateTime.fromMillisecondsSinceEpoch(until.toInt() * 1000) : null,
    );
  } on FirebaseFunctionsException catch (error) {
    throw SchoolSearchFailure(
      error.code == 'unavailable' || error.code == 'deadline-exceeded'
          ? SchoolSearchFailureKind.offline
          : SchoolSearchFailureKind.unavailable,
    );
  }
}

final Provider<SchoolSearch> schoolSearchProvider = Provider<SchoolSearch>((Ref ref) {
  final FirestoreSchoolSearch fake = FirestoreSchoolSearch(ref.watch(firestoreProvider));
  if (ref.watch(flavorConfigProvider).useEmulators) {
    return fake;
  }
  final FirebaseFunctions functions = functionsClient();
  return ServerSelectedSchoolSearch(
    fetchKey: () => fetchSearchKey(functions),
    fallback: ref.watch(flavorConfigProvider).isProd ? const UnavailableSchoolSearch() : fake,
  );
});
