import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/settings/settings_store.dart';
import 'package:timezone/timezone.dart' as tz;

/// The app's own alarm for critical alerts (spec section 11: "sound an
/// in-app alarm when neither message is opened in time"). A local
/// notification with sound at the record's alarm time, cancelled as soon as
/// the parent opens the alert. On the iPhone it is "time sensitive", so it
/// breaks through Focus (Time Sensitive Notifications capability,
/// SETUP.md section 18.3).
///
/// Behind one interface so widget tests use a fake.
abstract interface class LocalAlarms {
  /// [onTap] gets the payload of a tapped alarm.
  Future<void> init({required void Function(String payload) onTap});

  /// Schedules (or replaces) alarm [id] at [at]; at once when [at] has passed.
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload});

  /// Sounds now (the alarm time passed while the app was open).
  Future<void> ringNow({required int id, required String title, required String body, required String payload});
  Future<void> cancel(int id);

  /// IDs of alarms still waiting.
  Future<Set<int>> pending();
}

/// A stable 31-bit ID for a notification (FNV-1a), so the background
/// isolate and the app schedule and cancel the same alarm.
int alarmIdFor(String notificationId) {
  int hash = 0x811c9dc5;
  for (final int unit in notificationId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

/// IDs of critical alerts whose alarm this phone already rang or scheduled
/// (newest last, at most [kRungAlarmsKept]), so an old unread alert never
/// rings again when the app opens. IDs only; no personal data.
const String kRungAlarmsKey = 'alarms.rung';
const int kRungAlarmsKept = 50;

Set<String> rungAlarmIds(SettingsStore store) {
  final String? raw = store.read(kRungAlarmsKey);
  return raw == null || raw.isEmpty ? <String>{} : raw.split(',').toSet();
}

Future<void> rememberAlarm(SettingsStore store, String notificationId) async {
  final List<String> ids = <String>[...rungAlarmIds(store).where((String x) => x != notificationId), notificationId];
  final int drop = ids.length > kRungAlarmsKept ? ids.length - kRungAlarmsKept : 0;
  await store.write(kRungAlarmsKey, ids.skip(drop).join(','));
}

/// "notificationId|route": what a tapped alarm opens.
String alarmPayload(String notificationId, String route) => '$notificationId|$route';

/// Splits [alarmPayload]. Null when malformed.
(String, String)? parseAlarmPayload(String? payload) {
  if (payload == null) {
    return null;
  }
  final int bar = payload.indexOf('|');
  if (bar <= 0) {
    return null;
  }
  return (payload.substring(0, bar), payload.substring(bar + 1));
}

class PluginLocalAlarms implements LocalAlarms {
  PluginLocalAlarms([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const NotificationDetails _details = NotificationDetails(
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
      threadIdentifier: 'critical',
    ),
    android: AndroidNotificationDetails(
      'critical',
      'Critical alerts',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
    ),
  );

  @override
  Future<void> init({required void Function(String payload) onTap}) async {
    if (kIsWeb) {
      return;
    }
    await _plugin.initialize(
      const InitializationSettings(
        // Permission is asked once, by FirebaseMessaging.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? payload = response.payload;
        if (payload != null) {
          onTap(payload);
        }
      },
    );
    final NotificationAppLaunchDetails? launch = await _plugin.getNotificationAppLaunchDetails();
    final String? payload = launch?.notificationResponse?.payload;
    if ((launch?.didNotificationLaunchApp ?? false) && payload != null) {
      onTap(payload);
    }
  }

  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {
    if (kIsWeb) {
      return;
    }
    if (!at.isAfter(DateTime.now())) {
      await ringNow(id: id, title: title, body: body, payload: payload);
      return;
    }
    // UTC needs no time zone database.
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(at.toUtc(), tz.UTC),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  @override
  Future<void> ringNow({required int id, required String title, required String body, required String payload}) async {
    if (kIsWeb) {
      return;
    }
    await _plugin.show(id, title, body, _details, payload: payload);
  }

  @override
  Future<void> cancel(int id) async {
    if (kIsWeb) {
      return;
    }
    await _plugin.cancel(id);
  }

  @override
  Future<Set<int>> pending() async {
    if (kIsWeb) {
      return <int>{};
    }
    final List<PendingNotificationRequest> list = await _plugin.pendingNotificationRequests();
    return <int>{for (final PendingNotificationRequest p in list) p.id};
  }
}

final Provider<LocalAlarms> localAlarmsProvider = Provider<LocalAlarms>((Ref ref) => PluginLocalAlarms());
