import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';

/// What the app does with its own alarms for one list of notifications.
@immutable
class AlarmPlan {
  const AlarmPlan({this.schedule = const <AppNotification>[], this.ringNow = const <AppNotification>[], this.cancel = const <int>{}});

  /// Unread critical alerts whose alarm time is still ahead.
  final List<AppNotification> schedule;

  /// Unread critical alerts whose alarm time passed and that have not rung
  /// in this run of the app.
  final List<AppNotification> ringNow;

  /// Alarms of alerts that were opened (or are gone).
  final Set<int> cancel;

  bool get isEmpty => schedule.isEmpty && ringNow.isEmpty && cancel.isEmpty;
}

/// An alarm whose time passed longer ago than this does not ring when the
/// app opens: the run it was about is over (the banner still shows it).
const Duration kAlarmRingWindow = Duration(hours: 2);

/// Plans the app's alarms (spec section 11) from the notifications list:
/// every unread critical alert has an alarm at its alarm time; when that
/// time has passed it rings once ever ([rung] is kept on the phone), and
/// only within [kAlarmRingWindow] of the alarm time; an opened alert's
/// alarm is cancelled. [pending] are the alarms the phone still holds.
AlarmPlan planAlarms(List<AppNotification> notifications, {required DateTime now, required Set<int> pending, required Set<String> rung}) {
  final List<AppNotification> schedule = <AppNotification>[];
  final List<AppNotification> ring = <AppNotification>[];
  final Set<int> wanted = <int>{};
  for (final AppNotification n in notifications) {
    final DateTime? at = n.alarmAt;
    if (!n.critical || !n.unread || at == null) {
      continue;
    }
    final int id = alarmIdFor(n.id);
    wanted.add(id);
    if (at.isAfter(now)) {
      if (!pending.contains(id)) {
        schedule.add(n);
      }
    } else if (!rung.contains(n.id) && now.difference(at) <= kAlarmRingWindow) {
      ring.add(n);
    }
  }
  final Set<int> cancel = <int>{
    for (final AppNotification n in notifications)
      if (n.critical && !n.unread) alarmIdFor(n.id),
    ...pending.difference(wanted),
  }..removeAll(wanted);
  return AlarmPlan(schedule: schedule, ringNow: ring, cancel: cancel);
}

/// Splits the list for the Notifications tab: unread first ("New"), then
/// the rest ("Earlier"), each newest first.
(List<AppNotification>, List<AppNotification>) splitByRead(List<AppNotification> all) {
  final List<AppNotification> sorted = <AppNotification>[...all]
    ..sort((AppNotification a, AppNotification b) => b.createdAt.compareTo(a.createdAt));
  return (
    <AppNotification>[for (final AppNotification n in sorted) if (n.unread) n],
    <AppNotification>[for (final AppNotification n in sorted) if (!n.unread) n],
  );
}
