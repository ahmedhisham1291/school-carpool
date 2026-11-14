import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_labels.dart';
import 'package:school_carpool/features/notifications/notification_logic.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/features/notifications/push_messaging.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Runs notifications on the phone (Prompt 8), from app start to close:
/// - after sign-in: asks for permission once and registers this phone's
///   token (again after every token refresh, replacing the old one);
/// - a tapped push or alarm: marks it read and opens its screen;
/// - critical alerts: keeps the app's own alarms in step with the list
///   (scheduled at the alarm time, rung once when the time passed with the
///   app open, cancelled when opened; spec section 11);
/// - sign-out: [unregister] removes the token first.
///
/// Every step is best effort: a failure never blocks the app.
class NotificationCenter {
  NotificationCenter(this._ref);

  final Ref _ref;
  final Set<String> _rung = <String>{};
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];
  String? _registeredUid;
  bool _syncing = false;

  GoRouter? _router;
  String? _pendingRoute;

  /// The router of the tab shell (set by HomeShell). A push tapped before
  /// the shell exists (cold start) opens its screen when it attaches.
  GoRouter? get router => _router;

  set router(GoRouter? value) {
    if (value == null) {
      _router = null;
      return;
    }
    if (identical(_router, value)) {
      return;
    }
    _router = value;
    final String? pending = _pendingRoute;
    _pendingRoute = null;
    if (pending != null) {
      scheduleMicrotask(() => value.go(pending));
    }
  }
  List<AppNotification>? _again;

  static const String tokenKey = 'push.token';

  PushMessaging get _push => _ref.read(pushMessagingProvider);
  LocalAlarms get _alarms => _ref.read(localAlarmsProvider);
  NotificationRepository get _repository => _ref.read(notificationRepositoryProvider);
  SettingsStore get _store => _ref.read(settingsStoreProvider);

  void start() {
    unawaited(_guard(() => _alarms.init(onTap: _onAlarmTap)));
    _subscriptions
      ..add(_push.taps.listen(open))
      ..add(_push.tokenRefresh.listen((String token) => unawaited(_guard(() => _register(token)))));
    unawaited(_guard(() async {
      final PushData? first = await _push.initialTap();
      if (first != null) {
        open(first);
      }
    }));
    _ref
      ..listen<SessionState>(sessionProvider, (SessionState? previous, SessionState next) => _onSession(next), fireImmediately: true)
      ..listen<AsyncValue<List<AppNotification>>>(notificationsProvider, (AsyncValue<List<AppNotification>>? previous, AsyncValue<List<AppNotification>> next) {
        final List<AppNotification>? list = next.value;
        if (list != null) {
          unawaited(_sync(list));
        }
      }, fireImmediately: true);
  }

  void dispose() {
    for (final StreamSubscription<Object?> s in _subscriptions) {
      unawaited(s.cancel());
    }
  }

  static Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on Object {
      // Push and alarms are best effort (no permission, offline, web).
    }
  }

  String? get _uid {
    final SessionState session = _ref.read(sessionProvider);
    return session is SessionSignedIn ? session.uid : null;
  }

  void _onSession(SessionState session) {
    if (session is! SessionSignedIn) {
      if (session is SessionSignedOut) {
        _registeredUid = null;
      }
      return;
    }
    if (_registeredUid == session.uid) {
      return;
    }
    _registeredUid = session.uid;
    unawaited(_guard(() async {
      if (!await _push.requestPermission()) {
        return;
      }
      final String? token = await _push.token();
      if (token != null) {
        await _register(token);
      }
    }));
  }

  Future<void> _register(String token) async {
    if (_uid == null) {
      return;
    }
    final String? previous = _store.read(tokenKey);
    await _repository.registerDevice(
      token: token,
      platform: _push.platform,
      previousToken: previous != null && previous != token ? previous : null,
    );
    await _store.write(tokenKey, token);
  }

  /// Before signing out: this phone stops getting this parent's pushes and
  /// alarms. Waits at most a few seconds; signing out never fails because
  /// of it.
  Future<void> unregister() async {
    final String? token = _store.read(tokenKey);
    if (token != null) {
      await _guard(() => _repository.unregisterDevice(token).timeout(const Duration(seconds: 5)));
    }
    await _guard(() => _push.deleteToken().timeout(const Duration(seconds: 5)));
    await _guard(() async {
      for (final int id in await _alarms.pending()) {
        await _alarms.cancel(id);
      }
    });
    await _store.write(tokenKey, null);
    _registeredUid = null;
    _rung.clear();
  }

  /// Opens a tapped push: marks it read, stops its alarm, opens its screen.
  void open(PushData data) => openNotification(data.notificationId, data.route);

  void openNotification(String id, String route) {
    final String? uid = _uid;
    if (uid != null && id.isNotEmpty) {
      unawaited(_guard(() => _repository.markRead(uid, id)));
      unawaited(_guard(() => _alarms.cancel(alarmIdFor(id))));
    }
    final String target = NotificationRoutes.safe(route);
    final GoRouter? shell = _router;
    if (shell == null) {
      _pendingRoute = target;
    } else {
      shell.go(target);
    }
  }

  void _onAlarmTap(String payload) {
    final (String, String)? parsed = parseAlarmPayload(payload);
    if (parsed != null) {
      openNotification(parsed.$1, parsed.$2);
    }
  }

  Future<void> _sync(List<AppNotification> list) async {
    if (_syncing) {
      _again = list;
      return;
    }
    _syncing = true;
    try {
      final AlarmPlan plan = planAlarms(
        list,
        now: _ref.read(notificationClockProvider)().toUtc(),
        pending: await _alarms.pending(),
        rung: _rung,
      );
      if (plan.isEmpty) {
        return;
      }
      final AppLocalizations l10n = lookupAppLocalizations(_ref.read(localeProvider));
      for (final int id in plan.cancel) {
        await _alarms.cancel(id);
      }
      for (final AppNotification n in plan.schedule) {
        await _alarms.schedule(
          id: alarmIdFor(n.id),
          at: n.alarmAt!,
          title: notificationTitle(l10n, n.kind),
          body: notificationBody(l10n, n),
          payload: alarmPayload(n.id, n.route),
        );
      }
      for (final AppNotification n in plan.ringNow) {
        _rung.add(n.id);
        await _alarms.ringNow(
          id: alarmIdFor(n.id),
          title: notificationTitle(l10n, n.kind),
          body: notificationBody(l10n, n),
          payload: alarmPayload(n.id, n.route),
        );
      }
    } on Object {
      // Best effort.
    } finally {
      _syncing = false;
      final List<AppNotification>? next = _again;
      _again = null;
      if (next != null) {
        unawaited(_sync(next));
      }
    }
  }
}

/// "Now" for notifications (tests fix it).
final Provider<DateTime Function()> notificationClockProvider = Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// Started by the app root (CarpoolApp watches it).
final Provider<NotificationCenter> notificationCenterProvider = Provider<NotificationCenter>((Ref ref) {
  final NotificationCenter center = NotificationCenter(ref)..start();
  ref.onDispose(center.dispose);
  return center;
});

/// Opens a notification from the list or the banner (marks read, stops the
/// alarm, navigates) without going through the router's root.
void openFromApp(WidgetRef ref, BuildContext context, AppNotification n) {
  final SessionState session = ref.read(sessionProvider);
  if (session is SessionSignedIn && n.unread) {
    unawaited(NotificationCenter._guard(() => ref.read(notificationRepositoryProvider).markRead(session.uid, n.id)));
    unawaited(NotificationCenter._guard(() => ref.read(localAlarmsProvider).cancel(alarmIdFor(n.id))));
  }
  context.go(n.route);
}
