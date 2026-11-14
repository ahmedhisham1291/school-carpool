import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';

/// How often a running app tells the server this phone is still in use.
const Duration kTouchEvery = Duration(minutes: 15);

/// True when the phone should report itself now: a new session (another
/// uid), or [kTouchEvery] passed since the last report.
bool shouldTouch({required String uid, required String? lastUid, required DateTime? lastAt, required DateTime now}) =>
    uid != lastUid || lastAt == null || now.difference(lastAt) >= kTouchEvery;

/// Prompt 12 (spec section 7): the parent can sign out any phone from
/// another phone, and a sign-in from a new phone signs the others out. The
/// server cuts every session at once; this guard makes the phone that was
/// signed out notice it at its next start or resume and sign out cleanly
/// (live location stops, pushes stop, the session ends).
///
/// Offline or any error: nothing happens (the server has already revoked
/// the session, so the phone is signed out when its token expires).
final Provider<void> deviceGuardProvider = Provider<void>((Ref ref) {
  String? lastUid;
  DateTime? lastAt;
  bool busy = false;

  Future<void> check() async {
    final SessionState session = ref.read(sessionProvider);
    if (session is! SessionSignedIn || busy) {
      return;
    }
    final DateTime now = DateTime.now().toUtc();
    if (!shouldTouch(uid: session.uid, lastUid: lastUid, lastAt: lastAt, now: now)) {
      return;
    }
    busy = true;
    try {
      lastUid = session.uid;
      lastAt = now;
      final bool signedOut = await ref.read(privacyRepositoryProvider).touchDevice();
      if (signedOut) {
        await _signOutHere(ref);
      }
    } on Object catch (error) {
      debugPrint('device guard: ${error.runtimeType}');
    } finally {
      busy = false;
    }
  }

  ref.listen<SessionState>(sessionProvider, (SessionState? previous, SessionState next) {
    if (next is SessionSignedIn) {
      unawaited(check());
    } else {
      lastUid = null;
    }
  }, fireImmediately: true);

  final AppLifecycleListener lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
  ref.onDispose(lifecycle.dispose);
});

/// This phone was signed out from another phone: the same steps as the
/// Sign out button, without asking.
Future<void> _signOutHere(Ref ref) async {
  final LocationTracker tracker = ref.read(locationTrackerProvider);
  try {
    if (await tracker.activeTrip() != null) {
      await tracker.stop(keepUnsent: true);
    }
  } on Object {
    // The server ended the run when it signed this phone out.
  }
  ref.read(signupFlowProvider.notifier).reset();
  try {
    await ref.read(notificationCenterProvider).unregister();
  } on Object {
    // Best effort; the server removes dead tokens while sending.
  }
  await ref.read(authRepositoryProvider).signOut();
  await ref.read(pendingInviteProvider.notifier).save(null);
}
