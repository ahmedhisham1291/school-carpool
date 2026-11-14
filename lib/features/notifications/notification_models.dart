import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Notification types (Prompt 8). Same names as the server's catalog
/// (functions/src/notifications/catalog.ts), in camel case.
enum NotificationKind {
  planReady('plan-ready', WhatsAppGroup.schedule),
  noDriver('no-driver', WhatsAppGroup.noDriver, critical: true),
  swapRequested('swap-requested', WhatsAppGroup.swaps),
  swapAccepted('swap-accepted', WhatsAppGroup.swaps),
  swapCancelled('swap-cancelled', WhatsAppGroup.swaps),
  runTaken('run-taken', WhatsAppGroup.swaps),
  childAbsent('child-absent', WhatsAppGroup.absences),
  childBack('child-back', WhatsAppGroup.absences),
  driverUnavailable('driver-unavailable', WhatsAppGroup.swaps),
  scheduleChanged('schedule-changed', WhatsAppGroup.schedule),
  timeChanged('time-changed', WhatsAppGroup.schedule),
  driveEvening('drive-evening', WhatsAppGroup.reminders),
  driveHour('drive-hour', WhatsAppGroup.reminders),
  confirmReminder('confirm-reminder', WhatsAppGroup.reminders),
  joinRequested('join-requested', WhatsAppGroup.joins),
  joinApproved('join-approved', WhatsAppGroup.joins),
  joinDeclined('join-declined', WhatsAppGroup.joins),
  verificationApproved('verification-approved', WhatsAppGroup.verification),
  verificationRejected('verification-rejected', WhatsAppGroup.verification),
  newParent('new-parent', WhatsAppGroup.newParents),
  childNotConfirmed('child-not-confirmed', WhatsAppGroup.childNotConfirmed, critical: true),
  // Prompt 10: trips.
  tripStarted('trip-started', WhatsAppGroup.trips),
  driverArrived('driver-arrived', WhatsAppGroup.tripAlerts),
  childPickedUp('child-picked-up', WhatsAppGroup.trips),
  childDropped('child-dropped', WhatsAppGroup.trips),
  childReceived('child-received', WhatsAppGroup.trips),
  locationStopped('location-stopped', WhatsAppGroup.tripAlerts),
  driverLate('driver-late', WhatsAppGroup.trips),
  driverAtGate('driver-at-gate', WhatsAppGroup.trips),
  allChildrenIn('all-children-in', WhatsAppGroup.trips),
  emergency('emergency', WhatsAppGroup.emergency, critical: true),
  chatMessage('chat-message', null);

  const NotificationKind(this.wire, this.group, {this.critical = false});

  /// The type as stored by the server.
  final String wire;

  /// What the parent switches WhatsApp on or off for; null: push only (chat).
  final WhatsAppGroup? group;

  /// Critical alerts sound the alarm when not opened in time (spec section 11).
  final bool critical;

  static NotificationKind? fromWire(Object? value) {
    for (final NotificationKind k in values) {
      if (k.wire == value) {
        return k;
      }
    }
    return null;
  }
}

/// WhatsApp on or off per group (Settings). Critical groups first.
enum WhatsAppGroup {
  noDriver(defaultOn: true),
  childNotConfirmed(defaultOn: true),
  // Prompt 10: the emergency button and Arrived / location stopped.
  emergency(defaultOn: true),
  tripAlerts(defaultOn: true),
  trips,
  reminders,
  swaps,
  absences,
  schedule,
  joins,
  verification,
  newParents;

  const WhatsAppGroup({this.defaultOn = false});

  /// COST MODE: only the critical alerts go to WhatsApp unless switched on.
  final bool defaultOn;
}

/// The screens a notification may open. Anything else opens the
/// Notifications tab: a route from the server is checked before use.
abstract final class NotificationRoutes {
  static const String fallback = '/notifications';
  static final RegExp _allowed = RegExp(
    r'^/(notifications|profile|chats|home/nearby|carpools/[A-Za-z0-9_-]{1,128}(/schedule|/emergency|/trip/\d{4}-\d{2}-\d{2}_(am|pm))?)$',
  );

  static String safe(Object? route) => route is String && _allowed.hasMatch(route) ? route : fallback;
}

