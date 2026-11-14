import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/features/notifications/push_messaging.dart';

/// Monday 16 Nov 2026, 10:00 UTC: the fixed "now" of notification tests.
final DateTime notifNow = DateTime.utc(2026, 11, 16, 10);

/// A notification for tests (fake data only).
AppNotification testNotification(
  String id,
  NotificationKind kind, {
  bool read = false,
  Duration ago = const Duration(minutes: 5),
  DateTime? alarmAt,
  String route = '/carpools/k1/schedule',
}) => AppNotification(
  id: id,
  kind: kind,
  createdAt: notifNow.subtract(ago),
  route: route,
  carpoolId: 'k1',
  date: DateTime(2026, 11, 17),
  toSchool: true,
  readAt: read ? notifNow : null,
  alarmAt: alarmAt ?? (kind.critical ? notifNow.subtract(ago).add(const Duration(minutes: 15)) : null),
);

/// Records calls; [failure] makes writes fail; [streamError] fails the lists.
class FakeNotificationRepository implements NotificationRepository {
  FakeNotificationRepository({List<AppNotification>? items, NotificationSettings? settings})
    : items = items ?? <AppNotification>[],
      settings = settings ?? const NotificationSettings();

  List<AppNotification> items;
  NotificationSettings settings;
  NotificationFailure? failure;
  Object? streamError;
  final List<String> calls = <String>[];
  final StreamController<int> _changes = StreamController<int>.broadcast();

  void emit() => _changes.add(0);

  Stream<T> _watch<T>(T Function() read) async* {
    final Object? error = streamError;
    if (error != null) {
      throw error;
    }
    yield read();
    await for (final int _ in _changes.stream) {
      yield read();
    }
  }

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final NotificationFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Stream<List<AppNotification>> watch(String uid) => _watch(() => List<AppNotification>.of(items));

  @override
  Future<void> markRead(String uid, String id) async {
    calls.add('markRead:$id');
    items = <AppNotification>[for (final AppNotification n in items) n.id == id && n.unread ? n.markedRead(notifNow) : n];
    emit();
  }

  @override
  Future<void> markAllRead(String uid, List<String> ids) async {
    await _maybeFail('markAllRead:${ids.length}');
    items = <AppNotification>[for (final AppNotification n in items) ids.contains(n.id) ? n.markedRead(notifNow) : n];
    emit();
  }

  @override
  Stream<NotificationSettings> watchSettings(String uid) => _watch(() => settings);

  @override
  Future<void> setWhatsApp(WhatsAppGroup group, {required bool on}) async {
    await _maybeFail('setWhatsApp:${group.name}:$on');
    settings = settings.withWhatsApp(group, on);
    emit();
  }

  @override
  Future<void> setQuietHours({required bool on}) async {
    await _maybeFail('setQuietHours:$on');
    settings = settings.withQuietHours(on);
    emit();
  }

  @override
  Future<void> registerDevice({required String token, required String platform, String? previousToken}) async {
    calls.add('register:$token:$platform:${previousToken ?? '-'}');
  }

  @override
  Future<void> unregisterDevice(String token) async {
    calls.add('unregister:$token');
  }
}

class FakePushMessaging implements PushMessaging {
  bool allowed = true;
  String? currentToken = 'fake-token-1';
  PushData? launchTap;
  bool deleted = false;
  final StreamController<PushData> tapController = StreamController<PushData>.broadcast();
  final StreamController<String> refreshController = StreamController<String>.broadcast();

  @override
  String get platform => 'ios';

  @override
  Future<bool> requestPermission() async => allowed;

  @override
  Future<String?> token() async => currentToken;

  @override
  Stream<String> get tokenRefresh => refreshController.stream;

  @override
  Future<void> deleteToken() async {
    deleted = true;
  }

  @override
  Future<PushData?> initialTap() async => launchTap;

  @override
  Stream<PushData> get taps => tapController.stream;

  @override
  Stream<PushData> get foreground => const Stream<PushData>.empty();
}

class FakeLocalAlarms implements LocalAlarms {
  final Map<int, DateTime> scheduled = <int, DateTime>{};
  final List<int> rang = <int>[];
  final List<int> cancelled = <int>[];

  @override
  Future<void> init({required void Function(String payload) onTap}) async {}

  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String payload}) async {
    scheduled[id] = at;
  }

  @override
  Future<void> ringNow({required int id, required String title, required String body, required String payload}) async {
    rang.add(id);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> pending() async => scheduled.keys.toSet();
}

/// Overrides that keep Firebase and the plugins out of widget tests. The
/// number of overrides is the same for every call.
List<Override> notificationOverrides({
  NotificationRepository? notifications,
  PushMessaging? push,
  LocalAlarms? alarms,
}) => <Override>[
  notificationRepositoryProvider.overrideWithValue(notifications ?? FakeNotificationRepository()),
  pushMessagingProvider.overrideWithValue(push ?? FakePushMessaging()),
  localAlarmsProvider.overrideWithValue(alarms ?? FakeLocalAlarms()),
  notificationClockProvider.overrideWithValue(() => notifNow),
];
