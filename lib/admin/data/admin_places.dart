import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Places in the admin panel (F4 grouping, F46 addresses): City -> Area ->
/// District with counts, add, rename, deactivate and merge, move a school
/// to an area, and the "my district isn't listed" queue. Every change is
/// in the audit log (functions/src/places/admin.ts). Every method throws
/// [AdminFailure].
abstract interface class AdminPlacesApi {
  Future<List<AdminPlace>> areas(String governorate);
  Future<List<AdminPlace>> districts(String areaId);

  /// Adds (no [id]) or renames an area; returns its id.
  Future<String> saveArea({required String nameAr, required String nameEn, String? id, String? governorate});

  /// Adds (no [id]) or renames a district; returns its id.
  Future<String> saveDistrict({required String nameAr, required String nameEn, String? id, String? areaId});
  Future<void> setActive({required PlaceLevel level, required String id, required bool active});

  /// Returns how many schools moved.
  Future<int> merge({required PlaceLevel level, required String fromId, required String intoId});
  Future<void> moveSchool({required String schoolId, required String areaId, String? districtId});
  Future<List<AdminPlaceRequest>> requests();
  Future<void> resolveRequest({
    required String id,
    required PlaceRequestAction action,
    String? districtId,
    String? nameAr,
    String? nameEn,
  });
}

enum PlaceLevel {
  area,
  district;

  String get wire => name;
}

enum PlaceRequestAction {
  create,
  map,
  dismiss;

  String get wire => name;
}

@immutable
class AdminPlace {
  const AdminPlace({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    this.governorate = '',
    this.areaId = '',
    this.source = '',
    this.hasShape = false,
    this.schoolCount = 0,
    this.addressCount = 0,
    this.active = true,
  });

  factory AdminPlace.fromJson(Json j) => AdminPlace(
    id: j.str('id'),
    governorate: j.str('governorate'),
    areaId: j.str('areaId'),
    nameAr: j.str('nameAr'),
    nameEn: j.str('nameEn'),
    source: j.str('source'),
    hasShape: j.flag('hasShape'),
    schoolCount: j.integer('schoolCount'),
    addressCount: j.integer('addressCount'),
    active: j.map['active'] != false,
  );

  final String id;
  final String governorate;

  /// For a district: its area.
  final String areaId;
  final String nameAr;
  final String nameEn;

  /// osm, osm-boundary, osm-place, admin.
  final String source;
  final bool hasShape;
  final int schoolCount;
  final int addressCount;
  final bool active;

  String name(String languageCode) {
    final String preferred = languageCode == 'ar' ? nameAr : nameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? nameEn : nameAr);
  }
}

@immutable
class AdminPlaceRequest {
  const AdminPlaceRequest({
    required this.id,
    required this.areaId,
    required this.governorate,
    required this.text,
    this.areaNameAr = '',
    this.areaNameEn = '',
    this.createdAt,
  });

  factory AdminPlaceRequest.fromJson(Json j) => AdminPlaceRequest(
    id: j.str('id'),
    areaId: j.str('areaId'),
    governorate: j.str('governorate'),
    text: j.str('text'),
    areaNameAr: j.str('areaNameAr'),
    areaNameEn: j.str('areaNameEn'),
    createdAt: j.time('createdAtMs'),
  );

  final String id;
  final String areaId;
  final String governorate;

  /// What the parent typed (a district name; never anything else).
  final String text;
  final String areaNameAr;
  final String areaNameEn;
  final DateTime? createdAt;
}

class FirebaseAdminPlacesApi implements AdminPlacesApi {
  FirebaseAdminPlacesApi(this._functions);

  final FirebaseFunctions _functions;

  Future<Json> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable(name)
          .call<Object?>(data);
      return Json.of(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AdminFailure.from(error), stackTrace);
    }
  }

  @override
  Future<List<AdminPlace>> areas(String governorate) async =>
      (await _call('adminListPlaceAreas', <String, Object?>{'governorate': governorate})).list('areas').map(AdminPlace.fromJson).toList();

  @override
  Future<List<AdminPlace>> districts(String areaId) async =>
      (await _call('adminListPlaceDistricts', <String, Object?>{'areaId': areaId})).list('districts').map(AdminPlace.fromJson).toList();

  @override
  Future<String> saveArea({required String nameAr, required String nameEn, String? id, String? governorate}) async =>
      (await _call('adminSavePlaceArea', <String, Object?>{
        'id': ?id,
        'governorate': ?governorate,
        'nameAr': nameAr,
        'nameEn': nameEn,
      })).str('id');

  @override
  Future<String> saveDistrict({required String nameAr, required String nameEn, String? id, String? areaId}) async =>
      (await _call('adminSavePlaceDistrict', <String, Object?>{
        'id': ?id,
        'areaId': ?areaId,
        'nameAr': nameAr,
        'nameEn': nameEn,
      })).str('id');

  @override
  Future<void> setActive({required PlaceLevel level, required String id, required bool active}) async {
    await _call('adminSetPlaceActive', <String, Object?>{'kind': level.wire, 'id': id, 'active': active});
  }

  @override
  Future<int> merge({required PlaceLevel level, required String fromId, required String intoId}) async =>
      (await _call('adminMergePlaces', <String, Object?>{'kind': level.wire, 'fromId': fromId, 'intoId': intoId})).integer('schoolsMoved');

  @override
  Future<void> moveSchool({required String schoolId, required String areaId, String? districtId}) async {
    await _call('adminMoveSchoolArea', <String, Object?>{'schoolId': schoolId, 'areaId': areaId, 'districtId': ?districtId});
  }

  @override
  Future<List<AdminPlaceRequest>> requests() async =>
      (await _call('adminListPlaceRequests')).list('requests').map(AdminPlaceRequest.fromJson).toList();

  @override
  Future<void> resolveRequest({
    required String id,
    required PlaceRequestAction action,
    String? districtId,
    String? nameAr,
    String? nameEn,
  }) async {
    await _call('adminResolvePlaceRequest', <String, Object?>{
      'id': id,
      'action': action.wire,
      'districtId': ?districtId,
      'nameAr': ?nameAr,
      'nameEn': ?nameEn,
    });
  }
}

final Provider<AdminPlacesApi> adminPlacesApiProvider = Provider<AdminPlacesApi>(
  (Ref ref) => FirebaseAdminPlacesApi(functionsClient()),
);
