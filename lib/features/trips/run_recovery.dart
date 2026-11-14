import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:run_recovery/run_recovery.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Run recovery on iPhone (Prompt 13, owner request 14 Nov 2026 13:44).
///
/// Switching apps, a phone call or the lock screen never stop tracking:
/// the geolocator stream runs with background updates (Info.plist
/// `location` mode, no automatic pausing, the blue indicator) and nothing
/// in the app stops it on `paused`, `inactive` or `hidden`. iOS can still
/// close the app (memory, a swipe away). Then:
/// - with the optional "Always", the run_recovery plugin's significant
///   location changes make iOS relaunch the app in the background; at
///   start (before any screen), [RunRecoveryService.recover] reads the
///   local [RunMarker], checks the run on the server and restarts the
///   tracker, sends the points waiting on the phone and shows "Tracking
///   resumed";
/// - without it, the server pushes the driver "Run still on" after 2
///   minutes and tells the parents (the fallback).
///
/// The marker holds IDs and a start time only (no coordinates, no names).

/// A run this phone is driving. Cleared at the end of the run and on sign-out.
@immutable
class RunMarker {
  const RunMarker({required this.uid, required this.carpoolId, required this.runId, required this.startedAt});

  final String uid;
  final String carpoolId;
  final String runId;
  final DateTime startedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'uid': uid,
    'carpoolId': carpoolId,
    'runId': runId,
    'startedAtMs': startedAt.toUtc().millisecondsSinceEpoch,
  };

  static RunMarker? fromJson(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      final Object? data = jsonDecode(raw);
      if (data is! Map) {
        return null;
      }
      final Object? uid = data['uid'];
      final Object? carpoolId = data['carpoolId'];
      final Object? runId = data['runId'];
      final Object? started = data['startedAtMs'];
      if (uid is! String || carpoolId is! String || runId is! String || started is! int) {
        return null;
      }
      return RunMarker(uid: uid, carpoolId: carpoolId, runId: runId, startedAt: DateTime.fromMillisecondsSinceEpoch(started, isUtc: true));
    } on FormatException {
      return null;
    }
  }
}

/// A recovered run older than this is not resumed (the server ends runs
/// after 4 hours; a school run is far shorter).
const Duration kRecoveryMaxAge = Duration(hours: 3);

enum RecoveryStep {
  /// No run was on: nothing to do.
  none,

  /// Ask the server whether the run is still on.
  checkServer,

  /// Start tracking again.
  resume,

  /// Forget the marker (with [RecoveryDecision.reason]).
  clear,
}

enum RecoveryClearReason { signedOut, otherParent, tooOld, runEnded }

@immutable
class RecoveryDecision {
  const RecoveryDecision(this.step, [this.reason]);

  final RecoveryStep step;
  final RecoveryClearReason? reason;

  @override
  bool operator ==(Object other) => other is RecoveryDecision && other.step == step && other.reason == reason;

  @override
  int get hashCode => Object.hash(step, reason);

  @override
  String toString() => 'RecoveryDecision($step, $reason)';
}

/// The whole rule, without plugins or Firebase (unit-tested).
/// [runActive]: null before the server was asked.
RecoveryDecision decideRecovery({
  required RunMarker? marker,
  required String? signedInUid,
  required DateTime now,
  bool? runActive,
  Duration maxAge = kRecoveryMaxAge,
}) {
  if (marker == null) {
    return const RecoveryDecision(RecoveryStep.none);
  }
  if (signedInUid == null) {
    return const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.signedOut);
  }
  if (signedInUid != marker.uid) {
    return const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.otherParent);
  }
  final Duration age = now.toUtc().difference(marker.startedAt);
  if (age.isNegative || age > maxAge) {
    return const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.tooOld);
  }
  return switch (runActive) {
    null => const RecoveryDecision(RecoveryStep.checkServer),
    true => const RecoveryDecision(RecoveryStep.resume),
    false => const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.runEnded),
  };
}

