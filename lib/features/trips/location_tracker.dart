import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live location during a run (F15), behind one interface so tests, CI,
/// the website and the gallery use [FakeLocationTracker] and the phone uses
/// the free geolocator plugin (geolocator_tracker.dart; owner decision
/// 14 Nov 2026, docs/DECISIONS.md "Location tracking on iPhone").
///
/// Rules (spec section 6, "Live location"): tracking starts with the run,
/// sends a point every 5 to 10 seconds also with the phone locked, stops
/// at the last drop-off and never runs outside a run. Points go from the
/// phone's location plugin straight to the tripLocation function with the
/// run's own token; the app never writes a point to Firestore. Before a
/// run the driving gate (location_gate.dart) checks Location Services, the
/// permission ("While Using the App" is enough; "Always" is never
/// required, only offered once as an optional step for run recovery),
/// Precise Location and notifications.

/// Where the background location permission stands.
enum TrackerPermission {
  /// Not asked yet: show the explanation screen, then the system prompt.
  notAsked,

  /// "Always" (iPhone) / "Allow all the time" (Android): a run may start.
  always,

  /// "While Using the App": a run may start (background location mode and
  /// the blue indicator keep it going with the phone locked).
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

  Future<void> openSettings();

  /// Starts sending points for [session]. Throws [StateError] when the
  /// permission is missing. Starting again for the same trip only renews the token.
  Future<void> start(TrackerSession session);

  /// Stops sending. Points not sent yet are cleared (the run is over),
  /// unless [keepUnsent]: then the tracker tries to send them first.
  Future<void> stop({bool keepUnsent = false});

  /// The trip being tracked on this phone, or null (also after a restart).
  Future<String?> activeTrip();

  Stream<TrackerStatus> get status;
}

/// For tests, CI, the website (drivers use the phone app) and the gallery.
class FakeLocationTracker implements LocationTracker {
  FakeLocationTracker({this._permission = TrackerPermission.whileInUse});

  TrackerPermission _permission;

  final StreamController<TrackerStatus> _status = StreamController<TrackerStatus>.broadcast();
  TrackerSession? session;
  int starts = 0;
  int stops = 0;

  /// Whether the last stop kept the points not sent yet.
  bool? lastStopKeptUnsent;
  int settingsOpened = 0;

  set permissionValue(TrackerPermission value) => _permission = value;

  @override
  Future<TrackerPermission> permission() async => _permission;

  @override
  Future<void> openSettings() async => settingsOpened++;

  @override
  Future<void> start(TrackerSession s) async {
    if (_permission != TrackerPermission.always && _permission != TrackerPermission.whileInUse) {
      throw StateError('location permission missing');
    }
    session = s;
    starts++;
    _status.add(TrackerStatus(tracking: true, tripId: s.tripId));
  }

  @override
  Future<void> stop({bool keepUnsent = false}) async {
    if (session != null) {
      stops++;
      lastStopKeptUnsent = keepUnsent;
    }
    session = null;
    _status.add(TrackerStatus.idle);
  }

  @override
  Future<String?> activeTrip() async => session?.tripId;

  @override
  Stream<TrackerStatus> get status => _status.stream;

  /// Tests: Location Services or the permission went away mid-run.
  void lose(TrackerPermission permission) {
    _permission = permission;
    _status.add(TrackerStatus(tracking: session != null, tripId: session?.tripId, permission: permission));
  }

  /// Tests: a location fix arrived.
  void fix(DateTime at) => _status.add(TrackerStatus(tracking: session != null, tripId: session?.tripId, lastFixAt: at));

  Future<void> dispose() => _status.close();
}

/// Replaced in bootstrap.dart for the phone (geolocator_tracker.dart);
/// the fake everywhere else, so nothing ever tracks outside a run.
final Provider<LocationTracker> locationTrackerProvider = Provider<LocationTracker>((Ref ref) {
  final FakeLocationTracker tracker = FakeLocationTracker();
  ref.onDispose(() => unawaited(tracker.dispose()));
  return tracker;
});
