import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_places.dart';
import 'package:school_carpool/features/places/place_models.dart';
import 'package:school_carpool/features/places/place_repository.dart';
import 'package:school_carpool/features/schools/school_models.dart';

/// Fake places (not real borders): two Cairo areas, one Giza area.
const List<PlaceArea> testAreas = <PlaceArea>[
  PlaceArea(id: 'osm-r1', governorate: 'cairo', nameAr: 'المعادي', nameEn: 'Maadi', schoolCount: 2),
  PlaceArea(id: 'osm-r2', governorate: 'cairo', nameAr: 'مدينة نصر', nameEn: 'Nasr City', schoolCount: 1),
  PlaceArea(id: 'osm-r3', governorate: 'giza', nameAr: 'الشيخ زايد', nameEn: 'Sheikh Zayed'),
];

const List<PlaceDistrict> testDistricts = <PlaceDistrict>[
  PlaceDistrict(id: 'osm-n10', areaId: 'osm-r1', nameAr: 'دجلة', nameEn: 'Degla'),
  PlaceDistrict(id: 'osm-n11', areaId: 'osm-r1', nameAr: 'سرايات المعادي', nameEn: 'Sarayat El Maadi'),
  PlaceDistrict(id: 'osm-n20', areaId: 'osm-r3', nameAr: 'الحي 14', nameEn: 'District 14'),
];

const List<SchoolOption> testAreaSchools = <SchoolOption>[
  SchoolOption(id: 'z', nameAr: 'مدرسة الزهور (تجريبية)', nameEn: 'Zohour School (test)', governorate: 'cairo', placeAreaId: 'osm-r1'),
  SchoolOption(id: 'a', nameAr: 'مدرسة الأمل (تجريبية)', nameEn: 'Amal School (test)', governorate: 'cairo', placeAreaId: 'osm-r1'),
  SchoolOption(id: 'n', nameAr: 'مدرسة النصر (تجريبية)', nameEn: 'Nasr School (test)', governorate: 'cairo', placeAreaId: 'osm-r2'),
];

class FakePlaceRepository implements PlaceRepository {
  FakePlaceRepository({this.areaList = testAreas, this.districtList = testDistricts, this.schools = testAreaSchools});

  final List<PlaceArea> areaList;
  final List<PlaceDistrict> districtList;
  final List<SchoolOption> schools;
  final List<String> calls = <String>[];

  /// Every call fails with this, when set.
  PlaceFailure? failure;

  void _check(String call) {
    calls.add(call);
    final PlaceFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<List<PlaceArea>> areas(String governorate) async {
    _check('areas:$governorate');
    return areaList.where((PlaceArea a) => a.governorate == governorate).toList();
  }

  @override
  Future<List<PlaceDistrict>> districts(String areaId) async {
    _check('districts:$areaId');
    return districtList.where((PlaceDistrict d) => d.areaId == areaId).toList();
  }

  @override
  Future<List<SchoolOption>> schoolsInArea(String areaId) async {
    _check('schools:$areaId');
    return schools.where((SchoolOption s) => s.placeAreaId == areaId).toList();
  }
}

List<Override> placeOverrides({PlaceRepository? repository}) => <Override>[
  placeRepositoryProvider.overrideWithValue(repository ?? FakePlaceRepository()),
];

/// Records calls; answers with fake places. [failure] makes every call fail.
class FakeAdminPlacesApi implements AdminPlacesApi {
  final List<String> calls = <String>[];
  AdminFailure? failure;

  final List<AdminPlace> areaList = <AdminPlace>[
    const AdminPlace(id: 'osm-r1', governorate: 'cairo', nameAr: 'المعادي', nameEn: 'Maadi', source: 'osm', hasShape: true, schoolCount: 4, addressCount: 2),
    const AdminPlace(id: 'osm-r2', governorate: 'cairo', nameAr: 'مدينة نصر', nameEn: 'Nasr City', source: 'osm', hasShape: true, schoolCount: 1),
  ];
  final List<AdminPlace> districtList = <AdminPlace>[
    const AdminPlace(id: 'osm-n10', areaId: 'osm-r1', nameAr: 'دجلة', nameEn: 'Degla', source: 'osm-place', schoolCount: 1),
  ];
  final List<AdminPlaceRequest> requestList = <AdminPlaceRequest>[
    const AdminPlaceRequest(id: 'q1', areaId: 'osm-r1', governorate: 'cairo', text: 'الحي الجديد', areaNameAr: 'المعادي', areaNameEn: 'Maadi'),
  ];

  Future<void> _check(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<List<AdminPlace>> areas(String governorate) async {
    await _check('areas:$governorate');
    return areaList.where((AdminPlace a) => a.governorate == governorate).toList();
  }

  @override
  Future<List<AdminPlace>> districts(String areaId) async {
    await _check('districts:$areaId');
    return districtList.where((AdminPlace d) => d.areaId == areaId).toList();
  }

  @override
  Future<String> saveArea({required String nameAr, required String nameEn, String? id, String? governorate}) async {
    await _check('saveArea:${id ?? 'new'}:$nameAr:$nameEn:${governorate ?? ''}');
    return id ?? 'adm-1';
  }

  @override
  Future<String> saveDistrict({required String nameAr, required String nameEn, String? id, String? areaId}) async {
    await _check('saveDistrict:${id ?? 'new'}:$nameAr:$nameEn:${areaId ?? ''}');
    return id ?? 'adm-2';
  }

  @override
  Future<void> setActive({required PlaceLevel level, required String id, required bool active}) =>
      _check('setActive:${level.wire}:$id:$active');

  @override
  Future<int> merge({required PlaceLevel level, required String fromId, required String intoId}) async {
    await _check('merge:${level.wire}:$fromId:$intoId');
    return 1;
  }

  @override
  Future<void> moveSchool({required String schoolId, required String areaId, String? districtId}) =>
      _check('moveSchool:$schoolId:$areaId:${districtId ?? ''}');

  @override
  Future<List<AdminPlaceRequest>> requests() async {
    await _check('requests');
    return requestList;
  }

  @override
  Future<void> resolveRequest({
    required String id,
    required PlaceRequestAction action,
    String? districtId,
    String? nameAr,
    String? nameEn,
  }) => _check('resolve:$id:${action.wire}:${districtId ?? ''}:${nameAr ?? ''}:${nameEn ?? ''}');
}