/// The native side, behind an interface (tests use [FakeRecoveryNative]).
abstract interface class RecoveryNative {
  bool get supported;
  Future<RecoveryAuthorization> authorization();
  Future<RecoveryAuthorization> requestAlways();
  Future<bool> startRun();
  Future<void> stopRun();
  Future<bool> launchedForLocation();
}

class PluginRecoveryNative implements RecoveryNative {
  PluginRecoveryNative([RunRecovery? plugin]) : _plugin = plugin ?? RunRecovery();

  final RunRecovery _plugin;

  @override
  bool get supported => _plugin.supported;

  @override
  Future<RecoveryAuthorization> authorization() => _plugin.authorization();

  @override
  Future<RecoveryAuthorization> requestAlways() => _plugin.requestAlways();

  @override
  Future<bool> startRun() => _plugin.startRun();

  @override
  Future<void> stopRun() => _plugin.stopRun();

  @override
  Future<bool> launchedForLocation() => _plugin.launchedForLocation();
}

/// Tests, the web, Android and the gallery.
class FakeRecoveryNative implements RecoveryNative {
  FakeRecoveryNative({this.supported = false, this.status = RecoveryAuthorization.unsupported, this.afterRequest});

  @override
  final bool supported;
  RecoveryAuthorization status;

  /// What the "system prompt" answers; null: unchanged.
  RecoveryAuthorization? afterRequest;
  int requests = 0;
  int starts = 0;
  int stops = 0;
  bool launched = false;

  @override
  Future<RecoveryAuthorization> authorization() async => status;

  @override
  Future<RecoveryAuthorization> requestAlways() async {
    requests++;
    status = afterRequest ?? status;
    return status;
  }

  @override
  Future<bool> startRun() async {
    starts++;
    return status == RecoveryAuthorization.always;
  }

  @override
  Future<void> stopRun() async => stops++;

  @override
  Future<bool> launchedForLocation() async => launched;
}

enum RecoveryOutcome { nothing, resumed, cleared, failed }

class RunRecoveryService {
  RunRecoveryService({
    required this._store,
    required this._native,
    required this._trips,
    required this._tracker,
    required this._notify,
    this._now = _utcNow,
  });

  static DateTime _utcNow() => DateTime.now().toUtc();

  static const String markerKey = 'runMarker.v1';

  /// The optional "Always" screen is shown once per install.
  static const String alwaysAskedKey = 'runRecovery.alwaysAsked';

  final SettingsStore _store;
  final RecoveryNative _native;
  final TripRepository _trips;
  final LocationTracker _tracker;

  /// Shows "Tracking resumed" (a local notification).
  final Future<void> Function() _notify;
  final DateTime Function() _now;

  RunMarker? get marker => RunMarker.fromJson(_store.read(markerKey));

  /// A run started (or resumed) on this phone.
  Future<void> runStarted({required String uid, required String carpoolId, required String runId}) async {
    final RunMarker? existing = marker;
    final bool same = existing != null && existing.uid == uid && existing.carpoolId == carpoolId && existing.runId == runId;
    final RunMarker next = same ? existing : RunMarker(uid: uid, carpoolId: carpoolId, runId: runId, startedAt: _now());
    await _store.write(markerKey, jsonEncode(next.toJson()));
    await _guard(_native.startRun);
  }

  /// The run ended, tracking stopped or the parent signed out.
  Future<void> runEnded() async {
    if (_store.read(markerKey) == null) {
      return;
    }
    await _store.write(markerKey, null);
    await _guard(_native.stopRun);
  }

