import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Home, map settings, driving schools and the nearby parents map
/// (F21 to F24). Every write goes through Cloud Functions; the app reads
/// only its own homes/{uid} (firestore.rules). Other parents come back from
/// searchNearbyParents with rounded, offset points only.
abstract interface class MapRepository {
  /// The parent's own home and settings; null before anything was saved.
  Stream<HomeLocation?> watchHome(String uid);

  /// Throws [MapFailure]. Returns the rounded point others will see.
  Future<GeoPin> setHome(GeoPin location, {String label = ''});

  /// Throws [MapFailure].
  Future<void> updateSettings({bool? showOnMap, bool? notifyNewParents, int? radiusKm});

  /// Throws [MapFailure].
  Future<List<SchoolRef>> setDrivingSchools(List<String> schoolIds);

  /// Throws [MapFailure].
  Future<List<NearbyParent>> nearby({required String schoolId, required int radiusKm});

  /// The pin of an active school (F40), or null when it has none or cannot
  /// be read. Schools are public data (firestore.rules).
  Future<GeoPin?> schoolPin(String schoolId);
}

/// Address search through the placesAutocomplete and placeDetails functions
/// (the Places key stays on the server).
abstract interface class PlacesRepository {
  /// Throws [MapFailure].
  Future<List<PlaceSuggestion>> autocomplete(String input, {required String sessionToken, required String language, GeoPin? near});

  /// Throws [MapFailure]. Ends the session.
  Future<PlaceResult> details(String placeId, {required String sessionToken, required String language});
}

/// A new random session token (UUID v4 form) for one address search.
String newPlacesSessionToken([math.Random? random]) {
  final math.Random r = random ?? math.Random.secure();
  final List<int> b = List<int>.generate(16, (int _) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final String hex = b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<Object?, Object?> _map(Object? data) => data is Map<Object?, Object?> ? data : const <Object?, Object?>{};

String _text(Object? value) => value is String ? value : '';

GeoPin? _pin(Object? value) {
  final Map<Object?, Object?> m = _map(value);
  final Object? lat = m['lat'];
  final Object? lng = m['lng'];
  return lat is num && lng is num ? GeoPin(lat.toDouble(), lng.toDouble()) : null;
}

class FirebaseMapRepository implements MapRepository {
  FirebaseMapRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  Future<Map<Object?, Object?>> _call(String name, Map<String, Object?> data) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable(name).call<Object?>(data);
      return _map(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(MapFailure.from(error), stackTrace);
    }
  }

  @override
  Stream<HomeLocation?> watchHome(String uid) => _db
      .collection('homes')
      .doc(uid)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> snap) {
        final Map<String, dynamic>? data = snap.data();
        return data == null ? null : HomeLocation.fromMap(data);
      });

  @override
  Future<GeoPin> setHome(GeoPin location, {String label = ''}) async {
    final Map<Object?, Object?> result = await _call('setHomeLocation', <String, Object?>{
      'location': location.toJson(),
      'label': label,
    });
    return _pin(result['approximate']) ?? location;
  }

  @override
  Future<void> updateSettings({bool? showOnMap, bool? notifyNewParents, int? radiusKm}) async {
    await _call('updateMapSettings', <String, Object?>{
      'showOnMap': ?showOnMap,
      'notifyNewParents': ?notifyNewParents,
      'radiusKm': ?radiusKm,
    });
  }

  @override
  Future<List<SchoolRef>> setDrivingSchools(List<String> schoolIds) async {
    final Map<Object?, Object?> result = await _call('setDrivingSchools', <String, Object?>{'schoolIds': schoolIds});
    final Object? schools = result['schools'];
    return <SchoolRef>[
      if (schools is List<Object?>)
        for (final Object? s in schools)
          SchoolRef(id: _text(_map(s)['id']), nameAr: _text(_map(s)['nameAr']), nameEn: _text(_map(s)['nameEn'])),
    ];
  }

  @override
  Future<List<NearbyParent>> nearby({required String schoolId, required int radiusKm}) async {
    final Map<Object?, Object?> result = await _call('searchNearbyParents', <String, Object?>{
      'schoolId': schoolId,
      'radiusKm': radiusKm,
    });
    final Object? parents = result['parents'];
    final List<NearbyParent> out = <NearbyParent>[];
    if (parents is List<Object?>) {
      for (final Object? p in parents) {
        final Map<Object?, Object?> m = _map(p);
        final GeoPin? point = _pin(m['point']);
        if (point != null && _text(m['id']).isNotEmpty) {
          out.add(NearbyParent(id: _text(m['id']), firstName: _text(m['firstName']), schoolId: _text(m['schoolId']), point: point));
        }
      }
    }
    return out;
  }

  @override
  Future<GeoPin?> schoolPin(String schoolId) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _db.collection('schools').doc(schoolId).get();
      final Object? loc = snap.data()?['location'];
      return loc is GeoPoint ? GeoPin(loc.latitude, loc.longitude) : null;
    } on FirebaseException {
      return null;
    }
  }
}

class FirebasePlacesRepository implements PlacesRepository {
  FirebasePlacesRepository(this._functions);

  final FirebaseFunctions _functions;

  @override
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    required String language,
    GeoPin? near,
  }) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable('placesAutocomplete').call<Object?>(
        <String, Object?>{'input': input, 'sessionToken': sessionToken, 'language': language, 'near': near?.toJson()},
      );
      final Object? list = _map(result.data)['suggestions'];
      return <PlaceSuggestion>[
        if (list is List<Object?>)
          for (final Object? s in list)
            PlaceSuggestion(
              placeId: _text(_map(s)['placeId']),
              primary: _text(_map(s)['primary']),
              secondary: _text(_map(s)['secondary']),
            ),
      ];
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(MapFailure.from(error), stackTrace);
    }
  }

  @override
  Future<PlaceResult> details(String placeId, {required String sessionToken, required String language}) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable('placeDetails').call<Object?>(
        <String, Object?>{'placeId': placeId, 'sessionToken': sessionToken, 'language': language},
      );
      final Map<Object?, Object?> m = _map(result.data);
      final GeoPin? location = _pin(m['location']);
      if (location == null) {
        throw const MapFailure(MapFailureKind.unknown);
      }
      return PlaceResult(placeId: _text(m['placeId']), label: _text(m['label']), location: location);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(MapFailure.from(error), stackTrace);
    }
  }
}

final Provider<MapRepository> mapRepositoryProvider = Provider<MapRepository>(
  (Ref ref) => FirebaseMapRepository(functionsClient(), ref.watch(firestoreProvider)),
);

final Provider<PlacesRepository> placesRepositoryProvider = Provider<PlacesRepository>(
  (Ref ref) => FirebasePlacesRepository(functionsClient()),
);

/// The signed-in parent's home and map settings (null before any save).
final StreamProvider<HomeLocation?> myHomeProvider = StreamProvider<HomeLocation?>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<HomeLocation?>.value(null);
  }
  return ref.watch(mapRepositoryProvider).watchHome(session.uid);
});
