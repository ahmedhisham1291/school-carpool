import 'package:firebase_messaging/firebase_messaging.dart' as fcm;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';

/// What a push carries (data keys from the server; IDs and flags only).
@immutable
class PushData {
  const PushData({
    required this.notificationId,
    required this.route,
    this.critical = false,
    this.alarm = false,
    this.alarmAt,
    this.title,
    this.body,
  });

  /// Reads a push's data map. Anything odd falls back to safe values.
  factory PushData.fromMap(Map<String, dynamic> data, {String? title, String? body}) {
    final Object? at = data['alarmAt'];
    final int? ms = at is String ? int.tryParse(at) : null;
    final Object? id = data['notificationId'];
    return PushData(
      notificationId: id is String ? id : '',
      route: NotificationRoutes.safe(data['route']),
      critical: data['critical'] == '1',
      alarm: data['alarm'] == '1',
      alarmAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      title: title,
      body: body,
    );
  }

  final String notificationId;
  final String route;
  final bool critical;

  /// The second, louder push of an unopened critical alert.
  final bool alarm;
  final DateTime? alarmAt;

  /// Text the server wrote (generic, no names), for the background alarm.
  final String? title;
  final String? body;
}

/// Firebase Cloud Messaging behind one interface, so widget tests use a
/// fake (CLAUDE.md fakes). APNs on the iPhone (SETUP.md section 18).
abstract interface class PushMessaging {
  /// Asks the phone for permission (iOS shows its prompt once). True when allowed.
  Future<bool> requestPermission();

  /// This phone's FCM token, or null (no permission, no APNs token yet, web).
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// Sign-out: this phone stops getting this parent's pushes.
  Future<void> deleteToken();

  /// The push that opened the app from a closed state, if any.
  Future<PushData?> initialTap();

  /// Pushes the parent tapped while the app was in the background.
  Stream<PushData> get taps;

  /// Pushes that arrived while the app was open.
  Stream<PushData> get foreground;

  /// "ios", "android" or "web".
  String get platform;
}

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging(this._messaging);

  final fcm.FirebaseMessaging _messaging;

  static PushData _data(fcm.RemoteMessage m) =>
      PushData.fromMap(m.data, title: m.notification?.title, body: m.notification?.body);

  @override
  String get platform => kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb) {
      // The website gets push in Stage 2 (needs a VAPID key).
      return false;
    }
    final fcm.NotificationSettings settings = await _messaging.requestPermission();
    // Banners in the foreground come from the in-app banner and list; the
    // system shows the push too, so nothing is missed while the app is open.
    await _messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
    return settings.authorizationStatus == fcm.AuthorizationStatus.authorized ||
        settings.authorizationStatus == fcm.AuthorizationStatus.provisional;
  }

  @override
  Future<String?> token() async {
    if (kIsWeb) {
      return null;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS && await _messaging.getAPNSToken() == null) {
      // APNs has not answered yet; the next start (or tokenRefresh) registers.
      return null;
    }
    // firebase_messaging 17 deprecates the registration-token API in favour
    // of Firebase Installation ID registration (register()/onRegistered).
    // FCM still fully supports tokens, and our server sends to tokens
    // (FCM HTTP v1 `token`). Moving to FIDs changes the server's send target
    // too (`fid`), so it is one planned change, not done blind here:
    // docs/progress/prompt-08.md, "Not done".
    // ignore: deprecated_member_use
    return _messaging.getToken();
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefresh => kIsWeb ? const Stream<String>.empty() : _messaging.onTokenRefresh;

  @override
  // ignore: deprecated_member_use
  Future<void> deleteToken() => kIsWeb ? Future<void>.value() : _messaging.deleteToken();

  @override
  Future<PushData?> initialTap() async {
    if (kIsWeb) {
      return null;
    }
    final fcm.RemoteMessage? m = await _messaging.getInitialMessage();
    return m == null ? null : _data(m);
  }

  @override
  Stream<PushData> get taps => kIsWeb ? const Stream<PushData>.empty() : fcm.FirebaseMessaging.onMessageOpenedApp.map(_data);

  @override
  Stream<PushData> get foreground => kIsWeb ? const Stream<PushData>.empty() : fcm.FirebaseMessaging.onMessage.map(_data);
}

final Provider<PushMessaging> pushMessagingProvider = Provider<PushMessaging>(
  (Ref ref) => FirebasePushMessaging(fcm.FirebaseMessaging.instance),
);

/// Registers the background handler (once, after Firebase starts, before
/// runApp). Not on the web.
void registerPushBackgroundHandler() {
  if (!kIsWeb) {
    fcm.FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
  }
}

/// Runs in a background isolate when a push arrives while the app is not
/// open (iOS: critical pushes are sent with content-available). A critical
/// alert schedules the app's own alarm at its alarm time, so it sounds even
/// on a phone that stops background apps before the server's second push.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(fcm.RemoteMessage message) async {
  final PushData data = PushData.fromMap(message.data, title: message.notification?.title, body: message.notification?.body);
  final DateTime? at = data.alarmAt;
  if (!data.critical || data.alarm || at == null || data.notificationId.isEmpty) {
    return;
  }
  final LocalAlarms alarms = PluginLocalAlarms();
  await alarms.init(onTap: (_) {});
  await alarms.schedule(
    id: alarmIdFor(data.notificationId),
    at: at,
    title: data.title ?? '',
    body: data.body ?? '',
    payload: alarmPayload(data.notificationId, data.route),
  );
}