  /// At app start (also a background relaunch, before any screen).
  Future<RecoveryOutcome> recover(String? signedInUid) async {
    final RunMarker? m = marker;
    RecoveryDecision decision = decideRecovery(marker: m, signedInUid: signedInUid, now: _now());
    if (decision.step == RecoveryStep.none || m == null) {
      return RecoveryOutcome.nothing;
    }
    if (decision.step == RecoveryStep.checkServer) {
      try {
        final TripPreparation prep = await _trips.prepare(m.carpoolId, m.runId);
        decision = decideRecovery(marker: m, signedInUid: signedInUid, now: _now(), runActive: prep.active);
      } on TripFailure catch (failure) {
        if (failure.isOffline) {
          // Keep the marker: the next start (or the run screen) tries again.
          return RecoveryOutcome.failed;
        }
        decision = const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.runEnded);
      }
    }
    if (decision.step == RecoveryStep.clear) {
      await runEnded();
      return RecoveryOutcome.cleared;
    }
    try {
      final TripSession session = await _trips.start(m.carpoolId, m.runId);
      await _tracker.start(TrackerSession(tripId: session.tripId, uploadUrl: _trips.uploadUrl(session.tripId), token: session.token));
      await _guard(_native.startRun);
      await _guard(_notify);
      return RecoveryOutcome.resumed;
    } on TripFailure {
      return RecoveryOutcome.failed;
    } on StateError {
      // The permission went away: the run screen shows the steps.
      return RecoveryOutcome.failed;
    }
  }

  /// The optional "Always" step: only on iPhone, only with "While Using
  /// the App" already given, once per install.
  Future<bool> shouldOfferAlways() async {
    if (!_native.supported || _store.read(alwaysAskedKey) != null) {
      return false;
    }
    return await _native.authorization() == RecoveryAuthorization.whenInUse;
  }

  Future<bool> requestAlways() async {
    await _store.write(alwaysAskedKey, '1');
    return await _native.requestAlways() == RecoveryAuthorization.always;
  }

  Future<void> declineAlways() => _store.write(alwaysAskedKey, '1');

  static Future<void> _guard(Future<Object?> Function() body) async {
    try {
      await body();
    } on Object catch (error) {
      debugPrint('run recovery: ${error.runtimeType}');
    }
  }
}

/// Replaced in bootstrap.dart on the phone with [PluginRecoveryNative].
final Provider<RecoveryNative> recoveryNativeProvider = Provider<RecoveryNative>((Ref ref) => FakeRecoveryNative());

final Provider<RunRecoveryService> runRecoveryProvider = Provider<RunRecoveryService>((Ref ref) {
  return RunRecoveryService(
    store: ref.watch(settingsStoreProvider),
    native: ref.watch(recoveryNativeProvider),
    trips: ref.watch(tripRepositoryProvider),
    tracker: ref.watch(locationTrackerProvider),
    notify: () async {
      final AppLocalizations l10n = lookupAppLocalizations(ref.read(localeProvider));
      await ref.read(localAlarmsProvider).ringNow(id: alarmIdFor('run-resumed'), title: l10n.recoveryResumedTitle, body: l10n.recoveryResumedBody, payload: '/notifications');
    },
  );
});

/// Read once in bootstrap.dart (before the first frame, so it also runs
/// when iOS relaunches the app in the background): recovers a run when the
/// session is known, and forgets the marker when tracking stops.
final Provider<void> runRecoveryLauncherProvider = Provider<void>((Ref ref) {
  bool tried = false;
  ref.listen<SessionState>(sessionProvider, (SessionState? previous, SessionState next) {
    final RunRecoveryService service = ref.read(runRecoveryProvider);
    switch (next) {
      case SessionSignedIn(:final String uid) when !tried:
        tried = true;
        unawaited(service.recover(uid).then((_) {}, onError: (Object _) {}));
      case SessionSignedOut():
        unawaited(service.runEnded());
      case _:
        break;
    }
  }, fireImmediately: true);
  final StreamSubscription<TrackerStatus> sub = ref.watch(locationTrackerProvider).status.listen((TrackerStatus s) {
    if (!s.tracking && s.tripId == null) {
      unawaited(ref.read(runRecoveryProvider).runEnded());
    }
  });
  ref.onDispose(sub.cancel);
});

/// Analytics for the optional step (no location data).
void trackAlwaysChoice(Analytics analytics, {required bool granted}) =>
    analytics.track(AnalyticsEvent.alwaysLocation, <String, Object?>{'granted': granted});
