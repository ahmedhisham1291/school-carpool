import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';

/// Why the guard stops tracking for [next], or null to leave it running.
///
/// Live location never outlives the driver's session, but a relaunch in
/// the middle of a run must not stop it: while the session is loading,
/// failed (for example offline) or the account record is not loaded yet,
/// nothing is decided. Tracking stops only when
/// - the parent is signed out,
/// - another parent is signed in on this phone ([driver] is the uid seen
///   before in this app run), or
/// - the account is loaded and not verified (suspended, rejected,
///   unverified, back in review).
/// The server refuses such uploads too and ends the driver's trips.
TrackerGuardStop? trackerGuardDecision(SessionState next, String? driver) {
  return switch (next) {
    SessionLoading() || SessionFailed() => null,
    SessionSignedOut() => TrackerGuardStop.signedOut,
    SessionSignedIn(:final String uid, :final Account? account) => switch (account) {
      _ when driver != null && uid != driver => TrackerGuardStop.otherParent,
      null => null,
      Account(:final AccountStatus status) when status != AccountStatus.verified => TrackerGuardStop.notVerified,
      _ => null,
    },
  };
}

enum TrackerGuardStop { signedOut, otherParent, notVerified }

/// Watched by the app. Applies [trackerGuardDecision] on every session
/// change. Points not sent yet are kept (sent first if possible), so a
/// guard stop never deletes a driver's track.
final Provider<void> trackerGuardProvider = Provider<void>((Ref ref) {
  String? driver;
  ref.listen<SessionState>(sessionProvider, (SessionState? previous, SessionState next) {
    final TrackerGuardStop? stop = trackerGuardDecision(next, driver);
    if (next is SessionSignedIn) {
      driver = next.uid;
    } else if (next is SessionSignedOut) {
      driver = null;
    }
    if (stop == null) {
      return;
    }
    final LocationTracker tracker = ref.read(locationTrackerProvider);
    unawaited(
      tracker.activeTrip().then((String? trip) async {
        if (trip != null) {
          await tracker.stop(keepUnsent: true);
        }
      }, onError: (Object _) {}),
    );
  }, fireImmediately: true);
});
