import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:school_carpool/features/maps/geo.dart';

/// Where "use my current location" stands.
enum LocationAccess {
  /// Not asked yet: show our explanation screen first, then the system prompt.
  notAsked,
  granted,

  /// Refused once; asking again is allowed.
  denied,

  /// Refused for good: only the phone's Settings can change it.
  deniedForever,

  /// Location services are off on the phone.
  serviceOff,
}

enum LocationFailureKind { denied, serviceOff, timeout, unknown }

class LocationFailure implements Exception {
  const LocationFailure(this.kind);

  final LocationFailureKind kind;

  @override
  String toString() => 'LocationFailure(${kind.name})';
}

/// One-shot location for the home picker. "While using the app" only; the
/// app never tracks a parent outside a run (runs come in Prompt 13 with
/// flutter_background_geolocation). The position is used to move the pin
/// and is sent nowhere until the parent saves.
abstract interface class LocationService {
  Future<LocationAccess> access();

  /// Shows the system prompt (call after our explanation screen).
  Future<LocationAccess> request();

  /// Throws [LocationFailure].
  Future<GeoPin> current();

  Future<void> openSettings();
}

class GeolocatorLocationService implements LocationService {
  const GeolocatorLocationService();

  static LocationAccess _map(LocationPermission p) => switch (p) {
    LocationPermission.always || LocationPermission.whileInUse => LocationAccess.granted,
    LocationPermission.deniedForever => LocationAccess.deniedForever,
    LocationPermission.denied => LocationAccess.notAsked,
    LocationPermission.unableToDetermine => LocationAccess.notAsked,
  };

  @override
  Future<LocationAccess> access() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceOff;
    }
    return _map(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> request() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceOff;
    }
    final LocationPermission p = await Geolocator.requestPermission();
    return p == LocationPermission.denied ? LocationAccess.denied : _map(p);
  }

  @override
  Future<GeoPin> current() async {
    try {
      final Position p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(timeLimit: Duration(seconds: 15)),
      );
      return GeoPin(p.latitude, p.longitude);
    } on LocationServiceDisabledException {
      throw const LocationFailure(LocationFailureKind.serviceOff);
    } on PermissionDeniedException {
      throw const LocationFailure(LocationFailureKind.denied);
    } on TimeoutException {
      throw const LocationFailure(LocationFailureKind.timeout);
    } on Exception {
      throw const LocationFailure(LocationFailureKind.unknown);
    }
  }

  @override
  Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }
}

final Provider<LocationService> locationServiceProvider = Provider<LocationService>(
  (Ref ref) => const GeolocatorLocationService(),
);
