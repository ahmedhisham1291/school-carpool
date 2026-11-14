// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';

import '../helpers/schedule_fakes.dart';
import '../helpers/trip_fakes.dart';

/// A run that starts 30 minutes after [testNow] (Saturday 10:00).
ScheduleRun _soon({RunStatus status = RunStatus.confirmed, String driver = 'uid-1'}) => ScheduleRun(
  id: '2026-11-14_am',
  date: DateTime(2026, 11, 14),
  direction: RunDirection.toSchool,
  time: '10:30',
  status: status,
  driverUid: driver,
  driverFirstName: 'Mona',
  riders: const <Rider>[Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1'), Rider(id: 'h1', firstName: 'Laila', parentUid: 'p1')],
  start: DateTime(2026, 11, 14, 10, 30),
);

const TripStop _stop = TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'p1', state: StopState.waiting);

TripStop _at(StopState s) => TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'p1', state: s);

void main() {
  group('who may start or follow a run (F15)', () {
    test('only the confirmed driver, from an hour before to three hours after', () {
      expect(canStartRun(_soon(), 'uid-1', testNow), isTrue);
      expect(canStartRun(_soon(), 'p1', testNow), isFalse);
      expect(canStartRun(_soon(status: RunStatus.planned), 'uid-1', testNow), isFalse);
      expect(canStartRun(_soon(status: RunStatus.completed), 'uid-1', testNow), isTrue);
      expect(canStartRun(_soon(), 'uid-1', DateTime(2026, 11, 14, 9, 29)), isFalse);
      expect(canStartRun(_soon(), 'uid-1', DateTime(2026, 11, 14, 13, 31)), isFalse);
    });

    test('parents of children on the run follow it; others do not', () {
      expect(canFollowRun(_soon(driver: 'x'), 'p1', testNow), isTrue);
      expect(canFollowRun(_soon(driver: 'x'), 'p2', testNow), isFalse);
      expect(canFollowRun(_soon(), 'uid-1', testNow), isFalse, reason: 'the driver drives, not follows');
    });
  });

  group('stops (F16, F41)', () {
    test('morning: Arrived and Picked up, then At school', () {
      expect(stopActions(_stop, RunDirection.toSchool), <StopAction>[StopAction.arrived, StopAction.pickedUp]);
      expect(stopActions(_at(StopState.arrived), RunDirection.toSchool), <StopAction>[StopAction.arrived, StopAction.pickedUp]);
      expect(stopActions(_at(StopState.onBoard), RunDirection.toSchool), <StopAction>[StopAction.dropped]);
      expect(stopActions(_at(StopState.dropped), RunDirection.toSchool), isEmpty);
    });

    test('afternoon: Picked up at school, then Arrived and Handed over', () {
      expect(stopActions(_stop, RunDirection.toHome), <StopAction>[StopAction.pickedUp]);
      expect(stopActions(_at(StopState.onBoard), RunDirection.toHome), <StopAction>[StopAction.arrived, StopAction.dropped]);
      expect(stopActions(_at(StopState.received), RunDirection.toHome), isEmpty);
      expect(stopActions(_at(StopState.absent), RunDirection.toHome), isEmpty);
    });

    test('the current stop is the first one not done', () {
      final Trip trip = testTrip(
        stops: const <TripStop>[
          TripStop(childId: 'a', firstName: 'A', parentUid: 'p', state: StopState.onBoard),
          TripStop(childId: 'b', firstName: 'B', parentUid: 'p', state: StopState.absent),
          TripStop(childId: 'c', firstName: 'C', parentUid: 'p', state: StopState.waiting),
        ],
      );
      expect(currentStopIndex(trip), 0);
      expect(trip.riding.map((TripStop s) => s.childId), <String>['a', 'c']);
    });

    test('handover: the receiving parent, afternoon, after the drop-off', () {
      final Trip pm = testTrip(direction: RunDirection.toHome);
      expect(canConfirmHandover(pm, _at(StopState.dropped), 'p1'), isTrue);
      expect(canConfirmHandover(pm, _at(StopState.dropped), 'p2'), isFalse);
      expect(canConfirmHandover(pm, _at(StopState.onBoard), 'p1'), isFalse);
      expect(canConfirmHandover(testTrip(), _at(StopState.dropped), 'p1'), isFalse, reason: 'morning: dropped at school');
    });
  });

  group('location health (staleness, UTC instants)', () {
    final DateTime now = DateTime.utc(2026, 11, 14, 8);

    test('live, waiting, stopped after the stale time, off after the run', () {
      expect(locationHealth(testTrip(lastPointAt: now.subtract(const Duration(seconds: 30))), now), LocationHealth.live);
      expect(locationHealth(testTrip(lastPointAt: now.subtract(const Duration(seconds: 121))), now), LocationHealth.stale);
      expect(locationHealth(testTrip(lastPointAt: now.subtract(const Duration(seconds: 120))), now), LocationHealth.live);
      expect(locationHealth(testTrip(status: TripStatus.ended), now), LocationHealth.off);
      final Trip fresh = Trip(
        id: 't',
        carpoolId: 'k1',
        runId: 'r',
        direction: RunDirection.toSchool,
        driverUid: 'd',
        driverFirstName: 'D',
        status: TripStatus.active,
        stops: const <TripStop>[],
        startedAt: now.subtract(const Duration(seconds: 10)),
      );
      expect(locationHealth(fresh, now), LocationHealth.waiting);
      expect(locationHealth(fresh, now.add(const Duration(minutes: 3))), LocationHealth.stale);
    });

    test('minutes until the arrival time', () {
      expect(minutesUntil(null, now), isNull);
      expect(minutesUntil(now.add(const Duration(seconds: 20)), now), 0);
      expect(minutesUntil(now.add(const Duration(seconds: 61)), now), 2);
      expect(minutesUntil(now.add(const Duration(minutes: 6)), now), 6);
    });
  });

  group('input', () {
    test('request IDs are random and server-safe', () {
      final String a = newRequestId(math.Random(1));
      final String b = newRequestId(math.Random(2));
      expect(a, isNot(b));
      expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(a), isTrue);
    });

    test('names: letters in Arabic or English, 2 to 40', () {
      expect(validPersonName('Mona'), isTrue);
      expect(validPersonName('منى أحمد'), isTrue);
      expect(validPersonName("O'Neil"), isTrue);
      expect(validPersonName('M'), isFalse);
      expect(validPersonName('Mona1'), isFalse);
      expect(validPersonName(''), isFalse);
    });
  });

  group('records from Firestore and Functions', () {
    test('a trip document', () {
      final Trip t = Trip.fromDoc('k1_2026-11-16_pm', <String, dynamic>{
        'carpoolId': 'k1',
        'runId': '2026-11-16_pm',
        'direction': 'toHome',
        'driverUid': 'd1',
        'driverFirstName': 'Dina',
        'status': 'handover',
        'car': const <String, dynamic>{'model': 'Corolla', 'color': 'White', 'plate': 'ABC 123'},
        'stops': const <Object?>[
          <String, dynamic>{
            'childId': 'c1',
            'firstName': 'Adam',
            'parentUid': 'p1',
            'state': 'dropped',
            'arrivedCount': 2,
            'handover': <Object?>[<String, dynamic>{'name': 'Gran', 'relation': 'grandparent'}],
          },
          <String, dynamic>{'childId': 'c2', 'firstName': 'Omar', 'parentUid': 'p3', 'state': 'odd'},
        ],
        'last': const <String, dynamic>{'location': GeoPoint(30, 31)},
        'lastPointAt': Timestamp.fromMillisecondsSinceEpoch(1000),
        'messages': <Object?>[
          <String, dynamic>{'kind': 'late', 'at': Timestamp.fromMillisecondsSinceEpoch(2000)},
          <String, dynamic>{'kind': 'nope', 'at': Timestamp.fromMillisecondsSinceEpoch(3000)},
        ],
      });
      expect(t.status, TripStatus.handover);
      expect(t.tracking, isFalse);
      expect(t.direction, RunDirection.toHome);
      expect(t.stops.first.handover.single.relation, Relation.grandparent);
      expect(t.stops.first.arrivedCount, 2);
      expect(t.stops.last.state, StopState.waiting);
      expect(t.last?.lat, 30);
      expect(t.last?.lng, 31);
      expect(t.lastPointAt, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
      expect(t.messages.single.$1, QuickKind.late);
      expect(t.car?.plate, 'ABC 123');
    });

    test('arrival times, driver cards and the upload session', () {
      final TripEta eta = TripEta.fromDoc(<String, dynamic>{
        'stops': <String, dynamic>{'c1': Timestamp.fromMillisecondsSinceEpoch(5000), 'bad': 'x'},
      });
      expect(eta.stops.keys, <String>['c1']);
      final DriverCard card = DriverCard.fromMap(const <Object?, Object?>{
        'runId': 'r',
        'direction': 'toSchool',
        'time': '07:30',
        'driverFirstName': 'Dina',
        'photoUrl': 'http://not-https.example/x.jpg',
      });
      expect(card.photoUrl, isNull, reason: 'only https links are shown');
      final TripSession s = TripSession.fromMap(const <Object?, Object?>{'tripId': 't', 'token': 'x', 'expiresAtMs': 1000, 'staleSeconds': 90});
      expect(s.staleSeconds, 90);
      expect(s.expiresAt, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    });

    test('server refusals become short messages', () {
      TripFailureKind kind(String reason) =>
          TripFailure.from(FirebaseFunctionsException(message: reason, code: 'failed-precondition', details: <String, Object?>{'reason': reason})).kind;
      expect(kind('driving-paused'), TripFailureKind.drivingPaused);
      expect(kind('selfie-required'), TripFailureKind.selfieRequired);
      expect(kind('too-early'), TripFailureKind.tooEarly);
      expect(kind('wrong-state'), TripFailureKind.wrongState);
      expect(TripFailure.from(FirebaseFunctionsException(message: 'x', code: 'unavailable')).isOffline, isTrue);
      expect(TripFailure.from(StateError('x')).kind, TripFailureKind.unknown);
    });
  });

  group('fake location tracker', () {
    test('asks for Always, starts only with it and stops after the run', () async {
      final FakeLocationTracker tracker = FakeLocationTracker();
      addTearDown(tracker.dispose);
      expect(await tracker.permission(), TrackerPermission.notAsked);
      const TrackerSession session = TrackerSession(tripId: 't', uploadUrl: 'https://x.test', token: 'tok');
      await expectLater(tracker.start(session), throwsStateError);
      expect(await tracker.requestAlways(), TrackerPermission.always);
      await tracker.start(session);
      expect(await tracker.activeTrip(), 't');
      await tracker.stop();
      expect(await tracker.activeTrip(), isNull);
      expect(tracker.stops, 1);
    });

    test('refused: stays refused', () async {
      final FakeLocationTracker tracker = FakeLocationTracker(grantOnRequest: TrackerPermission.whileInUse);
      addTearDown(tracker.dispose);
      expect(await tracker.requestAlways(), TrackerPermission.whileInUse);
    });
  });
}
