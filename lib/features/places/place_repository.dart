import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/places/place_models.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/firebase/collections.dart';

enum PlaceFailureKind { offline, unavailable }

class PlaceFailure implements Exception {
  const PlaceFailure(this.kind);

  factory PlaceFailure.from(Object error) {
    if (error is PlaceFailure) {
      return error;
    }
    if (error is FirebaseException && (error.code == 'unavailable' || error.code == 'deadline-exceeded')) {
      return const PlaceFailure(PlaceFailureKind.offline);
    }
    return const PlaceFailure(PlaceFailureKind.unavailable);
  }

  final PlaceFailureKind kind;

  bool get isOffline => kind == PlaceFailureKind.offline;

  @override
  String toString() => 'PlaceFailure(${kind.name})';
}

/// Areas of a city, districts of an area, and the schools of an area.
/// Reads only (firestore.rules: lists of at most 500 areas or districts and
/// 200 schools). Every method throws [PlaceFailure].
abstract interface class PlaceRepository {
  Future<List<PlaceArea>> areas(String governorate);
  Future<List<PlaceDistrict>> districts(String areaId);

  /// Active schools of [areaId], at most [kAreaSchoolsLimit].
  Future<List<SchoolOption>> schoolsInArea(String areaId);
}

/// The most schools an area list reads (firestore.rules allows 200).
const int kAreaSchoolsLimit = 200;

class FirestorePlaceRepository implements PlaceRepository {
  FirestorePlaceRepository(this._db);

  final FirebaseFirestore _db;

  Future<List<T>> _read<T>(Query<Map<String, dynamic>> query, T Function(String, Map<String, Object?>) from) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await query.get();
      return <T>[for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs) from(d.id, d.data())];
    } on Object catch (error) {
      throw PlaceFailure.from(error);
    }
  }

  @override
  Future<List<PlaceArea>> areas(String governorate) async {
    // Inactive and merged areas stay as records only.
    final List<PlaceArea> all = await _read(
      _db.collection(Collections.placeAreas).where('governorate', isEqualTo: governorate).where('active', isEqualTo: true).limit(500),
      PlaceArea.fromMap,
    );
    return all.where((PlaceArea a) => a.nameAr.isNotEmpty || a.nameEn.isNotEmpty).toList();
  }

  @override
  Future<List<PlaceDistrict>> districts(String areaId) =>
      _read(_db.collection(Collections.placeDistricts).where('areaId', isEqualTo: areaId).where('active', isEqualTo: true).limit(500), PlaceDistrict.fromMap);

  @override
  Future<List<SchoolOption>> schoolsInArea(String areaId) async {
    // Schools taken out of the list by the import (searchHidden: the
    // sample, names in no usable script, schools no longer in any source)
    // stay as documents but are not offered.
    final List<SchoolOption?> all = await _read(
      _db
          .collection(Collections.schools)
          .where('status', isEqualTo: 'active')
          .where('placeAreaId', isEqualTo: areaId)
          .limit(kAreaSchoolsLimit),
      (String id, Map<String, Object?> data) => data['searchHidden'] == true ? null : SchoolOption.fromMap(id, data),
    );
    return all.whereType<SchoolOption>().toList();
  }
}

final Provider<PlaceRepository> placeRepositoryProvider = Provider<PlaceRepository>(
  (Ref ref) => FirestorePlaceRepository(ref.watch(firestoreProvider)),
);
