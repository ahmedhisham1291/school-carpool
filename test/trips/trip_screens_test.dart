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
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
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
import '../helpers/trip_fakes.dart';
import '../helpers/verification_fakes.dart';

const String _am = '2026-11-14_am';

/// A run of today that starts 30 minutes after [testNow], driven by the
/// signed-in parent (uid-1).
ScheduleRun _today({String driver = 'uid-1', RunStatus status = RunStatus.confirmed}) => ScheduleRun(
  id: _am,
  date: DateTime(2026, 11, 14),
  direction: RunDirection.toSchool,
  time: '10:30',
  status: status,
  driverUid: driver,
  driverFirstName: driver == 'uid-1' ? 'Mona' : 'Hoda',
  riders: const <Rider>[Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1'), Rider(id: 'h1', firstName: 'Laila', parentUid: 'p1')],
  start: DateTime(2026, 11, 14, 10, 30),
  confirmBy: DateTime(2026, 11, 13, 21),
);

FakeCarpoolRepository _carpools() => FakeCarpoolRepository(
  memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved)],
  members: const <CarpoolMember>[
    CarpoolMember(uid: 'uid-1', firstName: 'Mona', children: <CarpoolChild>[CarpoolChild(id: 'c1', firstName: 'Adam', grade: Grade.g3)]),
    CarpoolMember(uid: 'p1', firstName: 'Hoda', isAdmin: true, children: <CarpoolChild>[CarpoolChild(id: 'h1', firstName: 'Laila', grade: Grade.g2)]),
  ],
);

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides({
  required FakeTripRepository trips,
  FakeLocationTracker? tracker,
  FakeScheduleRepository? schedule,
  FakeCamera? camera,
  List<ChildRecord> children = const <ChildRecord>[],
}) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(carpools: _carpools(), schedule: schedule ?? FakeScheduleRepository(), trips: trips, tracker: tracker),
  verificationRepositoryProvider.overrideWithValue(FakeVerificationRepository()),
  captureLauncherProvider.overrideWithValue((camera ?? FakeCamera()).launch),
  childrenProvider.overrideWith((Ref ref) => Stream<List<ChildRecord>>.value(children)),
  vehicleProvider.overrideWith((Ref ref) => Stream<VehicleRecord?>.value(null)),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required List<Override> overrides,
  Locale locale = AppLocales.english,
  double width = 400,
  double height = 2400,
  double textScale = 1,
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
        theme: AppTheme.build(DesignDirection.a, Brightness.light),
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

