// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart' as fcm;
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart' show TargetPlatform;
import 'package:school_carpool/features/trips/geolocator_tracker.dart';
import 'package:school_carpool/features/trips/location_gate.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// A fake geolocator platform: every answer is set by the test.
class FakeGeoSource implements GeoSource {
  bool service = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission afterRequest = LocationPermission.whileInUse;
  LocationAccuracyStatus accuracyStatus = LocationAccuracyStatus.precise;
  int requests = 0;
  int appSettings = 0;
  int locationSettings = 0;
  LocationSettings? lastSettings;
  GeoFix? currentFix;
  final StreamController<GeoFix> fixes = StreamController<GeoFix>.broadcast();
  final StreamController<ServiceStatus> services = StreamController<ServiceStatus>.broadcast();

  @override
  Future<bool> serviceEnabled() async => service;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    permission = afterRequest;
    return permission;
  }

  @override
  Future<LocationAccuracyStatus> accuracy() async => accuracyStatus;

  @override
  Stream<GeoFix> positions(LocationSettings settings) {
    lastSettings = settings;
    return fixes.stream;
  }

  @override
  Future<GeoFix> current(LocationSettings settings) async {
    final GeoFix? f = currentFix;
    if (f == null) {
      throw TimeoutException('no fix');
    }
    return f;
  }

  @override
  Stream<ServiceStatus> serviceStatus() => services.stream;

  @override
  Future<bool> openAppSettings() async {
    appSettings++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettings++;
    return true;
  }

  Future<void> dispose() async {
    await fixes.close();
    await services.close();
  }
}

/// Records the batches the server kept (200).
class FakePoster implements PointPoster {
  final List<(String, String, Map<String, Object?>)> posts = <(String, String, Map<String, Object?>)>[];
  int status = 200;
  bool offline = false;

  @override
  Future<int> post(String url, String token, String body) async {
    if (offline) {
      throw const PointPostOffline();
    }
    if (status == 200) {
      posts.add((url, token, jsonDecode(body) as Map<String, Object?>));
    }
    return status;
  }

  int get points => posts.fold<int>(0, (int n, (String, String, Map<String, Object?>) p) => n + (p.$3['location']! as List<Object?>).length);
}

class FakeNotifications implements NotificationStatus {
  NotificationAccess access = NotificationAccess.allowed;
  int requests = 0;

  @override
  Future<NotificationAccess> status() async => access;

  @override
  Future<void> request() async {
    requests++;
    access = NotificationAccess.allowed;
  }
}

final DateTime _t0 = DateTime.utc(2026, 11, 16, 6, 30);

GeoFix _fix(int seconds, {double speed = 8}) =>
    GeoFix(lat: 30.04, lng: 31.24, at: _t0.add(Duration(seconds: seconds)), accuracy: 5, speed: speed, heading: 90);

const TrackerSession _session = TrackerSession(tripId: 'k1_2026-11-16_am', uploadUrl: 'https://fn.test/tripLocation?trip=k1', token: 'token-abcdefghijklmnopqrstuvwxyz');

