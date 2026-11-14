import 'dart:async';

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:geolocator/geolocator.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';

/// [LocationTracker] on the phone: flutter_background_geolocation
/// (Transistor Software, paid licence for Android release builds; iPhone
/// and debug builds need none). It keeps sending with the phone locked or
/// another app open, and its own uploader posts each point to the
/// tripLocation function with the run's token, so points keep flowing even
/// when iOS pauses the Flutter engine. Points not sent yet wait on the
/// phone (weak connections) and are cleared when the run ends.
///
/// Tuned for the 5 to 10 second target (spec section 11): high accuracy,
/// a point every ~10 m of movement (about every 3 s at 15 km/h, 9 s at
/// 5 km/h) and a heartbeat fix every 60 s while the car waits at a home, so
/// the server's "location stopped" alert (120 s) means the phone really
/// stopped sending. Stop detection is off during a run: a car waiting at a
/// gate must not pause tracking.
class BackgroundLocationTracker implements LocationTracker {
  /// Listens from app start (also when iOS relaunches the app in the
  /// background during a run), so the server's "run over" answer stops
  /// tracking even if the driver never opens the run screen again.
  BackgroundLocationTracker() {
    unawaited(_ensureReady().then((_) {}, onError: (Object _) {}));
  }

  final StreamController<TrackerStatus> _status = StreamController<TrackerStatus>.broadcast();
  Future<void>? _ready;
  String? _tripId;

  static TrackerPermission _map(bg.ProviderChangeEvent e) {
    if (!e.enabled) {
      return TrackerPermission.serviceOff;
    }
    return switch (e.status) {
      bg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS => TrackerPermission.always,
      bg.ProviderChangeEvent.AUTHORIZATION_STATUS_WHEN_IN_USE => TrackerPermission.whileInUse,
      bg.ProviderChangeEvent.AUTHORIZATION_STATUS_NOT_DETERMINED => TrackerPermission.notAsked,
      _ => TrackerPermission.denied,
    };
  }

  Future<void> _ensureReady() => _ready ??= _init();

  Future<void> _init() async {
    bg.BackgroundGeolocation.onLocation(
      (bg.Location location) {
        final DateTime? at = DateTime.tryParse(location.timestamp)?.toUtc();
        _status.add(TrackerStatus(tracking: _tripId != null, tripId: _tripId, lastFixAt: at));
      },
      (bg.LocationError error) {
        // Never logged with a position (PRIVACY); the screen shows "no fix".
      },
    );
    bg.BackgroundGeolocation.onProviderChange((bg.ProviderChangeEvent event) {
      _status.add(TrackerStatus(tracking: _tripId != null, tripId: _tripId, permission: _map(event)));
    });
    bg.BackgroundGeolocation.onHeartbeat((bg.HeartbeatEvent event) {
      if (_tripId != null) {
        // Waiting at a stop: one fix a minute keeps the parents' map fresh.
        unawaited(bg.BackgroundGeolocation.getCurrentPosition(samples: 1, persist: true, timeout: 30).then((_) {}, onError: (Object _) {}));
      }
    });
    bg.BackgroundGeolocation.onHttp((bg.HttpEvent event) {
      // 410: the server ended the run (last drop-off or timeout). Stop at once.
      if (event.status == 410 || event.status == 401) {
        unawaited(stop());
      }
    });
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        // Plugin defaults kept: high accuracy, a point every 10 m, Always
        // permission, automatic upload one point at a time, one day on the
        // phone at most, logging off.
        locationUpdateInterval: 5000,
        fastestLocationUpdateInterval: 5000,
        disableElasticity: true,
        disableStopDetection: true,
        pausesLocationUpdatesAutomatically: false,
        heartbeatInterval: 60,
        preventSuspend: true,
        // Keeps tracking when the app is swiped away during a run; never
        // starts on boot (plugin default). The server's 410 and the
        // elapsed-time cap below stop it after the run.
        stopOnTerminate: false,
        showsBackgroundLocationIndicator: true,
      ),
    );
  }

  @override
  Future<TrackerPermission> permission() async {
    await _ensureReady();
    return _map(await bg.BackgroundGeolocation.providerState);
  }

  @override
  Future<TrackerPermission> requestAlways() async {
    await _ensureReady();
    try {
      await bg.BackgroundGeolocation.requestPermission();
    } on Exception {
      // Refused: the state below says so.
    }
    return _map(await bg.BackgroundGeolocation.providerState);
  }

  @override
  Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }

  @override
  Future<void> start(TrackerSession session) async {
    await _ensureReady();
    final TrackerPermission p = _map(await bg.BackgroundGeolocation.providerState);
    if (p != TrackerPermission.always) {
      throw StateError('background location permission missing');
    }
    _tripId = session.tripId;
    await bg.BackgroundGeolocation.setConfig(
      bg.Config(
        url: session.uploadUrl,
        headers: <String, dynamic>{'Authorization': 'Bearer ${session.token}'},
        extras: <String, dynamic>{'trip': session.tripId},
        httpRootProperty: 'location',
        // Hard cap, same as the server's (4 hours): never outside a run,
        // even if the app is never opened again.
        stopAfterElapsedMinutes: 240,
      ),
    );
    final bg.State state = await bg.BackgroundGeolocation.state;
    if (!state.enabled) {
      await bg.BackgroundGeolocation.start();
    }
    await bg.BackgroundGeolocation.changePace(true);
    _status.add(TrackerStatus(tracking: true, tripId: session.tripId));
  }

  @override
  Future<void> stop() async {
    _tripId = null;
    await _ensureReady();
    await bg.BackgroundGeolocation.stop();
    // Points not sent yet belong to a run that is over.
    await bg.BackgroundGeolocation.destroyLocations();
    await bg.BackgroundGeolocation.setConfig(bg.Config(url: '', headers: <String, dynamic>{}, extras: <String, dynamic>{}));
    _status.add(TrackerStatus.idle);
  }

  @override
  Future<String?> activeTrip() async {
    await _ensureReady();
    final bg.State state = await bg.BackgroundGeolocation.state;
    if (!state.enabled) {
      return null;
    }
    final Object? trip = state.extras?['trip'];
    _tripId = trip is String && trip.isNotEmpty ? trip : null;
    return _tripId;
  }

  @override
  Stream<TrackerStatus> get status => _status.stream;

  Future<void> dispose() => _status.close();
}
