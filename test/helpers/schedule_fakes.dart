import 'dart:async';

import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';

/// Saturday 14 Nov 2026, 10:00: the fixed "now" of schedule tests.
final DateTime testNow = DateTime(2026, 11, 14, 10);

/// A run of the test week (fake data only).
ScheduleRun testRun(
  String day,
  RunDirection direction, {
  RunStatus status = RunStatus.planned,
  String? driverUid = 'uid-1',
  String driverFirstName = 'Mona',
  String? swapId,
  String? swapBy,
  List<Rider> riders = const <Rider>[
    Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1'),
    Rider(id: 'h1', firstName: 'Laila', parentUid: 'p1'),
  ],
  List<Rider> absent = const <Rider>[],
  bool fallback = false,
}) {
  final DateTime date = ScheduleDates.parse(day)!;
  final String time = direction == RunDirection.toSchool ? '07:30' : '14:30';
  final int hour = direction == RunDirection.toSchool ? 7 : 14;
  return ScheduleRun(
    id: '${day}_${direction == RunDirection.toSchool ? 'am' : 'pm'}',
    date: date,
    direction: direction,
    time: time,
    status: status,
    driverUid: driverUid,
    driverFirstName: driverUid == null ? '' : driverFirstName,
    swapId: swapId,
    swapBy: swapBy,
    riders: riders,
    absent: absent,
    fallback: fallback,
    start: DateTime(date.year, date.month, date.day, hour, 30),
    confirmBy: DateTime(date.year, date.month, date.day - 1, 21),
  );
}

/// Records calls in [calls]; [failure] makes every call fail; streams follow [emit].
class FakeScheduleRepository implements ScheduleRepository {
  FakeScheduleRepository({
    Map<String, List<ScheduleRun>>? weeks,
    this.exceptions = const <ScheduleException>[],
    this.balance,
    this.planResult = const PlanResult(planned: 10, open: 0),
  }) : weeks = weeks ?? <String, List<ScheduleRun>>{};

  /// Runs by week start key ("2026-11-14").
  Map<String, List<ScheduleRun>> weeks;
  List<ScheduleException> exceptions;
  DriveBalance? balance;
  PlanResult planResult;
  CarpoolFailure? failure;
  Object? streamError;
  final List<String> calls = <String>[];
  ExceptionDraft? savedException;
  List<Weekday>? savedDays;
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

  void _maybeFail(String call) {
    calls.add(call);
    final CarpoolFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  void _update(String runId, ScheduleRun Function(ScheduleRun) change) {
    weeks = <String, List<ScheduleRun>>{
      for (final MapEntry<String, List<ScheduleRun>> e in weeks.entries)
        e.key: <ScheduleRun>[for (final ScheduleRun r in e.value) r.id == runId ? change(r) : r],
    };
    emit();
  }

  ScheduleRun _with(ScheduleRun r, {required RunStatus status, String? driverUid, String driverFirstName = ''}) => ScheduleRun(
    id: r.id,
    date: r.date,
    direction: r.direction,
    time: r.time,
    status: status,
    driverUid: driverUid,
    driverFirstName: driverFirstName,
    riders: r.riders,
    absent: r.absent,
    start: r.start,
    confirmBy: r.confirmBy,
  );

  @override
  Stream<List<ScheduleRun>> watchWeek(String carpoolId, DateTime weekStart) =>
      _watch(() => weeks[ScheduleDates.key(weekStart)] ?? const <ScheduleRun>[]);

  @override
  Stream<List<ScheduleException>> watchExceptions(String carpoolId) => _watch(() => exceptions);

  @override
  Stream<DriveBalance?> watchBalance(String carpoolId, String termId) => _watch(() => balance);

  @override
  Future<PlanResult> planWeek(String carpoolId, DateTime weekStart) async {
    _maybeFail('plan:${ScheduleDates.key(weekStart)}');
    return planResult;
  }

  @override
  Future<void> confirmRun(String carpoolId, String runId) async {
    _maybeFail('confirm:$runId');
    _update(runId, (ScheduleRun r) => _with(r, status: RunStatus.confirmed, driverUid: r.driverUid, driverFirstName: r.driverFirstName));
  }

  @override
  Future<void> requestSwap(String carpoolId, String runId) async {
    _maybeFail('swap:$runId');
    _update(runId, (ScheduleRun r) => _with(r, status: RunStatus.open));
  }

  @override
  Future<void> cancelSwap(String carpoolId, String runId) async => _maybeFail('cancelSwap:$runId');

  @override
  Future<void> takeRun(String carpoolId, String runId) async {
    _maybeFail('take:$runId');
    _update(runId, (ScheduleRun r) => _with(r, status: RunStatus.confirmed, driverUid: 'uid-1', driverFirstName: 'Mona'));
  }

  @override
  Future<void> setChildAbsent({required String carpoolId, required DateTime date, required String childId, required bool absent}) async =>
      _maybeFail('absent:${ScheduleDates.key(date)}:$childId:$absent');

  @override
  Future<void> setDrivingDays(String carpoolId, List<Weekday> days) async {
    _maybeFail('days:${days.map((Weekday d) => d.name).join(',')}');
    savedDays = days;
  }

  @override
  Future<void> saveException(String carpoolId, ExceptionDraft draft) async {
    _maybeFail('saveException');
    savedException = draft;
  }

  @override
  Future<void> deleteException(String carpoolId, String exceptionId) async => _maybeFail('deleteException:$exceptionId');

  Future<void> dispose() => _changes.close();
}
