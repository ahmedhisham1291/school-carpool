import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';

/// Review item 5: live location never outlives the driver's session. When
/// the parent signs out (or another parent signs in on this phone), or the
/// account stops being verified (suspended, banned, deleted), tracking
/// stops at once and points not sent yet are cleared. The server refuses
/// such uploads too (it re-checks the account and ends the driver's trips).
final Provider<void> trackerGuardProvider = Provider<void>((Ref ref) {
  String? driver;
  ref.listen<SessionState>(sessionProvider, (SessionState? previous, SessionState next) {
    final bool allowed = next is SessionSignedIn && next.account?.status == AccountStatus.verified;
    final String? uid = next is SessionSignedIn ? next.uid : null;
    final bool changedParent = driver != null && uid != driver;
    driver = uid ?? driver;
    if (!allowed || changedParent) {
      final LocationTracker tracker = ref.read(locationTrackerProvider);
      unawaited(
        tracker.activeTrip().then((String? trip) async {
          if (trip != null) {
            await tracker.stop();
          }
        }, onError: (Object _) {}),
      );
      driver = uid;
    }
  }, fireImmediately: true);
});