Future<void> _tap(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

String _drive() => CarpoolRoutes.drive('k1', _am);
String _follow() => CarpoolRoutes.trip('k1', _am);

void main() {
  setUpAll(loadAppFonts);

  group('driver: before the run (F15, F38)', () {
    testWidgets('explains live location first; the run starts only after Always is allowed', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today(), trip: testTrip());
      final FakeLocationTracker tracker = FakeLocationTracker();
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      expect(find.byKey(const Key('drive.permission')), findsOneWidget);
      expect(find.text('Share your location'), findsOneWidget);
      expect(find.byKey(const Key('drive.start')), findsNothing);
      expect(trips.calls.contains('start'), isFalse);

      await _tap(tester, 'drive.allowLocation');
      expect(find.byKey(const Key('drive.ready')), findsOneWidget);
      expect(find.text('2 children on this run.'), findsOneWidget);

      await _tap(tester, 'drive.start');
      expect(trips.calls, contains('start'));
      expect(tracker.starts, 1);
      expect(tracker.session?.token, 'token-123');
      expect(tracker.session?.uploadUrl, contains('tripLocation'));
      expect(find.text('Run started'), findsOneWidget);
      expect(find.byKey(const Key('drive.stop.c1')), findsOneWidget);
      expect(find.byKey(const Key('drive.stop.h1')), findsOneWidget);
    });

    testWidgets('refused: says to choose Always and opens Settings; no run starts', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today());
      final FakeLocationTracker tracker = FakeLocationTracker(grantOnRequest: TrackerPermission.whileInUse);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      await _tap(tester, 'drive.allowLocation');
      expect(find.textContaining('Always'), findsWidgets);
      expect(find.text('Open Settings'), findsOneWidget);
      await _tap(tester, 'drive.allowLocation');
      expect(tracker.settingsOpened, 1);
      expect(tracker.starts, 0);
      expect(trips.calls.contains('start'), isFalse);
    });

    testWidgets('a random selfie check comes first when the server asks', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(
        run: _today(),
        trip: testTrip(),
        preparation: const TripPreparation(tripId: 'k1_$_am', selfieRequired: true, active: false),
      );
      final FakeCamera camera = FakeCamera();
      final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker, camera: camera));
      expect(find.byKey(const Key('drive.selfie')), findsOneWidget);
      await _tap(tester, 'drive.takeSelfie');
      expect(camera.requests.single.kind, CaptureKind.selfie);
      expect(trips.calls, contains('selfie'));
      expect(find.byKey(const Key('drive.ready')), findsOneWidget);
    });

    testWidgets('a selfie mismatch pauses driving', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(
        run: _today(),
        preparation: const TripPreparation(tripId: 'k1_$_am', selfieRequired: true, active: false),
      )..selfie = SelfieResult.failed;
      final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      await _tap(tester, 'drive.takeSelfie');
      expect(find.byKey(const Key('drive.paused')), findsOneWidget);
      expect(find.byKey(const Key('drive.start')), findsNothing);
    });

    testWidgets('offline and paused when opening', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today())..failure = const TripFailure(TripFailureKind.offline);
      addTearDown(trips.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips));
      expect(find.byType(OfflineStateView), findsOneWidget);
      trips.failure = const TripFailure(TripFailureKind.drivingPaused);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive.paused')), findsOneWidget);
    });
  });

  group('driver: during the run (F16, F20, F35, F41)', () {
    Future<(FakeTripRepository, FakeLocationTracker)> running(WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today(), trip: testTrip());
      final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      await _tap(tester, 'drive.start');
      return (trips, tracker);
    }

    testWidgets('Arrived tells the parents; a second tap repeats it; each tap has its own request ID', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker _) = await running(tester);
      await _tapInList(tester, 'drive.arrived.h1');
      expect(trips.calls, contains('act:h1:arrived'));
      expect(find.text('Parents told'), findsOneWidget);
      trips.trip = testTrip(
        stops: const <TripStop>[
          TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'uid-1', state: StopState.waiting),
          TripStop(childId: 'h1', firstName: 'Laila', parentUid: 'p1', state: StopState.arrived, arrivedCount: 1),
        ],
      );
      trips.emit();
      await tester.pumpAndSettle();
      expect(find.text('Remind again'), findsOneWidget);
      await _tapInList(tester, 'drive.arrived.h1');
      expect(trips.calls.where((String c) => c == 'act:h1:arrived'), hasLength(2));
      expect(trips.requestIds.toSet(), hasLength(2));
    });

    testWidgets('pickup and drop-off; after the last drop-off the phone stops sending location', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker tracker) = await running(tester);
      await _tapInList(tester, 'drive.pickedUp.c1');
      expect(trips.calls, contains('act:c1:pickedUp'));
      trips.trip = testTrip(
        status: TripStatus.ended,
        stops: const <TripStop>[
          TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'uid-1', state: StopState.dropped),
          TripStop(childId: 'h1', firstName: 'Laila', parentUid: 'p1', state: StopState.dropped),
        ],
      );
      trips.emit();
      await tester.pumpAndSettle();
      expect(tracker.stops, 1);
      expect(tracker.session, isNull);
      expect(find.byKey(const Key('drive.done')), findsOneWidget);
    });

    testWidgets('afternoon: the driver sees who may receive each child', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(
        run: _today(),
        trip: testTrip(
          direction: RunDirection.toHome,
          stops: const <TripStop>[
            TripStop(
              childId: 'h1',
              firstName: 'Laila',
              parentUid: 'p1',
              state: StopState.onBoard,
              handover: <HandoverAdult>[HandoverAdult(name: 'Gran', relation: Relation.grandparent)],
            ),
          ],
        ),
      );
      final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      await _tap(tester, 'drive.start');
      expect(find.text('Also: Gran (Grandparent)'), findsOneWidget);
      expect(find.byKey(const Key('drive.dropped.h1')), findsOneWidget);
      expect(find.text('Handed over'), findsWidgets);
    });

    testWidgets('no connection: the tap waits and is sent again with the same request ID', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker _) = await running(tester);
      trips.failOnce = const TripFailure(TripFailureKind.offline);
      await _tapInList(tester, 'drive.pickedUp.c1');
      expect(find.text('Sent when online'), findsOneWidget);
      expect(find.byKey(const Key('drive.queue')), findsOneWidget);
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(trips.calls.where((String c) => c == 'act:c1:pickedUp'), hasLength(2));
      expect(trips.requestIds.toSet(), hasLength(1));
      expect(find.byKey(const Key('drive.queue')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('quick buttons post with one tap; no typing', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker _) = await running(tester);
      await _tapInList(tester, 'drive.quick.late');
      await _tapInList(tester, 'drive.quick.gate');
      await _tapInList(tester, 'drive.quick.allIn');
      expect(trips.calls, containsAll(<String>['quick:late', 'quick:gate', 'quick:allIn']));
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Emergency asks first, then alerts the group and the contact', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker _) = await running(tester);
      await _tapInList(tester, 'drive.emergency');
      expect(find.text('Send emergency alert?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(trips.calls.contains('emergency'), isFalse);
      await _tapInList(tester, 'drive.emergency');
      await tester.tap(find.text('Send alert'));
      await tester.pumpAndSettle();
      expect(trips.calls, contains('emergency'));
      expect(find.text('Alert sent to all'), findsOneWidget);
    });

    testWidgets('Not coming asks first, then tells the parent', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker _) = await running(tester);
      await _tapInList(tester, 'drive.notComing.h1');
      expect(find.text('Laila not coming?'), findsOneWidget);
      await tester.tap(find.text('Not coming').last);
      await tester.pumpAndSettle();
      expect(trips.calls, contains('act:h1:notComing'));
      expect(find.text('Parent told'), findsOneWidget);
    });

    testWidgets('End run asks first; shown only with no child in the car', (WidgetTester tester) async {
      final (FakeTripRepository trips, FakeLocationTracker tracker) = await running(tester);
      await _tapInList(tester, 'drive.end');
      expect(find.text('End the run?'), findsOneWidget);
      await tester.tap(find.text('End run').last);
      await tester.pumpAndSettle();
      expect(trips.calls, contains('end'));
      trips.trip = testTrip(status: TripStatus.ended);
      trips.emit();
      await tester.pumpAndSettle();
      expect(tracker.stops, 1);
      expect(find.byKey(const Key('drive.done')), findsOneWidget);
    });

    testWidgets('End run is hidden while a child is in the car', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(
        run: _today(),
        trip: testTrip(stops: const <TripStop>[TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'uid-1', state: StopState.onBoard)]),
      );
      final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
      addTearDown(trips.dispose);
      addTearDown(tracker.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips, tracker: tracker));
      await _tap(tester, 'drive.start');
      expect(find.byKey(const Key('drive.end')), findsNothing);
    });

    testWidgets('a driver without a face reference is asked to add a photo', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today())..failure = const TripFailure(TripFailureKind.noReference);
      addTearDown(trips.dispose);
      await _pump(tester, _drive(), overrides: _overrides(trips: trips));
      expect(find.byKey(const Key('drive.noPhoto')), findsOneWidget);
      expect(find.byKey(const Key('drive.start')), findsNothing);
    });

    testWidgets('driver buttons are large (at least 64 dp high)', (WidgetTester tester) async {
      await running(tester);
      final Size size = tester.getSize(find.byKey(const Key('drive.pickedUp.c1')));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.driverTouchTarget));
    });
  });

  group('parents: the live run (F15, F33, F34)', () {
    testWidgets('the car on the map, the arrival time, the driver card and the children', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(trip: testTrip(driverUid: 'p1'))
        ..eta = TripEta(stops: <String, DateTime>{'c1': testNow.add(const Duration(minutes: 6)).toUtc()})
        ..cards = const <DriverCard>[
          DriverCard(runId: '2026-11-14_am', direction: RunDirection.toSchool, time: '10:30', driverFirstName: 'Mona', car: TripCar(model: 'Corolla', color: 'White', plate: 'ABC 123')),
        ];
      addTearDown(trips.dispose);
      await _pump(tester, _follow(), overrides: _overrides(trips: trips));
      expect(find.byType(AppMapView), findsOneWidget);
      expect(find.text('Car in about 6 min'), findsOneWidget);
      expect(find.byKey(const Key('trip.driverCard')), findsOneWidget);
      expect(find.text('Corolla, White'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byKey(const Key('trip.child.h1')), findsOneWidget);
    });

    testWidgets('location stopped: a warning; after the run the map goes', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(trip: testTrip(driverUid: 'p1', lastPointAt: testNow.subtract(const Duration(minutes: 5)).toUtc()));
      addTearDown(trips.dispose);
      await _pump(tester, _follow(), overrides: _overrides(trips: trips));
      expect(find.byKey(const Key('trip.stale')), findsOneWidget);
      trips.trip = testTrip(driverUid: 'p1', status: TripStatus.ended);
      trips.emit();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('trip.finished')), findsOneWidget);
      expect(find.byType(AppMapView), findsNothing);
    });

    testWidgets('a parent whose child is not on the run sees nothing', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository();
      addTearDown(trips.dispose);
      await _pump(tester, _follow(), overrides: _overrides(trips: trips));
      expect(find.byKey(const Key('trip.notStarted')), findsOneWidget);
      expect(find.byType(AppMapView), findsNothing);
    });

    testWidgets('afternoon: the receiving parent confirms the child is home (asks first)', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(
        trip: testTrip(
          driverUid: 'p1',
          direction: RunDirection.toHome,
          status: TripStatus.handover,
          stops: const <TripStop>[TripStop(childId: 'c1', firstName: 'Adam', parentUid: 'uid-1', state: StopState.dropped)],
        ),
      );
      addTearDown(trips.dispose);
      await _pump(tester, CarpoolRoutes.trip('k1', '2026-11-14_pm'), overrides: _overrides(trips: trips));
      await _tapInList(tester, 'trip.confirmHome.c1');
      expect(find.text('Is Adam home?'), findsOneWidget);
      await tester.tap(find.text('Child is home').last);
      await tester.pumpAndSettle();
      expect(trips.calls, contains('confirm:c1'));
      expect(find.text('Handover confirmed'), findsOneWidget);
    });
  });

  group('run sheet entry points', () {
    testWidgets('the driver starts today\'s run from the week plan', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(run: _today(), trip: testTrip());
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{'2026-11-14': <ScheduleRun>[_today()]});
      addTearDown(trips.dispose);
      final GoRouter router = await _pump(tester, CarpoolRoutes.schedule('k1'), overrides: _overrides(trips: trips, schedule: schedule));
      await _tapInList(tester, 'schedule.run.$_am');
      await _tap(tester, 'run.startTrip');
      expect(_path(router), _drive());
    });

    testWidgets('a parent with a child on the run follows it', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository(trip: testTrip(driverUid: 'p1'));
      final FakeScheduleRepository schedule = FakeScheduleRepository(weeks: <String, List<ScheduleRun>>{'2026-11-14': <ScheduleRun>[_today(driver: 'p1')]});
      addTearDown(trips.dispose);
      final GoRouter router = await _pump(tester, CarpoolRoutes.schedule('k1'), overrides: _overrides(trips: trips, schedule: schedule));
      await _tapInList(tester, 'schedule.run.$_am');
      await _tap(tester, 'run.followTrip');
      expect(_path(router), _follow());
    });
  });

  group('handover list (F29) and emergency contact (F20)', () {
    testWidgets('add an adult in a sheet; remove asks first', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository();
      addTearDown(trips.dispose);
      await _pump(tester, '${ProfileRoutes.handover}/c1', overrides: _overrides(trips: trips));
      expect(find.byKey(const Key('handover.empty')), findsOneWidget);
      await _tap(tester, 'handover.add');
      await tester.enterText(find.byKey(const Key('adult.name')), 'Gran');
      await tester.pumpAndSettle();
      await _tap(tester, 'adult.relation.grandparent');
      await tester.enterText(find.byKey(const Key('adult.phone')), '123');
      await tester.pumpAndSettle();
      expect(find.text('Enter an Egyptian mobile, e.g. 010 1234 5678.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('adult.phone')), '01012345678');
      await tester.pumpAndSettle();
      await _tap(tester, 'adult.save');
      expect(trips.calls, contains('saveAdults:c1:1'));
      expect(find.text('Gran'), findsOneWidget);
      await _tap(tester, 'handover.remove.Gran');
      expect(find.text('Remove Gran?'), findsOneWidget);
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      expect(trips.calls, contains('saveAdults:c1:0'));
    });

    testWidgets('emergency contact: checked as the parent types, then saved', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository();
      addTearDown(trips.dispose);
      await _pump(tester, ProfileRoutes.emergencyContact, overrides: _overrides(trips: trips));
      await tester.enterText(find.byKey(const Key('contact.name')), 'Sara');
      await tester.enterText(find.byKey(const Key('contact.phone')), '0101');
      await tester.pumpAndSettle();
      expect(find.text('Enter an Egyptian mobile, e.g. 010 1234 5678.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('contact.phone')), '01012345678');
      await _tap(tester, 'contact.relation.sibling');
      await _tap(tester, 'contact.save');
      expect(trips.calls, contains('saveContact:sibling'));
      expect(find.text('Contact saved'), findsOneWidget);
    });

    testWidgets('the group sees emergencies with the car\'s point and can call 123', (WidgetTester tester) async {
      final FakeTripRepository trips = FakeTripRepository()
        ..emergencies = <EmergencyAlert>[EmergencyAlert(id: 'e1', driverFirstName: 'Mona', at: testNow.toUtc(), point: testTrip().last)];
      addTearDown(trips.dispose);
      await _pump(tester, CarpoolRoutes.emergency('k1'), overrides: _overrides(trips: trips));
      expect(find.text('Mona pressed Emergency'), findsOneWidget);
      await _tapInList(tester, 'emergency.call');
      expect(trips.opened.single.toString(), 'tel:123');
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;
      for (final double scale in <double>[1, 2]) {
        testWidgets('[$lang] driver run, live run and data entry at text x$scale', (WidgetTester tester) async {
          final bool normal = scale == 1;
          void check(String where) {
            expectOneLine(find.byType(AppBarTitle), '$where title');
            expectOneLine(find.byType(AppButton), '$where buttons', allowEllipsis: !normal);
            expectOneLine(find.byType(AppSectionHeader), '$where sections', allowEllipsis: !normal);
            expectOneLine(find.byType(AppChip), '$where chips', allowEllipsis: !normal);
            expectOneLine(find.byType(AppStatusBadge), '$where badges', allowEllipsis: !normal);
          }

          final FakeTripRepository trips = FakeTripRepository(run: _today(), trip: testTrip());
          final FakeLocationTracker tracker = FakeLocationTracker();
          addTearDown(trips.dispose);
          addTearDown(tracker.dispose);
          final List<Override> overrides = _overrides(trips: trips, tracker: tracker);
          await _pump(tester, _drive(), overrides: overrides, locale: locale, width: 320, height: 4000, textScale: scale);
          check('location step');
          await _tap(tester, 'drive.allowLocation');
          check('ready step');
          await _tap(tester, 'drive.start');
          check('driver run');

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, _follow(), overrides: overrides, locale: locale, width: 320, height: 4000, textScale: scale);
          check('live run');
          await tester.pumpWidget(const SizedBox());
          await _pump(tester, '${ProfileRoutes.handover}/c1', overrides: overrides, locale: locale, width: 320, height: 4000, textScale: scale);
          check('handover');
          await tester.pumpWidget(const SizedBox());
          await _pump(tester, ProfileRoutes.emergencyContact, overrides: overrides, locale: locale, width: 320, height: 4000, textScale: scale);
          check('emergency contact');
        });
      }

      testWidgets('[$lang] every trip label fits on one line', (WidgetTester tester) async {
        tester.view
          ..devicePixelRatio = 2
          ..physicalSize = const Size(640, 4800);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          buildTestApp(
            Builder(
              builder: (BuildContext context) {
                final AppLocalizations l10n = context.l10n;
                final List<String> labels = <String>[
                  l10n.tripStart,
                  l10n.tripStartOpen,
                  l10n.tripFollow,
                  l10n.tripLocationTurnOn,
                  l10n.tripSelfieTake,
                  l10n.tripActionArrived,
                  l10n.tripActionArrivedAgain,
                  l10n.tripActionPickedUp,
                  l10n.tripActionAtSchool,
                  l10n.tripActionDropped,
                  l10n.tripActionNotComing,
                  l10n.tripActionArrivedSent,
                  l10n.tripNotComingTitle('Mohamed'),
                  l10n.tripEnd,
                  l10n.tripEndTitle,
                  l10n.tripEnded,
                  l10n.tripNoPhotoTitle,
                  l10n.tripAddPhoto,
                  l10n.tripNotComingSent,
                  l10n.notifNotComingTitle,
                  l10n.tripQuickLate,
                  l10n.tripQuickGate,
                  l10n.tripQuickAllIn,
                  l10n.tripEmergency,
                  l10n.tripEmergencySend,
                  l10n.tripEmergencyTitle,
                  l10n.tripConfirmHome,
                  l10n.tripConfirmHomeTitle('Mohamed'),
                  l10n.tripOpenDriver,
                  l10n.tripDoneAction,
                  l10n.tripStopWaiting,
                  l10n.tripStopArrived,
                  l10n.tripStopOnBoard,
                  l10n.tripStopAtSchool,
                  l10n.tripStopDropped,
                  l10n.tripStopReceived,
                  l10n.tripStopAbsent,
                  l10n.tripLocationWaiting,
                  l10n.tripLocationLive,
                  l10n.tripLocationStale,
                  l10n.tripLocationOff,
                  l10n.tripDriveTitle,
                  l10n.tripTitle,
                  l10n.tripTodaySection,
                  l10n.tripQuickSection,
                  l10n.tripChildrenSection,
                  l10n.tripMessagesSection,
                  l10n.tripDoneTitle,
                  l10n.tripNotStartedTitle,
                  l10n.tripPausedTitle,
                  l10n.tripProgress(3, 4),
                  l10n.handoverTitle,
                  l10n.handoverEditTitle,
                  l10n.handoverAdd,
                  l10n.handoverRemove,
                  l10n.handoverRemoveTitle('Mohamed'),
                  l10n.handoverPhoneLabel,
                  l10n.handoverRelationLabel,
                  l10n.emergencyContactTitle,
                  l10n.emergencyContactRemove,
                  l10n.emergencyContactRemoveTitle,
                  l10n.emergencyTitle,
                  l10n.emergencyFrom('Mohamed'),
                  l10n.emergencyOpenMap,
                  l10n.emergencyCallAmbulance,
                  l10n.emergencyNoneTitle,
                  l10n.relationMother,
                  l10n.relationFather,
                  l10n.relationGrandparent,
                  l10n.relationSibling,
                  l10n.relationRelative,
                  l10n.relationNanny,
                  l10n.relationOther,
                  l10n.driverPhotoTitle,
                  l10n.captureDriverPhotoTitle,
                  l10n.notifGroupEmergency,
                  l10n.notifGroupTripAlerts,
                  l10n.notifGroupTrips,
                  l10n.notifTripStartedTitle,
                  l10n.notifDriverArrivedTitle,
                  l10n.notifPickedUpTitle,
                  l10n.notifDroppedTitle,
                  l10n.notifReceivedTitle,
                  l10n.notifLocationStoppedTitle,
                  l10n.notifEmergencyTitle,
                  l10n.tripEmergencySentAll,
                  l10n.tripEmergencySentGroup,
                  l10n.tripQueued,
                  l10n.tripArrivedSent,
                  l10n.tripConfirmedHome,
                  l10n.emergencyContactSaved,
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
        expectOneLine(find.byType(AppStatusBadge), 'trip labels', requireText: true);
      });
    }
  });
}
