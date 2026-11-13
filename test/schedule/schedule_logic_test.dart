// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_logic.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

import '../helpers/schedule_fakes.dart';

CarpoolMember _member(String uid, int children) => CarpoolMember(
  uid: uid,
  firstName: uid.toUpperCase(),
  children: <CarpoolChild>[for (int i = 0; i < children; i++) CarpoolChild(id: '$uid$i', firstName: 'Kid', grade: Grade.g1)],
);

void main() {
  group('dates (Egyptian week, terms)', () {
    test('weeks start on Saturday', () {
      expect(ScheduleDates.key(ScheduleDates.weekStart(DateTime(2026, 11, 19, 18))), '2026-11-14');
      expect(ScheduleDates.key(ScheduleDates.weekStart(DateTime(2026, 11, 20))), '2026-11-14');
      expect(ScheduleDates.key(ScheduleDates.weekStart(DateTime(2026, 11, 21))), '2026-11-21');
      expect(ScheduleDates.weekdayOf(DateTime(2026, 11, 14)), Weekday.sat);
      expect(ScheduleDates.weekdayOf(DateTime(2026, 11, 15)), Weekday.sun);
      expect(ScheduleDates.weekdayOf(DateTime(2026, 11, 20)), Weekday.fri);
    });

    test('terms match the server', () {
      expect(ScheduleDates.termId(DateTime(2026, 11, 14)), '2026-t1');
      expect(ScheduleDates.termId(DateTime(2027, 1, 31)), '2026-t1');
      expect(ScheduleDates.termId(DateTime(2027, 2)), '2026-t2');
    });

    test('day counts ignore clock changes', () {
      expect(ScheduleDates.daysBetween(DateTime(2026, 4, 20), DateTime(2026, 4, 27)), 7);
      expect(ScheduleDates.daysBetween(DateTime(2026, 10, 27), DateTime(2026, 11, 2)), 6);
      expect(ScheduleDates.parse('soon'), isNull);
    });
  });

  group('run actions (F11, F28)', () {
    final DateTime now = testNow;

    test('the proposed driver confirms before the cut-off, not after', () {
      final ScheduleRun run = testRun('2026-11-15', RunDirection.toSchool);
      expect(runAction(run, 'uid-1', now, hasCar: true), RunAction.confirm);
      expect(runAction(run, 'p1', now, hasCar: true), RunAction.none);
      expect(runAction(run, 'uid-1', DateTime(2026, 11, 14, 21, 1), hasCar: true), RunAction.none);
    });

    test('a confirmed driver can still ask for a swap until the run starts', () {
      final ScheduleRun run = testRun('2026-11-15', RunDirection.toSchool, status: RunStatus.confirmed);
      expect(runAction(run, 'uid-1', now, hasCar: true), RunAction.cantDrive);
      expect(runAction(run, 'uid-1', DateTime(2026, 11, 15, 8), hasCar: true), RunAction.none);
    });

    test('open runs: members with a car take them; the requester takes back', () {
      final ScheduleRun swap = testRun('2026-11-15', RunDirection.toSchool, status: RunStatus.open, driverUid: null, swapId: 's', swapBy: 'p1');
      expect(runAction(swap, 'uid-1', now, hasCar: true), RunAction.take);
      expect(runAction(swap, 'uid-1', now, hasCar: false), RunAction.none);
      expect(runAction(swap, 'p1', now, hasCar: true), RunAction.takeBack);
    });

    test('missed, cancelled and done runs offer nothing', () {
      for (final RunStatus s in <RunStatus>[RunStatus.missed, RunStatus.cancelled, RunStatus.completed]) {
        expect(runAction(testRun('2026-11-15', RunDirection.toSchool, status: s), 'uid-1', now, hasCar: true), RunAction.none);
      }
    });

    test('counts runs to confirm and groups runs by day, morning first', () {
      final List<ScheduleRun> runs = <ScheduleRun>[
        testRun('2026-11-16', RunDirection.toHome),
        testRun('2026-11-15', RunDirection.toHome, driverUid: 'p1'),
        testRun('2026-11-15', RunDirection.toSchool),
      ];
      expect(runsToConfirm(runs, 'uid-1', now), 2);
      final List<(DateTime, List<ScheduleRun>)> days = runsByDay(runs);
      expect(days.map(((DateTime, List<ScheduleRun>) d) => ScheduleDates.key(d.$1)), <String>['2026-11-15', '2026-11-16']);
      expect(days.first.$2.map((ScheduleRun r) => r.direction), <RunDirection>[RunDirection.toSchool, RunDirection.toHome]);
    });

    test("the parent's own children on a run, riding then away", () {
      final ScheduleRun run = testRun(
        '2026-11-15',
        RunDirection.toSchool,
        riders: const <Rider>[Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1'), Rider(id: 'h1', firstName: 'Laila', parentUid: 'p1')],
        absent: const <Rider>[Rider(id: 'c2', firstName: 'Jana', parentUid: 'uid-1')],
      );
      expect(myChildrenOn(run, 'uid-1').map(((Rider, bool) x) => '${x.$1.id}:${x.$2}'), <String>['c1:false', 'c2:true']);
    });
  });

  group('drive balance (F37)', () {
    test('uneven children: the fair share follows the number of children', () {
      final List<CarpoolMember> members = <CarpoolMember>[_member('a', 1), _member('b', 2)];
      // 9 runs: fair shares 3 and 6. a drove 3, b drove 6: both even.
      const DriveBalance even = DriveBalance(
        termId: '2026-t1',
        families: <FamilyBalance>[
          FamilyBalance(uid: 'a', firstName: 'A', driven: 3, received: 6),
          FamilyBalance(uid: 'b', firstName: 'B', driven: 6, received: 3),
        ],
      );
      final Map<String, double> debts = driveDebts(even.families, members);
      expect(debts['a'], closeTo(0, 1e-9));
      expect(debts['b'], closeTo(0, 1e-9));
      // b drove 4 of 9: behind its share of 6, so b drove least.
      const DriveBalance behind = DriveBalance(
        termId: '2026-t1',
        families: <FamilyBalance>[
          FamilyBalance(uid: 'a', firstName: 'A', driven: 5, received: 4),
          FamilyBalance(uid: 'b', firstName: 'B', driven: 4, received: 5),
        ],
      );
      expect(droveLeast(behind, members), 'b');
      expect(balanceOrder(behind, members).map((FamilyBalance f) => f.uid), <String>['b', 'a']);
    });

    test('members with no runs yet are listed at zero; nobody "drove least" before any run', () {
      final List<CarpoolMember> members = <CarpoolMember>[_member('a', 1), _member('b', 1)];
      expect(balanceOrder(null, members).map((FamilyBalance f) => f.driven), <int>[0, 0]);
      expect(droveLeast(null, members), isNull);
    });
  });

  group('exceptions (F30)', () {
    test('ranges end on or after the start, at most 60 days; times need a new time', () {
      ExceptionDraft d(DateTime from, DateTime to, {ExceptionKind kind = ExceptionKind.noSchool, String? morning}) =>
          ExceptionDraft(kind: kind, reason: ExceptionReason.ramadan, from: from, to: to, morning: morning);
      expect(checkException(d(DateTime(2027, 2, 8), DateTime(2027, 3, 9))), isNull);
      expect(checkException(d(DateTime(2027, 2, 8), DateTime(2027, 2, 7))), ExceptionProblem.range);
      expect(checkException(d(DateTime(2027, 2, 8), DateTime(2027, 4, 9))), ExceptionProblem.range);
      expect(checkException(d(DateTime(2027, 2, 8), DateTime(2027, 2, 8), kind: ExceptionKind.times)), ExceptionProblem.times);
      expect(checkException(d(DateTime(2027, 2, 8), DateTime(2027, 2, 8), kind: ExceptionKind.times, morning: '08:30')), isNull);
    });

    test('the draft sends dates as Cairo date keys and times only for time changes', () {
      final ExceptionDraft holiday = ExceptionDraft(kind: ExceptionKind.noSchool, reason: ExceptionReason.holiday, from: DateTime(2026, 11, 19), to: DateTime(2026, 11, 19));
      expect(holiday.toJson('k1'), <String, Object?>{'carpoolId': 'k1', 'kind': 'noSchool', 'reason': 'holiday', 'from': '2026-11-19', 'to': '2026-11-19'});
      final ExceptionDraft ramadan = ExceptionDraft(
        kind: ExceptionKind.times,
        reason: ExceptionReason.ramadan,
        from: DateTime(2027, 2, 8),
        to: DateTime(2027, 3, 9),
        afternoon: '13:30',
      );
      expect(ramadan.toJson('k1')['afternoon'], '13:30');
      expect(ramadan.toJson('k1').containsKey('morning'), isTrue);
    });
  });

  group('parsing', () {
    test('a run document', () {
      final ScheduleRun run = ScheduleRun.fromDoc('2026-11-15_am', <String, Object?>{
        'date': '2026-11-15',
        'direction': 'toSchool',
        'time': '07:30',
        'status': 'open',
        'driverUid': null,
        'swapId': 's1',
        'swapBy': 'p1',
        'riders': <Object?>[
          <String, Object?>{'id': 'c1', 'firstName': 'Adam', 'parentUid': 'uid-1'},
        ],
        'absent': <Object?>[],
        'startAt': Timestamp.fromDate(DateTime.utc(2026, 11, 15, 5, 30)),
        'confirmBy': Timestamp.fromDate(DateTime.utc(2026, 11, 14, 19)),
      });
      expect(run.status, RunStatus.open);
      expect(run.swapOpen, isTrue);
      expect(run.swapBy, 'p1');
      expect(run.riders.single.firstName, 'Adam');
      expect(run.start, DateTime.utc(2026, 11, 15, 5, 30));
      expect(RunStatus.fromName('weird'), RunStatus.open);
    });

    test('a balance and an exception document', () {
      final DriveBalance b = DriveBalance.fromDoc('2026-t1', <String, Object?>{
        'families': <String, Object?>{
          'p1': <String, Object?>{'firstName': 'Hoda', 'driven': 3, 'received': 1},
        },
      });
      expect(b.families.single.driven, 3);
      final ScheduleException e = ScheduleException.fromDoc('x1', <String, Object?>{'kind': 'times', 'reason': 'ramadan', 'from': '2027-02-08', 'to': '2027-03-09', 'afternoon': '13:30'});
      expect(e.kind, ExceptionKind.times);
      expect(e.oneDay, isFalse);
      expect(e.morning, isNull);
    });

    test('schedule refusals from the server', () {
      CarpoolFailureKind kind(String reason) => CarpoolFailure.from(
        FirebaseFunctionsException(message: reason, code: 'failed-precondition', details: <Object?, Object?>{'reason': reason}),
      ).kind;
      expect(kind('no-consent'), CarpoolFailureKind.noConsent);
      expect(kind('not-driver'), CarpoolFailureKind.notDriver);
      expect(kind('too-late'), CarpoolFailureKind.tooLate);
      expect(kind('run-taken'), CarpoolFailureKind.runTaken);
      expect(kind('not-plannable'), CarpoolFailureKind.notPlannable);
      expect(kind('too-many-exceptions'), CarpoolFailureKind.tooManyExceptions);
    });
  });
}
