import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

String _text(Object? value) => value is String ? value : '';

/// A school by ID and names (driving schools, map filters).
@immutable
class SchoolRef {
  const SchoolRef({required this.id, required this.nameAr, required this.nameEn});

  final String id;
  final String nameAr;
  final String nameEn;

  String name(String languageCode) {
    final String preferred = languageCode == 'ar' ? nameAr : nameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? nameEn : nameAr);
  }

  @override
  bool operator ==(Object other) =>
      other is SchoolRef && other.id == id && other.nameAr == nameAr && other.nameEn == nameEn;

  @override
  int get hashCode => Object.hash(id, nameAr, nameEn);
}

/// The parent's own homes/{uid}: their EXACT home (only they can read it)
/// and their map settings. Written only by Cloud Functions.
@immutable
class HomeLocation {
  const HomeLocation({
    this.location,
    this.label = '',
    this.showOnMap = true,
    this.notifyNewParents = true,
    this.radiusKm = Geo.defaultRadiusKm,
    this.drivingSchools = const <SchoolRef>[],
    this.address,
  });

  factory HomeLocation.fromMap(Map<String, Object?> data) {
    final Object? loc = data['location'];
    final Object? schools = data['drivingSchools'];
    final Object? radius = data['radiusKm'];
    return HomeLocation(
      location: loc is GeoPoint ? GeoPin(loc.latitude, loc.longitude) : null,
      label: _text(data['label']),
      showOnMap: data['showOnMap'] != false,
      notifyNewParents: data['notifyNewParents'] != false,
      radiusKm: radius is num ? radius.toInt() : Geo.defaultRadiusKm,
      drivingSchools: <SchoolRef>[
        if (schools is List<Object?>)
          for (final Object? s in schools)
            if (s is Map<Object?, Object?> && _text(s['id']).isNotEmpty)
              SchoolRef(id: _text(s['id']), nameAr: _text(s['nameAr']), nameEn: _text(s['nameEn'])),
      ],
      address: HomeAddress.fromMap(data['address']),
    );
  }

  /// Null until the parent sets a home.
  final GeoPin? location;
  final String label;
  final bool showOnMap;
  final bool notifyNewParents;
  final int radiusKm;
  final List<SchoolRef> drivingSchools;

  /// F46: the structured address, or null (a home set before F46, or none).
  final HomeAddress? address;

  bool get hasHome => location != null;

  HomeLocation copyWith({bool? showOnMap, bool? notifyNewParents, int? radiusKm, List<SchoolRef>? drivingSchools}) =>
      HomeLocation(
        location: location,
        label: label,
        showOnMap: showOnMap ?? this.showOnMap,
        notifyNewParents: notifyNewParents ?? this.notifyNewParents,
        radiusKm: radiusKm ?? this.radiusKm,
        drivingSchools: drivingSchools ?? this.drivingSchools,
        address: address,
      );
}

/// Another parent on the nearby map. [point] is the server's rounded
/// (about 500 m) point plus a fixed offset: never their home.
@immutable
class NearbyParent {
  const NearbyParent({required this.id, required this.firstName, required this.schoolId, required this.point});

  final String id;
  final String firstName;
  final String schoolId;
  final GeoPin point;
}

/// One line of the address search.
@immutable
class PlaceSuggestion {
  const PlaceSuggestion({required this.placeId, required this.primary, required this.secondary});

  final String placeId;
  final String primary;
  final String secondary;
}

/// A picked address.
@immutable
class PlaceResult {
  const PlaceResult({required this.placeId, required this.label, required this.location});

  final String placeId;
  final String label;
  final GeoPin location;
}

enum MapFailureKind { offline, rateLimited, notVerified, noHome, notYourSchool, outsideEgypt, invalid, suspended, unknown }

/// Why a maps call failed, from `details.reason` (functions/src/maps).
class MapFailure implements Exception {
  const MapFailure(this.kind, {this.retryAfter = Duration.zero});

  factory MapFailure.from(Object error) {
    if (error is MapFailure) {
      return error;
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Object? reason = details is Map<Object?, Object?> ? details['reason'] : null;
      final Object? retry = details is Map<Object?, Object?> ? details['retryAfterSeconds'] : null;
      final MapFailureKind kind = switch (reason) {
        'rate-limited' => MapFailureKind.rateLimited,
        'not-verified' => MapFailureKind.notVerified,
        'no-home' => MapFailureKind.noHome,
        'not-your-school' => MapFailureKind.notYourSchool,
        'outside-egypt' => MapFailureKind.outsideEgypt,
        'invalid-request' || 'invalid-location' || 'invalid-school' || 'too-many-schools' => MapFailureKind.invalid,
        'suspended' => MapFailureKind.suspended,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => MapFailureKind.offline,
          _ => MapFailureKind.unknown,
        },
      };
      return MapFailure(kind, retryAfter: Duration(seconds: retry is num ? retry.toInt() : 0));
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const MapFailure(MapFailureKind.offline);
    }
    return const MapFailure(MapFailureKind.unknown);
  }

  final MapFailureKind kind;
  final Duration retryAfter;

  bool get isOffline => kind == MapFailureKind.offline;

  String message(AppLocalizations l10n) => switch (kind) {
    MapFailureKind.offline => l10n.errorOfflineShort,
    MapFailureKind.rateLimited => l10n.mapErrorTooMany,
    MapFailureKind.notVerified => l10n.mapErrorNotVerified,
    MapFailureKind.noHome => l10n.mapErrorNoHome,
    MapFailureKind.notYourSchool => l10n.mapErrorNotYourSchool,
    MapFailureKind.outsideEgypt => l10n.mapErrorOutsideEgypt,
    MapFailureKind.suspended => l10n.errorSuspended,
    MapFailureKind.invalid || MapFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'MapFailure(${kind.name})';
}
