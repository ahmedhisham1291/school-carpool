import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live location during a run (F15), behind one interface so tests, CI,
/// the website and the gallery use [FakeLocationTracker] and the phone uses
/// flutter_background_geolocation (background_location_tracker.dart).
///
/// Rules (spec section 6, "Live location"): tracking starts with the run,
/// sends a point every 5 to 10 seconds also with the phone locked, stops
/// at the last drop-off and never runs outside a run. Points go from the
/// phone's location plugin straight to the tripLocation function with the
/// run's own token; the app never writes a point to Firestore.

/// Where the background location permission stands.
enum TrackerPermission {
  /// Not asked yet: show the explanation screen, then the system prompt.
  notAsked,

  /// "Always" (iPhone) / "Allow all the time" (Android): a run may start.
  always,

  /// Only while the app is open: not enough for a run.
  whileInUse,

  /// Refused: only the phone's Settings can change it.
  denied,

  /// Location services are off on the phone.
  serviceOff,
}

/// What the tracker needs for one run.
@immutable
class TrackerSession {
  const TrackerSession({required this.tripId, required this.uploadUrl, required this.token});

  final String tripId;

  /// The tripLocation function, with `?trip=<tripId>`.
  final String uploadUrl;

  /// Bearer token for this trip only (expires with the run).
  final String token;
}

/// What the driver screen shows about tracking.
@immutable
class TrackerStatus {
  const TrackerStatus({required this.tracking, this.tripId, this.lastFixAt, this.permission = TrackerPermission.always});

  static const TrackerStatus idle = TrackerStatus(tracking: false);

  final bool tracking;
  final String? tripId;

  /// When the phone last had a location fix (UTC).
  final DateTime? lastFixAt;
  final TrackerPermission permission;
}

abstract interface class LocationTracker {
  Future<TrackerPermission> permission();

  /// Shows the system prompt for "Always" (call after the explanation screen).
  Future<TrackerPermission> requestAlways();

  Future<void> openSettings();

  /// Starts sending points for [session]. Throws when the permission is
  /// missing. Starting again for the same trip only renews the token.
  Future<void> start(TrackerSession session);

  /// Stops sending and clears points not yet sent (the run is over).
  Future<void> stop();

  /// The trip being tracked on this phone, or null (also after a restart).
  Future<String?> activeTrip();

  Stream<TrackerStatus> get status;
}

/// For tests, CI, the website (drivers use the phone app) and the gallery.
class FakeLocationTracker implements LocationTracker {
  FakeLocationTracker({TrackerPermission permission = TrackerPermission.notAsked, this.grantOnRequest = TrackerPermission.always})
    : _permission = permission;

  TrackerPermission _permission;

  /// What the "system prompt" answers.
  final TrackerPermission grantOnRequest;

  final StreamController<TrackerStatus> _status = StreamController<TrackerStatus>.broadcast();
  TrackerSession? session;
  int starts = 0;
  int stops = 0;
  int settingsOpened = 0;

  set permissionValue(TrackerPermission value) => _permission = value;

  @override
  Future<TrackerPermission> permission() async => _permission;

  @override
  Future<TrackerPermission> requestAlways() async {
    if (_permission == TrackerPermission.notAsked || _permission == TrackerPermission.whileInUse) {
      _permission = grantOnRequest;
    }
    return _permission;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<void> start(TrackerSession s) async {
    if (_permission != TrackerPermission.always) {
      throw StateError('background location permission missing');
    }
    session = s;
    starts++;
    _status.add(TrackerStatus(tracking: true, tripId: s.tripId));
  }

  @override
  Future<void> stop() async {
    if (session != null) {
      stops++;
    }
    session = null;
    _status.add(TrackerStatus.idle);
  }

  @override
  Future<String?> activeTrip() async => session?.tripId;

  @override
  Stream<TrackerStatus> get status => _status.stream;

  /// Tests: a location fix arrived.
  void fix(DateTime at) => _status.add(TrackerStatus(tracking: session != null, tripId: session?.tripId, lastFixAt: at));

  Future<void> dispose() => _status.close();
}

/// Replaced in main.dart builds for the phone (background_location_tracker.dart);
/// the fake everywhere else, so nothing ever tracks outside a run.
final Provider<LocationTracker> locationTrackerProvider = Provider<LocationTracker>((Ref ref) {
  final FakeLocationTracker tracker = FakeLocationTracker();
  ref.onDispose(() => unawaited(tracker.dispose()));
  return tracker;
});