/// One in-app notification (users/{uid}/notifications/{id}). IDs, a date
/// and a route only: the text comes from the app's own strings.
@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.route,
    this.carpoolId,
    this.date,
    this.toSchool,
    this.readAt,
    this.alarmAt,
    this.criticalEvent = false,
  });

  factory AppNotification.fromDoc(String id, NotificationKind kind, Map<String, dynamic> d) {
    final Object? direction = d['direction'];
    return AppNotification(
      id: id,
      kind: kind,
      createdAt: _time(d['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      route: NotificationRoutes.safe(d['route']),
      carpoolId: d['carpoolId'] is String ? d['carpoolId'] as String : null,
      date: _date(d['date']),
      toSchool: direction == 'toSchool' ? true : (direction == 'toHome' ? false : null),
      readAt: _time(d['readAt']),
      alarmAt: _time(d['alarmAt']),
      criticalEvent: d['critical'] == true,
    );
  }

  final String id;
  final NotificationKind kind;

  /// UTC instants (Firestore timestamps).
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? alarmAt;
  final String route;
  final String? carpoolId;

  /// The run's Cairo date (a calendar day), when the type is about a run.
  final DateTime? date;

  /// true: to school, false: home, null: not about one run.
  final bool? toSchool;

  /// The server made this one critical (a run moved with no time left to confirm).
  final bool criticalEvent;

  bool get unread => readAt == null;
  bool get critical => kind.critical || criticalEvent;

  AppNotification markedRead(DateTime at) => AppNotification(
    id: id,
    kind: kind,
    createdAt: createdAt,
    route: route,
    carpoolId: carpoolId,
    date: date,
    toSchool: toSchool,
    readAt: at,
    alarmAt: alarmAt,
    criticalEvent: criticalEvent,
  );

  static DateTime? _time(Object? v) => v is Timestamp ? v.toDate().toUtc() : null;

  static DateTime? _date(Object? v) {
    if (v is! String) {
      return null;
    }
    final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
}

/// WhatsApp per group and quiet hours (notificationSettings/{uid}).
@immutable
class NotificationSettings {
  const NotificationSettings({
    this.whatsapp = const <WhatsAppGroup, bool>{},
    this.quietHours = true,
    this.quietFrom = '22:00',
    this.quietTo = '06:00',
  });

  factory NotificationSettings.fromDoc(Map<String, dynamic>? d) {
    final Map<WhatsAppGroup, bool> wa = <WhatsAppGroup, bool>{};
    final Object? raw = d?['whatsapp'];
    if (raw is Map) {
      for (final WhatsAppGroup g in WhatsAppGroup.values) {
        final Object? v = raw[g.name];
        if (v is bool) {
          wa[g] = v;
        }
      }
    }
    final Object? q = d?['quiet'];
    final Map<Object?, Object?> quiet = q is Map ? q : const <Object?, Object?>{};
    final Object? on = quiet['on'];
    final Object? from = quiet['from'];
    final Object? to = quiet['to'];
    return NotificationSettings(
      whatsapp: wa,
      quietHours: on is bool ? on : true,
      quietFrom: from is String ? from : '22:00',
      quietTo: to is String ? to : '06:00',
    );
  }

  /// Only the groups the parent changed; the rest follow [WhatsAppGroup.defaultOn].
  final Map<WhatsAppGroup, bool> whatsapp;
  final bool quietHours;
  final String quietFrom;
  final String quietTo;

  bool whatsappOn(WhatsAppGroup g) => whatsapp[g] ?? g.defaultOn;

  NotificationSettings withWhatsApp(WhatsAppGroup g, bool on) => NotificationSettings(
    whatsapp: <WhatsAppGroup, bool>{...whatsapp, g: on},
    quietHours: quietHours,
    quietFrom: quietFrom,
    quietTo: quietTo,
  );

  NotificationSettings withQuietHours(bool on) =>
      NotificationSettings(whatsapp: whatsapp, quietHours: on, quietFrom: quietFrom, quietTo: quietTo);
}

enum NotificationFailureKind { offline, rateLimited, unknown }

class NotificationFailure implements Exception {
  const NotificationFailure(this.kind);

  factory NotificationFailure.from(Object error) {
    if (error is NotificationFailure) {
      return error;
    }
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'resource-exhausted' => const NotificationFailure(NotificationFailureKind.rateLimited),
        'unavailable' || 'deadline-exceeded' => const NotificationFailure(NotificationFailureKind.offline),
        _ => const NotificationFailure(NotificationFailureKind.unknown),
      };
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const NotificationFailure(NotificationFailureKind.offline);
    }
    return const NotificationFailure(NotificationFailureKind.unknown);
  }

  final NotificationFailureKind kind;

  bool get isOffline => kind == NotificationFailureKind.offline;

  String message(AppLocalizations l10n) => switch (kind) {
    NotificationFailureKind.offline => l10n.errorOfflineShort,
    NotificationFailureKind.rateLimited => l10n.notifErrorTooMany,
    NotificationFailureKind.unknown => l10n.notifErrorSave,
  };
}
