// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:run_recovery/run_recovery.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/run_recovery.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/trip_fakes.dart';

final DateTime _start = DateTime.utc(2026, 11, 16, 5, 30);
final RunMarker _marker = RunMarker(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am', startedAt: _start);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the recovery rule', () {
    RecoveryDecision decide({RunMarker? marker, String? uid = 'uid-1', Duration after = const Duration(minutes: 20), bool? active}) =>
        decideRecovery(marker: marker, signedInUid: uid, now: _start.add(after), runActive: active);

    test('no marker: nothing to do', () {
      expect(decide(), const RecoveryDecision(RecoveryStep.none));
    });

    test('marker, same parent, recent: ask the server, then resume or forget', () {
      expect(decide(marker: _marker), const RecoveryDecision(RecoveryStep.checkServer));
      expect(decide(marker: _marker, active: true), const RecoveryDecision(RecoveryStep.resume));
      expect(decide(marker: _marker, active: false), const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.runEnded));
    });

    test('signed out or another parent: forget, never resume', () {
      expect(decide(marker: _marker, uid: null), const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.signedOut));
      expect(decide(marker: _marker, uid: 'uid-2', active: true), const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.otherParent));
    });

    test('older than 3 hours (or from the future): forget', () {
      expect(decide(marker: _marker, after: const Duration(hours: 3, minutes: 1), active: true), const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.tooOld));
      expect(decide(marker: _marker, after: const Duration(minutes: -5)), const RecoveryDecision(RecoveryStep.clear, RecoveryClearReason.tooOld));
      expect(decide(marker: _marker, after: const Duration(hours: 2, minutes: 59)), const RecoveryDecision(RecoveryStep.checkServer));
    });

    test('the marker holds IDs and a time only (no coordinates, no names)', () {
      final String json = jsonEncode(_marker.toJson());
      expect(jsonDecode(json), <String, Object?>{'uid': 'uid-1', 'carpoolId': 'k1', 'runId': '2026-11-16_am', 'startedAtMs': _start.millisecondsSinceEpoch});
      expect(RunMarker.fromJson(json)?.startedAt, _start);
      expect(RunMarker.fromJson('not json'), isNull);
      expect(RunMarker.fromJson('{"uid": 1}'), isNull);
    });
  });

  group('the service', () {
    late InMemorySettingsStore store;
    late FakeRecoveryNative native;
    late FakeTripRepository trips;
    late FakeLocationTracker tracker;
    late int notified;
    late DateTime now;

    RunRecoveryService service() => RunRecoveryService(
      store: store,
      native: native,
      trips: trips,
      tracker: tracker,
      notify: () async => notified++,
      now: () => now,
    );

    setUp(() {
      store = InMemorySettingsStore();
      native = FakeRecoveryNative(supported: true);
      trips = FakeTripRepository(preparation: const TripPreparation(tripId: 'k1_2026-11-16_am', selfieRequired: false, active: true));
      tracker = FakeLocationTracker();
      notified = 0;
      now = _start;
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
    });

    test('a run start writes the marker and starts the native side; the end clears both', () async {
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(s.marker?.runId, '2026-11-16_am');
      expect(native.starts, 1);
      // A resume keeps the first start time.
      now = _start.add(const Duration(minutes: 10));
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(s.marker?.startedAt, _start);
      await s.runEnded();
      expect(s.marker, isNull);
      expect(native.stops, 1);
    });

    test('relaunch during a run still on: tracking starts again, "Tracking resumed" is shown', () async {
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      now = _start.add(const Duration(minutes: 25));
      expect(await s.recover('uid-1'), RecoveryOutcome.resumed);
      expect(trips.calls, containsAllInOrder(<String>['prepare', 'start']));
      expect(tracker.starts, 1);
      expect(tracker.session?.token, 'token-123');
      expect(notified, 1);
      expect(s.marker, isNotNull);
    });

    test('the run ended on the server: the marker goes, nothing starts', () async {
      trips.preparation = const TripPreparation(tripId: 'k1_2026-11-16_am', selfieRequired: false, active: false);
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(await s.recover('uid-1'), RecoveryOutcome.cleared);
      expect(s.marker, isNull);
      expect(tracker.starts, 0);
      expect(notified, 0);
    });

    test('signed out, too old: forgotten without asking the server', () async {
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(await s.recover(null), RecoveryOutcome.cleared);
      expect(trips.calls, isEmpty);
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      now = _start.add(const Duration(hours: 4));
      expect(await s.recover('uid-1'), RecoveryOutcome.cleared);
      expect(trips.calls, isEmpty);
    });

    test('offline: the marker stays for the next try', () async {
      trips.failOnce = const TripFailure(TripFailureKind.offline);
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(await s.recover('uid-1'), RecoveryOutcome.failed);
      expect(s.marker, isNotNull);
      expect(await s.recover('uid-1'), RecoveryOutcome.resumed);
    });

    test('permission gone at relaunch: not resumed (the run screen shows the steps)', () async {
      tracker.permissionValue = TrackerPermission.denied;
      final RunRecoveryService s = service();
      await s.runStarted(uid: 'uid-1', carpoolId: 'k1', runId: '2026-11-16_am');
      expect(await s.recover('uid-1'), RecoveryOutcome.failed);
      expect(notified, 0);
    });
  });

  group('launcher', () {
    test('tracking stops (idle): the marker goes', () async {
      final FakeLocationTracker tracker = FakeLocationTracker();
      final FakeTripRepository trips = FakeTripRepository();
      final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{RunRecoveryService.markerKey: jsonEncode(_marker.toJson())});
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(store),
          // Still loading: the launcher neither recovers nor clears yet.
          sessionProvider.overrideWithValue(const SessionLoading()),
          ...tripOverrides(trips: trips, tracker: tracker),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      container.read(runRecoveryLauncherProvider);
      await tracker.stop();
      await pumpEventQueue();
      expect(store.read(RunRecoveryService.markerKey), isNull);
    });
  });

  group('the plugin channel (fake platform)', () {
    const MethodChannel channel = MethodChannel('org.schoolcarpool/run_recovery');
    final List<String> calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        return switch (call.method) {
          'startRun' => true,
          'stopRun' => true,
          _ => null,
        };
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('iPhone: every call goes to the native side', () async {
      final RunRecovery r = RunRecovery(isIos: true);
      expect(await r.startRun(), isTrue);
      await r.stopRun();
      // The plugin has no permission call at all ("Always" is never asked).
      expect(calls, <String>['startRun', 'stopRun']);
    });

    test('Android and the web: nothing is called, answers say unsupported', () async {
      final RunRecovery r = RunRecovery(isIos: false);
      expect(r.supported, isFalse);
      expect(await r.startRun(), isFalse);
      expect(calls, isEmpty);
    });

    test('a native error is not fatal', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await RunRecovery(isIos: true).startRun(), isFalse);
    });
  });
}
