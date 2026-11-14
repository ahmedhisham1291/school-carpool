import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';

import 'schedule_fakes.dart';

/// A trip of the test week (fake data only): Monday 16 Nov, morning, the
/// signed-in parent (uid-1) drives Adam (uid-1) and Laila (p1).
Trip testTrip({
  TripStatus status = TripStatus.active,
  RunDirection direction = RunDirection.toSchool,
  String driverUid = 'uid-1',
  List<TripStop>? stops,
  GeoPin? last = const GeoPin(30.05, 31.25),
  DateTime? lastPointAt,
  List<(QuickKind, DateTime)> messages = const <(QuickKind, DateTime)>[],
}) => Trip(
  id: 'k1_2026-11-14_${direction == RunDirection.toSchool ? 'am' : 'pm'}',
  carpoolId: 'k1',
  runId: '2026-11-14_${direction == RunDirection.toSchool ? 'am' : 'pm'}',
  direction: direction,
  driverUid: driverUid,
  driverFirstName: 'Mona',
  status: status,
  stops:
      stops ??
      const <TripStop>[
        TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'uid-1', state: StopState.waiting),
        TripStop(
          childId: 'h1',
          firstName: 'Laila',
          parentUid: 'p1',
          state: StopState.waiting,
          handover: <HandoverAdult>[HandoverAdult(name: 'Gran', relation: Relation.grandparent)],
        ),
      ],
  car: const TripCar(model: 'Corolla', color: 'White', plate: 'ABC 123'),
  startedAt: testNow.subtract(const Duration(minutes: 5)).toUtc(),
  last: status == TripStatus.active ? last : null,
  lastPointAt: lastPointAt ?? (status == TripStatus.active ? testNow.subtract(const Duration(seconds: 20)).toUtc() : null),
  messages: messages,
);

/// Records calls in [calls]; [failure] makes the next calls fail; the
/// streams follow [trip], [eta] and friends after [emit].
class FakeTripRepository implements TripRepository {
  FakeTripRepository({this.trip, this.run, this.preparation = const TripPreparation(tripId: 'k1_2026-11-14_am', selfieRequired: false, active: false)});

  Trip? trip;
  ScheduleRun? run;
  TripEta? eta;
  TripPreparation preparation;
  SelfieResult selfie = SelfieResult.passed;
  TripFailure? failure;

  /// Fails only the next call (for example offline once, then online).
  TripFailure? failOnce;
  List<DriverCard> cards = const <DriverCard>[];
  List<HandoverAdult> adults = <HandoverAdult>[];
  List<EmergencyAlert> emergencies = const <EmergencyAlert>[];
  EmergencyContact? contact;
  bool contactSent = true;
  final List<String> calls = <String>[];
  final List<String> requestIds = <String>[];
  final List<Uri> opened = <Uri>[];
  final StreamController<int> _changes = StreamController<int>.broadcast();

  void emit() => _changes.add(0);

  Future<void> dispose() => _changes.close();

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    await for (final int _ in _changes.stream) {
      yield read();
    }
  }

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final TripFailure? once = failOnce;
    if (once != null) {
      failOnce = null;
      throw once;
    }
    final TripFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Stream<Trip?> watchTrip(String carpoolId, String runId) => _watch<Trip?>(() => trip);

  @override
  Stream<ScheduleRun?> watchRun(String carpoolId, String runId) => _watch<ScheduleRun?>(() => run);

  @override
  Stream<TripEta?> watchEta(String tripId, String uid) => _watch<TripEta?>(() => eta);

  @override
  Stream<List<EmergencyAlert>> watchEmergencies(String carpoolId) => _watch<List<EmergencyAlert>>(() => emergencies);

  @override
  Stream<EmergencyContact?> watchEmergencyContact(String uid) => _watch<EmergencyContact?>(() => contact);

  @override
  Future<TripPreparation> prepare(String carpoolId, String runId) async {
    await _maybeFail('prepare');
    return preparation;
  }

  @override
  Future<SelfieResult> submitSelfie({required String uid, required String carpoolId, required String runId, required Uint8List jpeg}) async {
    await _maybeFail('selfie');
    return selfie;
  }

  @override
  Future<TripSession> start(String carpoolId, String runId) async {
    await _maybeFail('start');
    return TripSession(tripId: '${carpoolId}_$runId', token: 'token-123', expiresAt: DateTime.utc(2030), staleSeconds: 120);
  }

  @override
  String uploadUrl(String tripId) => 'https://example.test/tripLocation?trip=$tripId';

  @override
  Future<bool> act({required String carpoolId, required String runId, required String childId, required StopAction action, required String requestId}) async {
    requestIds.add(requestId);
    await _maybeFail('act:$childId:${action.name}');
    return true;
  }

  @override
  Future<void> confirmHandover({required String carpoolId, required String runId, required String childId}) => _maybeFail('confirm:$childId');

  @override
  Future<bool> quick({required String carpoolId, required String runId, required QuickKind kind, required String requestId}) async {
    requestIds.add(requestId);
    await _maybeFail('quick:${kind.name}');
    return true;
  }

  @override
  Future<void> endTrip(String carpoolId, String runId) => _maybeFail('end');

  @override
  Future<void> stopMyTrips() => _maybeFail('stopMine');

  @override
  Future<bool> emergency({required String carpoolId, required String runId, GeoPin? point}) async {
    await _maybeFail('emergency');
    return contactSent;
  }

  @override
  Future<List<DriverCard>> todayDriverCards(String carpoolId) async {
    calls.add('cards');
    return cards;
  }

  @override
  Future<List<HandoverAdult>> handoverAdults(String childId) async {
    await _maybeFail('adults:$childId');
    return List<HandoverAdult>.of(adults);
  }

  @override
  Future<void> saveHandoverAdults(String childId, List<HandoverAdult> list) async {
    await _maybeFail('saveAdults:$childId:${list.length}');
    adults = List<HandoverAdult>.of(list);
  }

  @override
  Future<void> saveEmergencyContact({required String name, required String phone, required Relation relation}) async {
    await _maybeFail('saveContact:${relation.name}');
    contact = EmergencyContact(name: name, phone: phone, relation: relation);
    emit();
  }

  @override
  Future<void> clearEmergencyContact() async {
    await _maybeFail('clearContact');
    contact = null;
    emit();
  }

  @override
  Future<bool> openExternal(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

/// Keeps Firebase and the location plugin out of widget tests. Always the
/// same three overrides (one ProviderScope shape per test).
List<Override> tripOverrides({TripRepository? trips, LocationTracker? tracker}) => <Override>[
  tripRepositoryProvider.overrideWithValue(trips ?? FakeTripRepository()),
  locationTrackerProvider.overrideWithValue(tracker ?? FakeLocationTracker()),
  tripClockProvider.overrideWithValue(() => testNow),
];