void main() {
  late FakeGeoSource source;
  late FakePoster poster;
  late InMemorySettingsStore store;
  late DateTime now;

  GeolocatorTracker tracker() {
    final GeolocatorTracker t = GeolocatorTracker(
      store: store,
      source: source,
      poster: poster,
      now: () => now,
      platform: TargetPlatform.iOS,
      timers: false,
    );
    addTearDown(t.dispose);
    return t;
  }

  setUp(() {
    source = FakeGeoSource();
    poster = FakePoster();
    store = InMemorySettingsStore();
    now = _t0;
    addTearDown(source.dispose);
  });

  group('settings (owner decision, DECISIONS.md)', () {
    test('iPhone: best for navigation, automotive, 15 m, no auto pause, background with the blue indicator', () {
      final LocationSettings s = GeolocatorTracker.settingsFor(TargetPlatform.iOS);
      expect(s, isA<AppleSettings>());
      final AppleSettings a = s as AppleSettings;
      expect(a.accuracy, LocationAccuracy.bestForNavigation);
      expect(a.activityType, ActivityType.automotiveNavigation);
      expect(a.distanceFilter, 15);
      expect(a.pauseLocationUpdatesAutomatically, isFalse);
      expect(a.allowBackgroundLocationUpdates, isTrue);
      expect(a.showBackgroundLocationIndicator, isTrue);
    });

    test('the stream uses those settings', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      expect(source.lastSettings, isA<AppleSettings>());
    });
  });

  group('permission', () {
    test('While Using is enough; refused, not asked or service off: no run', () async {
      final GeolocatorTracker t = tracker();
      expect(await t.permission(), TrackerPermission.whileInUse);
      source.permission = LocationPermission.denied;
      expect(await t.permission(), TrackerPermission.notAsked);
      await expectLater(t.start(_session), throwsStateError);
      source.permission = LocationPermission.deniedForever;
      expect(await t.permission(), TrackerPermission.denied);
      source
        ..permission = LocationPermission.always
        ..service = false;
      expect(await t.permission(), TrackerPermission.serviceOff);
      await expectLater(t.start(_session), throwsStateError);
      expect(poster.posts, isEmpty);
    });
  });

  group('points', () {
    test('each fix is posted with the run token in the body the server parses', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      await t.flush();
      expect(poster.posts, hasLength(1));
      final (String url, String token, Map<String, Object?> body) = poster.posts.single;
      expect(url, _session.uploadUrl);
      expect(token, _session.token);
      final Map<String, Object?> point = (body['location']! as List<Object?>).single! as Map<String, Object?>;
      expect(point['timestamp'], '2026-11-16T06:30:00.000Z');
      expect((point['coords']! as Map<String, Object?>)['latitude'], 30.04);
      expect(t.pending, 0);
      expect(await t.activeTrip(), _session.tripId);
    });

    test('offline: points wait on the phone (also across a restart) and go in batches of 50 later', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      poster.offline = true;
      for (int i = 0; i < 120; i++) {
        source.fixes.add(_fix(i * 5));
      }
      await pumpEventQueue();
      await t.flush();
      expect(t.pending, 120);
      expect(store.read(GeolocatorTracker.storeKey), isNotNull);

      // The app is restarted: the buffer and the session come back.
      final GeolocatorTracker again = tracker();
      expect(again.pending, 120);
      expect(await again.activeTrip(), _session.tripId);
      poster.offline = false;
      await again.flush();
      expect(poster.posts.map(((String, String, Map<String, Object?>) p) => (p.$3['location']! as List<Object?>).length), <int>[50, 50, 20]);
      expect(again.pending, 0);
    });

    test('points older than a day are dropped at restart; the buffer is capped', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      poster.offline = true;
      for (int i = 0; i < GeolocatorTracker.maxBuffered + 10; i++) {
        source.fixes.add(_fix(i));
      }
      await pumpEventQueue();
      expect(t.pending, GeolocatorTracker.maxBuffered);
      now = _t0.add(const Duration(days: 2));
      expect(tracker().pending, 0);
    });

    test('410 (the run is over): tracking stops and nothing is kept', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      final List<TrackerStatus> seen = <TrackerStatus>[];
      final StreamSubscription<TrackerStatus> sub = t.status.listen(seen.add);
      addTearDown(sub.cancel);
      poster.status = 410;
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      await t.flush();
      expect(await t.activeTrip(), isNull);
      expect(t.pending, 0);
      expect(store.read(GeolocatorTracker.storeKey), isNull);
      expect(seen.last.tracking, isFalse);
      source.fixes.add(_fix(10));
      await pumpEventQueue();
      expect(t.pending, 0, reason: 'no points after the run');
    });

    test('server error: the batch stays for the next try', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      poster.status = 500;
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      await t.flush();
      expect(t.pending, 1);
      poster.status = 200;
      await t.flush();
      expect(t.pending, 0);
    });

    test('heartbeat: a car standing still sends one fix a minute', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      await t.flush();
      source.currentFix = _fix(65, speed: 0);
      now = _t0.add(const Duration(seconds: 20));
      await t.heartbeat();
      await t.flush();
      expect(poster.points, 1, reason: 'a fix came recently');
      now = _t0.add(const Duration(seconds: 65));
      await t.heartbeat();
      await t.flush();
      expect(poster.points, 2);
    });

    test('stop clears the session; keepUnsent sends what it can first', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      poster.status = 500;
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      poster.status = 200;
      await t.stop(keepUnsent: true);
      expect(poster.points, 1);
      expect(await t.activeTrip(), isNull);
      expect(store.read(GeolocatorTracker.storeKey), isNull);
    });

    test('Location Services switched off mid-run: the status says so', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      final List<TrackerStatus> seen = <TrackerStatus>[];
      final StreamSubscription<TrackerStatus> sub = t.status.listen(seen.add);
      addTearDown(sub.cancel);
      source.services.add(ServiceStatus.disabled);
      source.fixes.addError(const PermissionDeniedException('taken away'));
      await pumpEventQueue();
      expect(seen.map((TrackerStatus s) => s.permission), <TrackerPermission>[TrackerPermission.serviceOff, TrackerPermission.denied]);
    });
  });

  group('after a loss mid-run', () {
    test('start again (the driver fixed it) listens to positions again and keeps the buffer', () async {
      final GeolocatorTracker t = tracker();
      await t.start(_session);
      poster.offline = true;
      source.fixes.add(_fix(0));
      await pumpEventQueue();
      source.fixes.addError(const LocationServiceDisabledException());
      await pumpEventQueue();
      source.fixes.add(_fix(5));
      await pumpEventQueue();
      expect(t.pending, 1, reason: 'not listening after the error');
      await t.start(_session);
      source.fixes.add(_fix(10));
      await pumpEventQueue();
      expect(t.pending, 2);
      poster.offline = false;
      await t.flush();
      expect(poster.points, 2);
    });
  });

  group('driving gate check', () {
    late FakeNotifications notifications;
    setUp(() => notifications = FakeNotifications());

    test('all on: ready', () async {
      expect((await checkWith(source, notifications)).isReady, isTrue);
    });

    test('lists only what is missing, in order', () async {
      source
        ..service = false
        ..permission = LocationPermission.deniedForever;
      notifications.access = NotificationAccess.denied;
      final DrivingCheck c = await checkWith(source, notifications);
      expect(c.items(locationOnly: false), <GateItem>[GateItem.service, GateItem.permission, GateItem.notifications]);
      expect(c.items(locationOnly: true), <GateItem>[GateItem.service, GateItem.permission]);
      expect(c.anyNotAsked, isFalse);
    });

    test('approximate location counts as missing (Precise Location)', () async {
      source.accuracyStatus = LocationAccuracyStatus.reduced;
      final DrivingCheck c = await checkWith(source, notifications);
      expect(c.missing, <GateItem>{GateItem.precise});
      expect(c.locationReady, isFalse);
    });

    test('notifications only: location is ready (the home banner stays hidden)', () async {
      notifications.access = NotificationAccess.denied;
      final DrivingCheck c = await checkWith(source, notifications);
      expect(c.locationReady, isTrue);
      expect(c.isReady, isFalse);
    });

    test('never asked: asks in the app first (While Using), never Always', () async {
      source
        ..permission = LocationPermission.denied
        ..afterRequest = LocationPermission.whileInUse;
      notifications.access = NotificationAccess.notAsked;
      final DeviceDrivingReadiness readiness = DeviceDrivingReadiness(source: source, notifications: notifications);
      final DrivingCheck before = await readiness.check();
      expect(before.locationNotAsked, isTrue);
      expect(before.notificationsNotAsked, isTrue);
      final DrivingCheck after = await readiness.requestNotAsked();
      expect(source.requests, 1);
      expect(notifications.requests, 1);
      expect(after.isReady, isTrue);
    });

    test('refused before: no prompt again, Settings opens instead', () async {
      source.permission = LocationPermission.deniedForever;
      final DeviceDrivingReadiness readiness = DeviceDrivingReadiness(source: source, notifications: notifications);
      await readiness.requestNotAsked();
      expect(source.requests, 0);
      await readiness.openSettings(serviceOff: false);
      expect(source.appSettings, 1);
    });

    test('every notification status of firebase_messaging is mapped', () {
      expect(FcmNotificationStatus.fromFcm(fcm.AuthorizationStatus.authorized), NotificationAccess.allowed);
      expect(FcmNotificationStatus.fromFcm(fcm.AuthorizationStatus.provisional), NotificationAccess.allowed);
      expect(FcmNotificationStatus.fromFcm(fcm.AuthorizationStatus.notDetermined), NotificationAccess.notAsked);
      expect(FcmNotificationStatus.fromFcm(fcm.AuthorizationStatus.denied), NotificationAccess.denied);
      expect(FcmNotificationStatus.fromFcm(fcm.AuthorizationStatus.deniedPermanently), NotificationAccess.denied);
      for (final fcm.AuthorizationStatus s in fcm.AuthorizationStatus.values) {
        expect(FcmNotificationStatus.fromFcm(s), isA<NotificationAccess>(), reason: s.name);
      }
    });

    test('a check that fails counts as missing', () async {
      final DrivingCheck c = await checkWith(_ThrowingSource(), notifications);
      expect(c.missing, containsAll(<GateItem>[GateItem.service, GateItem.permission]));
    });
  });
}

class _ThrowingSource extends FakeGeoSource {
  @override
  Future<bool> serviceEnabled() => Future<bool>.error(StateError('x'));

  @override
  Future<LocationPermission> checkPermission() => Future<LocationPermission>.error(StateError('x'));
}
