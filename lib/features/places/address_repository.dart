import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/firebase/callable_error.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum AddressFailureKind { area, district, street, building, extra, pinOutsideArea, outsideEgypt, rateLimited, offline, unknown }

/// Why an address call failed (functions/src/places/address.ts and the maps reasons).
class AddressFailure implements AppFailure {
  const AddressFailure(this.kind, {this.demo, this.areaNameAr = '', this.areaNameEn = ''});

  factory AddressFailure.from(Object error) {
    if (error is AddressFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return AddressFailure(AddressFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final String? reason = callableReason(error);
      switch (reason) {
        case 'invalid-city' || 'invalid-area':
          return const AddressFailure(AddressFailureKind.area);
        case 'invalid-district':
          return const AddressFailure(AddressFailureKind.district);
        case 'invalid-street':
          return const AddressFailure(AddressFailureKind.street);
        case 'invalid-building':
          return const AddressFailure(AddressFailureKind.building);
        case 'invalid-extra':
          return const AddressFailure(AddressFailureKind.extra);
        case 'pin-outside-area':
          final Map<Object?, Object?> d = details is Map<Object?, Object?> ? details : const <Object?, Object?>{};
          return AddressFailure(
            AddressFailureKind.pinOutsideArea,
            areaNameAr: d['areaNameAr'] is String ? d['areaNameAr']! as String : '',
            areaNameEn: d['areaNameEn'] is String ? d['areaNameEn']! as String : '',
          );
      }
    }
    final MapFailure map = MapFailure.from(error);
    return AddressFailure(switch (map.kind) {
      MapFailureKind.offline => AddressFailureKind.offline,
      MapFailureKind.outsideEgypt => AddressFailureKind.outsideEgypt,
      MapFailureKind.rateLimited => AddressFailureKind.rateLimited,
      _ => AddressFailureKind.unknown,
    });
  }

  final AddressFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  /// pinOutsideArea: the chosen area's names (from the server).
  final String areaNameAr;
  final String areaNameEn;

  @override
  bool get isOffline => kind == AddressFailureKind.offline;

  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    AddressFailureKind.area => l10n.addressErrorArea,
    AddressFailureKind.district => l10n.addressErrorDistrict,
    AddressFailureKind.street => l10n.addressStreetError,
    AddressFailureKind.building => l10n.addressBuildingError,
    AddressFailureKind.extra => l10n.addressExtraError,
    AddressFailureKind.pinOutsideArea => l10n.addressPinOutsideArea(_areaName(l10n)),
    AddressFailureKind.outsideEgypt => l10n.mapErrorOutsideEgypt,
    AddressFailureKind.rateLimited => l10n.mapErrorTooMany,
    AddressFailureKind.offline => l10n.errorOfflineShort,
    AddressFailureKind.unknown => l10n.errorGeneric,
  };

  String _areaName(AppLocalizations l10n) {
    final bool arabic = l10n.localeName.startsWith('ar');
    final String first = arabic ? areaNameAr : areaNameEn;
    return first.isNotEmpty ? first : (arabic ? areaNameEn : areaNameAr);
  }

  @override
  String toString() => 'AddressFailure(${kind.name})';
}

/// Where the map starts for the parent to confirm (F46).
class GeocodeResult {
  const GeocodeResult({required this.location, required this.approximate});

  /// Null when neither the search nor the places gave a point.
  final GeoPin? location;

  /// True when the pin is only the district's or area's centre.
  final bool approximate;
}

/// F46 address calls. Every method throws [AddressFailure].
abstract interface class AddressRepository {
  Future<PlaceHit> placeForPoint(GeoPin point);
  Future<GeocodeResult> geocode(HomeAddress address, {required String sessionToken, required String language});

  /// Saves the address with its exact pin; returns the rounded point others see.
  Future<GeoPin> save(HomeAddress address, GeoPin location);
}

class FirebaseAddressRepository implements AddressRepository {
  FirebaseAddressRepository(this._functions);

  final FirebaseFunctions _functions;

  Future<Map<Object?, Object?>> _call(String name, Map<String, Object?> data) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? out = result.data;
      return out is Map<Object?, Object?> ? out : const <Object?, Object?>{};
    } on Object catch (error) {
      throw AddressFailure.from(error);
    }
  }

  static GeoPin? _pin(Object? v) {
    if (v is Map<Object?, Object?> && v['lat'] is num && v['lng'] is num) {
      return GeoPin((v['lat']! as num).toDouble(), (v['lng']! as num).toDouble());
    }
    return null;
  }

  static String? _id(Object? v) => v is String && v.isNotEmpty ? v : null;

  @override
  Future<PlaceHit> placeForPoint(GeoPin point) async {
    final Map<Object?, Object?> r = await _call('placeForPoint', <String, Object?>{'location': point.toJson()});
    return PlaceHit(governorate: _id(r['governorate']), placeAreaId: _id(r['placeAreaId']), placeDistrictId: _id(r['placeDistrictId']));
  }

  @override
  Future<GeocodeResult> geocode(HomeAddress address, {required String sessionToken, required String language}) async {
    final Map<Object?, Object?> r = await _call('geocodeAddress', <String, Object?>{
      'address': address.toJson(),
      'sessionToken': sessionToken,
      'language': language,
    });
    return GeocodeResult(location: _pin(r['location']), approximate: r['approximate'] != false);
  }

  @override
  Future<GeoPin> save(HomeAddress address, GeoPin location) async {
    final Map<Object?, Object?> r = await _call('setHomeAddress', <String, Object?>{
      'address': address.toJson(),
      'location': location.toJson(),
    });
    return _pin(r['approximate']) ?? location;
  }
}

final Provider<AddressRepository> addressRepositoryProvider = Provider<AddressRepository>(
  (Ref ref) => FirebaseAddressRepository(functionsClient()),
);
