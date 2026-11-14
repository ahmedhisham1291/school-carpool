// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/carpool_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/schedule_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

const CarpoolMember _hoda = CarpoolMember(
  uid: 'p1',
  firstName: 'Hoda',
  isAdmin: true,
  children: <CarpoolChild>[CarpoolChild(id: 'h1', firstName: 'Laila', grade: Grade.g2)],
);

/// The signed-in parent (uid-1) with an approved car.
final CarpoolMember _meWithCar = CarpoolMember(
  uid: 'uid-1',
  firstName: 'Mona',
  children: const <CarpoolChild>[CarpoolChild(id: 'c1', firstName: 'Adam', grade: Grade.g3)],
  car: CarpoolCar(seats: 4, validUntil: DateTime(2030)),
  drivingDays: const <Weekday>[Weekday.sun, Weekday.tue],
);

const String _week = '2026-11-14';

FakeCarpoolRepository _carpools({bool admin = false}) => FakeCarpoolRepository(
  memberships: <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved, isAdmin: admin)],
  members: <CarpoolMember>[_hoda, _meWithCar],
);

/// A week with every kind of run (fake data only).
List<ScheduleRun> _fullWeek() => <ScheduleRun>[
  testRun('2026-11-15', RunDirection.toSchool),
  testRun('2026-11-15', RunDirection.toHome, status: RunStatus.confirmed, driverUid: 'p1', driverFirstName: 'Hoda'),
  testRun('2026-11-16', RunDirection.toSchool, status: RunStatus.open, driverUid: null, swapId: 's1', swapBy: 'p1'),
  testRun('2026-11-16', RunDirection.toHome, status: RunStatus.open, driverUid: null),
  testRun('2026-11-17', RunDirection.toSchool, status: RunStatus.cancelled, driverUid: null),
  testRun('2026-11-17', RunDirection.toHome, status: RunStatus.cancelled, driverUid: null),
  testRun('2026-11-18', RunDirection.toSchool, status: RunStatus.confirmed),
  testRun('2026-11-18', RunDirection.toHome, fallback: true),
  testRun('2026-11-19', RunDirection.toSchool, status: RunStatus.open, driverUid: null, swapId: 's2', swapBy: 'uid-1'),
  testRun('2026-11-19', RunDirection.toHome, driverUid: 'p1', driverFirstName: 'Hoda'),
];

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides({FakeCarpoolRepository? carpools, FakeScheduleRepository? schedule}) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(carpools: carpools ?? _carpools(), schedule: schedule ?? FakeScheduleRepository()),
  verificationRepositoryProvider.overrideWithValue(FakeVerificationRepository()),
  childrenProvider.overrideWith((Ref ref) => Stream<List<ChildRecord>>.value(const <ChildRecord>[])),
  vehicleProvider.overrideWith((Ref ref) => Stream<VehicleRecord?>.value(null)),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required List<Override> overrides,
  Locale locale = AppLocales.english,
  double width = 400,
  double height = 1600,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, height * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.build(DesignDirection.a, brightness),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

