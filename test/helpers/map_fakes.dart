import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/location_service.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_view.dart';

/// Fake homes and parents for widget tests (fake data only).
const GeoPin testHome = GeoPin(29.96123, 31.25671);

/// Points as the server sends them: rounded cell centres plus an offset.
const List<NearbyParent> testNearbyParents = <NearbyParent>[
  NearbyParent(id: 'p1', firstName: 'Hoda', schoolId: 'nile', point: GeoPin(29.96712, 31.26203)),
  NearbyParent(id: 'p2', firstName: 'Tarek', schoolId: 'nile', point: GeoPin(29.95281, 31.25018)),
];

/// Records calls; answers from its fields; fails with [failure] while set.
class FakeMapRepository implements MapRepository {
  FakeMapRepository({this._home, this.parents = testNearbyParents});

  HomeLocation? _home;
  List<NearbyParent> parents;
  MapFailure? failure;
  MapFailure? nearbyFailure;

  /// When set, the home stream fails with it (error and offline states).
  Object? homeError;
  final List<String> calls = <String>[];
  final List<(String, int)> searches = <(String, int)>[];
  GeoPin? savedHome;
  String? savedLabel;
  final StreamController<HomeLocation?> _changes = StreamController<HomeLocation?>.broadcast();

  void _maybeFail() {
    final MapFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  void _emit(HomeLocation next) {
    _home = next;
    _changes.add(next);
  }

  @override
  Stream<HomeLocation?> watchHome(String uid) async* {
    final Object? error = homeError;
    if (error != null) {
      throw error;
    }
    yield _home;
    yield* _changes.stream;
  }

  @override
  Future<GeoPin> setHome(GeoPin location, {String label = ''}) async {
    calls.add('setHome');
    _maybeFail();
    savedHome = location;
    savedLabel = label;
    final HomeLocation h = _home ?? const HomeLocation();
    _emit(HomeLocation(
      location: location,
      label: label,
      showOnMap: h.showOnMap,
      notifyNewParents: h.notifyNewParents,
      radiusKm: h.radiusKm,
      drivingSchools: h.drivingSchools,
    ));
    return location;
  }

  @override
  Future<void> updateSettings({bool? showOnMap, bool? notifyNewParents, int? radiusKm}) async {
    calls.add('updateSettings:$showOnMap:$notifyNewParents:$radiusKm');
    _maybeFail();
    _emit((_home ?? const HomeLocation()).copyWith(showOnMap: showOnMap, notifyNewParents: notifyNewParents, radiusKm: radiusKm));
  }

  @override
  Future<List<SchoolRef>> setDrivingSchools(List<String> schoolIds) async {
    calls.add('setDrivingSchools:${schoolIds.join(',')}');
    _maybeFail();
    final List<SchoolRef> refs = <SchoolRef>[for (final String id in schoolIds) SchoolRef(id: id, nameAr: id, nameEn: id)];
    _emit((_home ?? const HomeLocation()).copyWith(drivingSchools: refs));
    return refs;
  }

  @override
  Future<List<NearbyParent>> nearby({required String schoolId, required int radiusKm}) async {
    searches.add((schoolId, radiusKm));
    final MapFailure? f = nearbyFailure ?? failure;
    if (f != null) {
      throw f;
    }
    return parents.where((NearbyParent p) => p.schoolId == schoolId).toList();
  }

  /// School pins by school ID (F40).
  Map<String, GeoPin> schoolPins = <String, GeoPin>{'nile': const GeoPin(29.9602, 31.2569)};

  @override
  Future<GeoPin?> schoolPin(String schoolId) async => schoolPins[schoolId];

  Future<void> dispose() => _changes.close();
}

class FakePlacesRepository implements PlacesRepository {
  final List<String> tokens = <String>[];
  final List<String> inputs = <String>[];
  MapFailure? failure;

  static const PlaceResult maadi = PlaceResult(placeId: 'fake-maadi', label: 'Road 9, Maadi, Cairo', location: GeoPin(29.9602, 31.2569));

  @override
  Future<List<PlaceSuggestion>> autocomplete(String input, {required String sessionToken, required String language, GeoPin? near}) async {
    inputs.add(input);
    tokens.add(sessionToken);
    final MapFailure? f = failure;
    if (f != null) {
      throw f;
    }
    return input.toLowerCase().contains('maadi') || input.contains('معادي')
        ? const <PlaceSuggestion>[PlaceSuggestion(placeId: 'fake-maadi', primary: 'Road 9, Maadi', secondary: 'Cairo')]
        : const <PlaceSuggestion>[];
  }

  @override
  Future<PlaceResult> details(String placeId, {required String sessionToken, required String language}) async {
    tokens.add(sessionToken);
    return maadi;
  }
}

class FakeLocationService implements LocationService {
  FakeLocationService({this.accessValue = LocationAccess.notAsked, this.afterRequest = LocationAccess.granted});

  LocationAccess accessValue;
  LocationAccess afterRequest;
  GeoPin here = const GeoPin(30.0626, 31.2197);
  int requests = 0;
  int settingsOpened = 0;

  @override
  Future<LocationAccess> access() async => accessValue;

  @override
  Future<LocationAccess> request() async {
    requests++;
    return accessValue = afterRequest;
  }

  @override
  Future<GeoPin> current() async => here;

  @override
  Future<void> openSettings() async {
    settingsOpened++;
  }
}

/// Keeps Firebase, Google Maps and the GPS out of widget tests: the maps
/// are drawn by the sketch (markers and discs keyed `map.marker.<id>` and
/// `map.area.<id>`).
List<Override> mapOverrides({MapRepository? maps, PlacesRepository? places, LocationService? location}) => <Override>[
  mapRepositoryProvider.overrideWithValue(maps ?? FakeMapRepository()),
  placesRepositoryProvider.overrideWithValue(places ?? FakePlacesRepository()),
  locationServiceProvider.overrideWithValue(location ?? FakeLocationService()),
  mapViewBuilderProvider.overrideWithValue(sketchMapViewBuilder),
];