/// Scrolls the screen's list until [key] is fully on screen, then taps it.
Future<void> _tapInList(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Taps [key] inside an open sheet or dialog (brought fully on screen first).
Future<void> _tapInSheet(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _schedule() => CarpoolRoutes.schedule('k1');

void main() {
  setUpAll(loadAppFonts);

  group('week plan (F7, F28)', () {
    testWidgets('shows each day with a driver and status for every run, and runs to confirm', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      expect(find.text('Week plan'), findsOneWidget);
      expect(find.byKey(const Key('schedule.toConfirm')), findsOneWidget);
      expect(find.text('You have 2 runs to confirm'), findsOneWidget);
      expect(find.text('07:30'), findsWidgets);
      expect(find.text('To school · You · 2 children'), findsWidgets);
      expect(find.text('Home · Hoda · 2 children'), findsWidgets);
      for (final String badge in <String>['To confirm', 'Confirmed', 'Swap asked', 'Needs driver', 'No school']) {
        expect(find.text(badge), findsWidgets, reason: badge);
      }
      // Not the admin: no Plan button, but My driving days.
      expect(find.byKey(const Key('schedule.plan')), findsNothing);
      expect(find.byKey(const Key('schedule.myDays')), findsOneWidget);
    });

    testWidgets('next week not planned: members are told the admin plans it', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await tester.tap(find.byKey(const Key('schedule.week.1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule.empty')), findsOneWidget);
      expect(find.text('Not planned yet'), findsOneWidget);
      expect(find.text('The group admin plans the week. Pick your driving days.'), findsOneWidget);
    });

    testWidgets('the admin plans the week from the empty state and sees the result', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(planResult: const PlanResult(planned: 8, open: 2));
      await _pump(tester, _schedule(), overrides: _overrides(carpools: _carpools(admin: true), schedule: schedule));
      expect(find.text('Propose a driver for each run. Each driver confirms their runs.'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Plan the week'));
      await tester.pumpAndSettle();
      expect(schedule.calls, contains('plan:$_week'));
      expect(find.text('Proposed. 2 runs need a driver'), findsOneWidget);
    });

    testWidgets('the proposed driver confirms a run', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-15_am');
      expect(find.byKey(const Key('run.deadline')), findsOneWidget);
      expect(find.text('Adam'), findsOneWidget);
      expect(find.text('Laila'), findsOneWidget);
      await _tapInSheet(tester, 'run.confirm');
      expect(schedule.calls, contains('confirm:2026-11-15_am'));
      expect(find.text('Drive confirmed'), findsOneWidget);
    });

    testWidgets("Can't drive asks first, then asks for a swap (F11)", (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-18_am');
      await _tapInSheet(tester, 'run.cantDrive');
      expect(find.text('Ask for a swap?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Ask for swap'));
      await tester.pumpAndSettle();
      expect(schedule.calls, contains('swap:2026-11-18_am'));
      expect(find.text('Swap request sent'), findsOneWidget);
    });

    testWidgets("a member takes another parent's swap after confirming", (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-16_am');
      expect(find.text('No driver yet'), findsWidgets);
      await _tapInSheet(tester, 'run.take');
      expect(find.text('Drive this run?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, "I'll drive it").last);
      await tester.pumpAndSettle();
      expect(schedule.calls, contains('take:2026-11-16_am'));
      expect(find.text('You drive this run'), findsOneWidget);
    });

    testWidgets('a server refusal (no consent) shows in the sheet', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()})
        ..failure = const CarpoolFailure(CarpoolFailureKind.noConsent);
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-16_pm');
      await _tapInSheet(tester, 'run.take');
      await tester.tap(find.widgetWithText(AppButton, "I'll drive it").last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('run.error')), findsOneWidget);
      expect(find.text('Every parent must accept you as a driver first.'), findsOneWidget);
    });

    testWidgets('the parent who asked for a swap can take it back', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-19_am');
      expect(find.byKey(const Key('run.take')), findsNothing);
      await _tapInSheet(tester, 'run.takeBack');
      expect(schedule.calls, contains('cancelSwap:2026-11-19_am'));
    });

    testWidgets("another driver's run offers no driver action", (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-19_pm');
      expect(find.text('Driver: Hoda'), findsOneWidget);
      for (final String key in <String>['run.confirm', 'run.cantDrive', 'run.take', 'run.takeBack']) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
    });

    testWidgets('a missed run tells each family to take their own child', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(
        weeks: <String, List<ScheduleRun>>{
          _week: <ScheduleRun>[testRun('2026-11-15', RunDirection.toSchool, status: RunStatus.missed, driverUid: null)],
        },
      );
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      expect(find.text('Own trip'), findsOneWidget);
      await _tapInList(tester, 'schedule.run.2026-11-15_am');
      expect(find.byKey(const Key('run.missed')), findsOneWidget);
      expect(find.byKey(const Key('run.take')), findsNothing);
    });
  });

  group('child absent today (F27)', () {
    testWidgets("marking one's child away tells the driver", (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.run.2026-11-15_pm');
      // Only the parent's own child has a switch.
      expect(find.byKey(const Key('run.absent.c1')), findsOneWidget);
      expect(find.byKey(const Key('run.absent.h1')), findsNothing);
      await _tapInSheet(tester, 'run.absent.c1');
      expect(schedule.calls, contains('absent:2026-11-15:c1:true'));
      expect(find.text('Driver told'), findsOneWidget);
    });

    testWidgets('an away child is shown as away and can come back', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(
        weeks: <String, List<ScheduleRun>>{
          _week: <ScheduleRun>[
            testRun(
              '2026-11-15',
              RunDirection.toSchool,
              riders: const <Rider>[Rider(id: 'h1', firstName: 'Laila', parentUid: 'p1')],
              absent: const <Rider>[Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1')],
            ),
          ],
        },
      );
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      expect(find.text('To school · You · 1 child'), findsOneWidget);
      await _tapInList(tester, 'schedule.run.2026-11-15_am');
      expect(find.text('Adam (away)'), findsOneWidget);
      await _tapInSheet(tester, 'run.absent.c1');
      expect(schedule.calls, contains('absent:2026-11-15:c1:false'));
    });
  });

  group('driving days (F7)', () {
    testWidgets('a member picks carpool days and saves; a refusal says how to fix it', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{_week: _fullWeek()});
      await _pump(tester, _schedule(), overrides: _overrides(schedule: schedule));
      await _tapInList(tester, 'schedule.myDays');
      expect(find.byKey(const Key('days.fri')), findsNothing);
      expect(find.byKey(const Key('days.sun')), findsOneWidget);
      await _tapInSheet(tester, 'days.wed');
      schedule.failure = const CarpoolFailure(CarpoolFailureKind.noConsent);
      await _tapInSheet(tester, 'days.save');
      expect(find.byKey(const Key('days.error')), findsOneWidget);
      schedule.failure = null;
      await _tapInSheet(tester, 'days.save');
      expect(schedule.savedDays, <Weekday>[Weekday.sun, Weekday.tue, Weekday.wed]);
      expect(find.text('Days saved'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('offline and error views with retry', (WidgetTester tester) async {
      final FakeScheduleRepository offline = FakeScheduleRepository()..streamError = const CarpoolFailure(CarpoolFailureKind.offline);
      await _pump(tester, _schedule(), overrides: _overrides(schedule: offline));
      expect(find.byType(OfflineStateView), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      final FakeScheduleRepository broken = FakeScheduleRepository()..streamError = const CarpoolFailure(CarpoolFailureKind.unknown);
      await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: _overrides(schedule: broken));
      expect(find.byType(ErrorStateView), findsOneWidget);
    });
  });

  group('days off and times (F30)', () {
    final List<ScheduleException> list = <ScheduleException>[
      ScheduleException(id: 'x1', kind: ExceptionKind.noSchool, reason: ExceptionReason.holiday, from: DateTime(2026, 11, 19), to: DateTime(2026, 11, 19)),
      ScheduleException(
        id: 'x2',
        kind: ExceptionKind.times,
        reason: ExceptionReason.ramadan,
        from: DateTime(2027, 2, 8),
        to: DateTime(2027, 3, 9),
        morning: '08:30',
        afternoon: '13:30',
      ),
    ];

    testWidgets('members see the list but cannot change it', (WidgetTester tester) async {
      await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: _overrides(schedule: FakeScheduleRepository(exceptions: list)));
      expect(find.text('Holiday'), findsOneWidget);
      expect(find.text('Ramadan'), findsOneWidget);
      expect(find.byKey(const Key('exceptions.add')), findsNothing);
      expect(find.byKey(const Key('exception.delete.x1')), findsNothing);
    });

    testWidgets('the admin adds a holiday in two steps', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository();
      await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: _overrides(carpools: _carpools(admin: true), schedule: schedule));
      expect(find.byKey(const Key('exceptions.empty')), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Add day off or time'));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 2'), findsOneWidget);
      await _tapInSheet(tester, 'ex.next');
      expect(find.text('Step 2 of 2'), findsOneWidget);
      await _tapInSheet(tester, 'ex.save');
      expect(schedule.savedException?.kind, ExceptionKind.noSchool);
      expect(schedule.savedException?.reason, ExceptionReason.holiday);
      expect(ScheduleDates.key(schedule.savedException!.from), '2026-11-14');
      expect(find.text('Saved; the group is told'), findsOneWidget);
    });

    testWidgets('Ramadan times need at least one new time before saving', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository();
      await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: _overrides(carpools: _carpools(admin: true), schedule: schedule));
      await tester.tap(find.widgetWithText(AppButton, 'Add day off or time'));
      await tester.pumpAndSettle();
      await _tapInSheet(tester, 'ex.kind.times');
      await _tapInSheet(tester, 'ex.reason.ramadan');
      await _tapInSheet(tester, 'ex.next');
      expect(find.byKey(const Key('ex.timesError')), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const Key('ex.save'))).onPressed, isNull);
      // The morning list opens near its top (As usual), so 08:30 is on screen.
      await _tapInSheet(tester, 'ex.morning');
      await tester.tap(find.text('08:30').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ex.timesError')), findsNothing);
      await _tapInSheet(tester, 'ex.save');
      expect(schedule.savedException?.kind, ExceptionKind.times);
      expect(schedule.savedException?.reason, ExceptionReason.ramadan);
      expect(schedule.savedException?.morning, '08:30');
      expect(schedule.savedException?.afternoon, isNull);
    });

    testWidgets('removing asks first', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(exceptions: list);
      await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: _overrides(carpools: _carpools(admin: true), schedule: schedule));
      await _tapInList(tester, 'exception.delete.x1');
      expect(find.text('Remove this change?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(schedule.calls, contains('deleteException:x1'));
      expect(find.text('Removed'), findsOneWidget);
    });
  });

  group('drive balance (F37)', () {
    testWidgets('runs driven and received per family; the family that drove least has a badge', (WidgetTester tester) async {
      final FakeScheduleRepository schedule = FakeScheduleRepository(
        balance: const DriveBalance(
          termId: '2026-t1',
          families: <FamilyBalance>[
            FamilyBalance(uid: 'p1', firstName: 'Hoda', driven: 6, received: 2),
            FamilyBalance(uid: 'uid-1', firstName: 'Mona', driven: 2, received: 6),
          ],
        ),
      );
      await _pump(tester, CarpoolRoutes.balance('k1'), overrides: _overrides(schedule: schedule));
      expect(find.text('Drive balance'), findsOneWidget);
      expect(find.text('Mona (you)'), findsOneWidget);
      expect(find.text('Drove 2 · Rode 6'), findsOneWidget);
      expect(find.text('Drove 6 · Rode 2'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('balance.uid-1')), matching: find.text('Drove least')), findsOneWidget);
      expect(find.byKey(const Key('balance.none')), findsNothing);
    });

    testWidgets('no runs yet: every family at zero and a note', (WidgetTester tester) async {
      await _pump(tester, CarpoolRoutes.balance('k1'), overrides: _overrides());
      expect(find.byKey(const Key('balance.none')), findsOneWidget);
      expect(find.text('Drove 0 · Rode 0'), findsNWidgets(2));
      expect(find.text('Drove least'), findsNothing);
    });
  });

  group('carpool detail links', () {
    testWidgets('members open the week plan from the carpool', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, CarpoolRoutes.detail('k1'), overrides: _overrides());
      expect(find.text('Schedule'), findsOneWidget);
      await _tapInList(tester, 'detail.schedule');
      expect(_path(router), '/carpools/k1/schedule');
      expect(find.text('Week plan'), findsWidgets);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;
      for (final double scale in <double>[1, 2]) {
        testWidgets('[$lang] week plan, run sheet, days off and balance at text x$scale', (WidgetTester tester) async {
          final bool normal = scale == 1;
          final FakeScheduleRepository schedule = FakeScheduleRepository(
            weeks: <String, List<ScheduleRun>>{_week: _fullWeek()},
            exceptions: <ScheduleException>[
              ScheduleException(id: 'x1', kind: ExceptionKind.noSchool, reason: ExceptionReason.early, from: DateTime(2026, 11, 19), to: DateTime(2026, 11, 19)),
            ],
            balance: const DriveBalance(termId: '2026-t1', families: <FamilyBalance>[FamilyBalance(uid: 'uid-1', firstName: 'Mona', driven: 1, received: 0)]),
          );
          void check(String where) {
            expectOneLine(find.byType(AppBarTitle), '$where title');
            expectOneLine(find.byType(AppButton), '$where buttons', allowEllipsis: !normal);
            expectOneLine(find.byType(AppSectionHeader), '$where sections', allowEllipsis: !normal);
            expectOneLine(find.byType(AppChip), '$where chips', allowEllipsis: !normal);
            expectOneLine(find.byType(AppStatusBadge), '$where badges', allowEllipsis: !normal);
          }

          final List<Override> overrides = _overrides(carpools: _carpools(admin: true), schedule: schedule);
          await _pump(tester, _schedule(), overrides: overrides, locale: locale, width: 320, height: 3200, textScale: scale);
          check('week plan');
          expectOneLine(find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)), 'run rows', allowEllipsis: !normal);

          await _tapInList(tester, 'schedule.run.2026-11-15_am');
          check('run sheet');
          expectOneLine(find.descendant(of: find.byKey(const Key('run.absent.c1')), matching: find.byType(OneLineText)), 'absent switch', allowEllipsis: !normal);

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, CarpoolRoutes.exceptions('k1'), overrides: overrides, locale: locale, width: 320, height: 3200, textScale: scale);
          check('days off');
          await tester.tap(find.byKey(const Key('exceptions.add')));
          await tester.pumpAndSettle();
          check('add step 1');
          await _tapInSheet(tester, 'ex.kind.times');
          await _tapInSheet(tester, 'ex.next');
          check('add step 2');

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, CarpoolRoutes.balance('k1'), overrides: overrides, locale: locale, width: 320, height: 3200, textScale: scale);
          check('balance');
        });
      }

      testWidgets('[$lang] every schedule badge, chip and title fits at 320 dp', (WidgetTester tester) async {
        tester.view
          ..devicePixelRatio = 2
          ..physicalSize = const Size(640, 2400);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          buildTestApp(
            Builder(
              builder: (BuildContext context) {
                final AppLocalizations l10n = context.l10n;
                final List<String> labels = <String>[
                  l10n.runPlanned,
                  l10n.runConfirmed,
                  l10n.runSwapAsked,
                  l10n.runNeedsDriver,
                  l10n.runOwnTrip,
                  l10n.runNoSchool,
                  l10n.runDone,
                  l10n.balanceLeast,
                  l10n.scheduleThisWeek,
                  l10n.scheduleNextWeek,
                  l10n.exceptionKindNoSchool,
                  l10n.exceptionKindTimes,
                  l10n.exReasonHoliday,
                  l10n.exReasonExams,
                  l10n.exReasonEarly,
                  l10n.exReasonRamadan,
                  l10n.exReasonOther,
                  l10n.scheduleToSchool('07:30'),
                  l10n.scheduleToHome('14:30'),
                  l10n.scheduleConfirm,
                  l10n.scheduleCantDrive,
                  l10n.scheduleTake,
                  l10n.scheduleTakeBack,
                  l10n.schedulePlan,
                  l10n.scheduleMyDays,
                  l10n.exceptionsAdd,
                  l10n.scheduleWeekPlan,
                  l10n.scheduleExceptions,
                  l10n.scheduleBalance,
                  l10n.scheduleAbsentChild('Mohamed'),
                  l10n.scheduleSwapTitle,
                  l10n.scheduleTakeTitle,
                  l10n.exceptionDeleteTitle,
                ];
                return Scaffold(
                  body: ListView(
                    padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                    children: <Widget>[
                      for (int i = 0; i < labels.length; i++)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: AppStatusBadge(key: Key('label.$i'), label: labels[i]),
                        ),
                    ],
                  ),
                );
              },
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expectOneLine(find.byType(AppStatusBadge), 'schedule labels', requireText: true);
      });
    }
  });
}
