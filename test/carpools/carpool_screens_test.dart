// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_search_screen.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/carpool_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/map_fakes.dart';
import '../helpers/one_line.dart';
import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

const ChildRecord _adam = ChildRecord(
  id: 'c1',
  firstName: 'Adam',
  age: 8,
  grade: Grade.g3,
  schoolName: 'Nile International School',
  status: ReviewStatus.approved,
  schoolId: 'nile',
);

const ChildRecord _jana = ChildRecord(
  id: 'c2',
  firstName: 'Jana',
  age: 6,
  grade: Grade.g1,
  schoolName: 'Nile International School',
  status: ReviewStatus.approved,
  schoolId: 'nile',
);

final VehicleRecord _car = VehicleRecord(
  plate: 'ABC 123',
  model: 'Test car',
  color: 'White',
  seats: 3,
  licenseExpiry: DateTime(2030),
  carLicenseExpiry: DateTime(2030),
  status: ReviewStatus.approved,
);

const CarpoolMember _hoda = CarpoolMember(
  uid: 'p1',
  firstName: 'Hoda',
  isAdmin: true,
  children: <CarpoolChild>[CarpoolChild(id: 'h1', firstName: 'Laila', grade: Grade.g2)],
);

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides({
  FakeCarpoolRepository? carpools,
  FakeLinkSharer? sharer,
  SessionState session = testVerifiedSession,
  List<ChildRecord> children = const <ChildRecord>[_adam],
  VehicleRecord? vehicle,
  SettingsStore? store,
  FakeMapRepository? maps,
}) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(store ?? InMemorySettingsStore()),
  ...authOverrides(session: session, carpools: carpools, sharer: sharer, maps: maps),
  verificationRepositoryProvider.overrideWithValue(FakeVerificationRepository()),
  childrenProvider.overrideWith((Ref ref) => Stream<List<ChildRecord>>.value(children)),
  vehicleProvider.overrideWith((Ref ref) => Stream<VehicleRecord?>.value(vehicle)),
];

/// Opens [location] in the real router (no session gate) so screens can navigate.
Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  List<Override>? overrides,
  Locale locale = AppLocales.english,
  double width = 400,
  double height = 1400,
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
      overrides: overrides ?? _overrides(),
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.light(DesignDirection.a),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

Future<void> _tapVisible(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  // Lazy lists build a little beyond the screen: bring it fully on screen.
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('Carpools tab', () {
    testWidgets('with no carpools it offers Find, Start and Looking for one', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, AppTab.carpools.path);
      expect(find.byKey(const Key('carpools.empty')), findsOneWidget);
      expect(find.text('No carpools yet'), findsOneWidget);
      expect(find.byKey(const Key('carpools.create')), findsOneWidget);
      expect(find.byKey(const Key('carpools.looking')), findsOneWidget);
      await tester.tap(find.byKey(const Key('carpools.find')));
      await tester.pumpAndSettle();
      expect(_path(router), CarpoolRoutes.search);
    });

    testWidgets('shows my carpools with Requested and Admin badges and opens one', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository(
        memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.requested)],
      );
      final GoRouter router = await _pump(tester, AppTab.carpools.path, overrides: _overrides(carpools: carpools));
      expect(find.byKey(const Key('carpools.mine.k1')), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Nile International School'), findsOneWidget);
      expect(find.text('No smoking'), findsOneWidget);
      expect(find.text('EGP 50/child/week'), findsOneWidget);
      await tester.tap(find.byKey(const Key('carpools.mine.k1')));
      await tester.pumpAndSettle();
      expect(_path(router), '/carpools/k1');
    });

    testWidgets('an invite that arrived before verification waits here', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{PendingInvite.storageKey: 'ABCDEFGH23'});
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      final GoRouter router = await _pump(tester, AppTab.carpools.path, overrides: _overrides(carpools: carpools, store: store));
      expect(find.byKey(const Key('carpools.pendingInvite')), findsOneWidget);
      await tester.tap(find.byKey(const Key('carpools.openInvite')));
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('open:ABCDEFGH23'));
      expect(_path(router), '/carpools/k1');
      expect(store.read(PendingInvite.storageKey), isNull);
    });

    testWidgets('offline and error states', (WidgetTester tester) async {
      await _pump(
        tester,
        AppTab.carpools.path,
        overrides: <Override>[
          ..._overrides(),
          myMembershipsProvider.overrideWith((Ref ref) => Stream<List<Membership>>.error(const CarpoolFailure(CarpoolFailureKind.offline))),
        ],
      );
      expect(find.byType(OfflineStateView), findsOneWidget);
    });
  });

  group('search (F5, F6, F36)', () {
    testWidgets('searches the child school and shows rules, contribution and free seats', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      final GoRouter router = await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: carpools));
      expect(carpools.searches.single.schoolId, 'nile');
      expect(carpools.searches.single.kind, CarpoolKind.school);
      expect(find.byKey(const Key('search.result.k1')), findsOneWidget);
      expect(find.text('3 seats free'), findsOneWidget);
      expect(find.text('Seat belts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('search.result.k1')));
      await tester.pumpAndSettle();
      expect(_path(router), '/carpools/k1');
    });

    testWidgets('filters by area and morning time', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: carpools));
      await tester.tap(find.byKey(const Key('search.areaChip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search.area.degla')));
      await tester.pumpAndSettle();
      expect(carpools.searches.last.areaId, 'degla');
      await tester.tap(find.byKey(const Key('search.timeChip')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('search.time.07:30')), 100, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.byKey(const Key('search.time.07:30')));
      await tester.pumpAndSettle();
      expect(carpools.searches.last.morning, '07:30');
      expect(find.text('In 07:30'), findsWidgets);
    });

    testWidgets('activities search near home (F39)', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: carpools));
      await tester.tap(find.byKey(const Key('search.targetChip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search.target.__activity')));
      await tester.pumpAndSettle();
      expect(carpools.searches.last.kind, CarpoolKind.activity);
      expect(carpools.searches.last.radiusKm, 5);
      expect(find.byKey(const Key('search.radiusChip')), findsOneWidget);
    });

    testWidgets('nothing found offers Start a carpool; offline and too many tries', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository(results: const <Carpool>[]);
      final GoRouter router = await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: carpools));
      expect(find.byKey(const Key('search.empty')), findsOneWidget);
      await tester.tap(find.text('Start a carpool'));
      await tester.pumpAndSettle();
      expect(_path(router), CarpoolRoutes.create);

      await tester.pumpWidget(const SizedBox());
      final FakeCarpoolRepository offline = FakeCarpoolRepository()..searchFailure = const CarpoolFailure(CarpoolFailureKind.offline);
      await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: offline));
      expect(find.byType(OfflineStateView), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      final FakeCarpoolRepository limited = FakeCarpoolRepository()..searchFailure = const CarpoolFailure(CarpoolFailureKind.rateLimited);
      await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: limited));
      expect(find.byKey(const Key('search.message')), findsOneWidget);
    });

    testWidgets("the nearby card's Join opens that parent's carpools (F22)", (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      final GoRouter router = await _pump(
        tester,
        HomeRoutes.nearby,
        overrides: _overrides(carpools: carpools, maps: FakeMapRepository(home: const HomeLocation(location: testHome))),
      );
      await tester.tap(find.byKey(const Key('map.area.p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('parent.join')));
      await tester.pumpAndSettle();
      expect(_path(router), CarpoolRoutes.search);
      expect(find.byType(CarpoolSearchScreen), findsOneWidget);
      expect(carpools.searches.last.parentUid, 'p1');
      expect(carpools.searches.last.schoolId, 'nile');
      expect(find.byKey(const Key('search.parentChip')), findsOneWidget);
    });
  });

  group('create (F5, F25, F36)', () {
    testWidgets('four steps with progress; seats never above the car; sends the draft', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      final GoRouter router = await _pump(
        tester,
        CarpoolRoutes.create,
        overrides: _overrides(carpools: carpools, vehicle: _car, children: const <ChildRecord>[_adam, _jana]),
      );
      expect(find.text('Step 1 of 4'), findsOneWidget);
      // Next without a school says what to fix.
      await _tapVisible(tester, 'create.next');
      expect(find.text('Pick the school.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('create.school')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nile International School').last);
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'create.next');

      expect(find.text('Step 2 of 4'), findsOneWidget);
      // Turning both runs off is refused.
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Afternoon run'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'create.next');
      expect(find.byKey(const Key('create.stepError')), findsOneWidget);
      await tester.tap(find.text('Morning run'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'create.next');

      expect(find.text('Step 3 of 4'), findsOneWidget);
      await _tapVisible(tester, 'create.child.c1');
      await _tapVisible(tester, 'create.child.c2');
      await tester.tap(find.byKey(const Key('create.seats')));
      await tester.pumpAndSettle();
      // The car has 3 passenger seats: no 4th choice.
      expect(find.text('4 seats'), findsNothing);
      await tester.tap(find.text('2 seats').last);
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'create.driveDay.sun');
      await _tapVisible(tester, 'create.next');

      expect(find.text('Step 4 of 4'), findsOneWidget);
      await _tapVisible(tester, 'create.rule.no_smoking');
      await _tapVisible(tester, 'create.contribution');
      await tester.enterText(find.byKey(const Key('create.amount')), '50');
      await tester.pumpAndSettle();
      await _tapVisible(tester, 'create.next');

      final CarpoolDraft? draft = carpools.created;
      expect(draft, isNotNull);
      expect(draft!.schoolId, 'nile');
      expect(draft.morning, '07:30');
      expect(draft.afternoon, isNull);
      expect(draft.days, Weekday.schoolDays);
      expect(draft.driveDays, <Weekday>[Weekday.sun]);
      expect(draft.seats, 2);
      expect(draft.childIds.toSet(), <String>{'c1', 'c2'});
      expect(draft.rules, <CarpoolRule>[CarpoolRule.noSmoking]);
      expect(draft.contribution?.amount, 50);
      expect(draft.contribution?.period, ContributionPeriod.week);
      expect(_path(router), '/carpools/new1');
      expect(find.text('Carpool created'), findsOneWidget);
    });

    testWidgets('without an approved car it says so and leads to Profile', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, '${CarpoolRoutes.create}?school=nile', overrides: _overrides());
      await _tapVisible(tester, 'create.next');
      await _tapVisible(tester, 'create.next');
      expect(find.byKey(const Key('create.noCar')), findsOneWidget);
      await _tapVisible(tester, 'create.addCar');
      expect(_path(router), ProfileRoutes.driving);
    });

    testWidgets('without an approved child it asks to add one', (WidgetTester tester) async {
      await _pump(tester, CarpoolRoutes.create, overrides: _overrides(children: const <ChildRecord>[]));
      expect(find.byKey(const Key('create.noChild')), findsOneWidget);
    });

    testWidgets('a server refusal shows inline above the button', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository()..failure = const CarpoolFailure(CarpoolFailureKind.carTooSmall);
      await _pump(tester, '${CarpoolRoutes.create}?school=nile', overrides: _overrides(carpools: carpools, vehicle: _car));
      await _tapVisible(tester, 'create.next');
      await _tapVisible(tester, 'create.next');
      await _tapVisible(tester, 'create.child.c1');
      await _tapVisible(tester, 'create.next');
      await _tapVisible(tester, 'create.next');
      expect(find.byKey(const Key('create.saveError')), findsOneWidget);
      expect(find.text('More seats than your car has.'), findsOneWidget);
    });
  });

  group('detail and joining (F6, F25, F36)', () {
    testWidgets('a non-member sees rules and contribution, and asks to join accepting both', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools, children: const <ChildRecord>[_adam, _jana]));
      expect(find.text('Nile International School'), findsOneWidget);
      expect(find.text('Started by Hoda'), findsOneWidget);
      expect(find.text('No smoking'), findsOneWidget);
      expect(find.text('EGP 50/child/week'), findsOneWidget);
      // Members and children are for members only.
      expect(find.text('Members'), findsNothing);

      await _tapVisible(tester, 'detail.join');
      expect(find.byKey(const Key('join.noChildren')), findsNothing);
      await tester.tap(find.byKey(const Key('join.child.c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join.rules')));
      await tester.pumpAndSettle();
      final AppButton send = tester.widget<AppButton>(find.byKey(const Key('join.send')));
      expect(send.onPressed, isNull, reason: 'the contribution must be accepted too');
      await tester.tap(find.byKey(const Key('join.contribution')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join.send')));
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('join:k1:c1:true'));
      expect(find.text('Request sent'), findsOneWidget);
      expect(find.byKey(const Key('detail.cancelRequest')), findsOneWidget);
    });

    testWidgets('children that do not fit the free seats are refused as the parent picks', (WidgetTester tester) async {
      const Carpool tight = Carpool(
        id: 'k1',
        kind: CarpoolKind.school,
        schoolId: 'nile',
        schoolNameAr: 'النيل',
        schoolNameEn: 'Nile',
        areaNameAr: '',
        areaNameEn: '',
        activityName: '',
        activityLabel: '',
        morning: '07:30',
        afternoon: null,
        days: Weekday.schoolDays,
        seats: 2,
        childrenCount: 1,
        memberCount: 1,
        rules: <CarpoolRule>[],
        contribution: null,
        creatorFirstName: 'Hoda',
      );
      await _pump(
        tester,
        '/carpools/k1',
        overrides: _overrides(carpools: FakeCarpoolRepository(carpools: <Carpool>[tight]), children: const <ChildRecord>[_adam, _jana]),
      );
      await _tapVisible(tester, 'detail.join');
      expect(find.byKey(const Key('join.noChildren')), findsNothing);
      await tester.tap(find.byKey(const Key('join.child.c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join.child.c2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('join.seatError')), findsOneWidget);
      expect(find.text('Only 1 seat is free.'), findsOneWidget);
    });

    testWidgets('a requested parent cancels after confirming', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository(
        memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.requested)],
      );
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools));
      await _tapVisible(tester, 'detail.cancelRequest');
      expect(find.text('Cancel request?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Cancel request').last);
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('cancel:k1'));
      expect(find.byKey(const Key('detail.join')), findsOneWidget);
    });
  });

  group('members and driver consent (F26)', () {
    FakeCarpoolRepository memberRepo({List<DriverConsent> consents = const <DriverConsent>[], bool admin = false}) => FakeCarpoolRepository(
      memberships: <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved, isAdmin: admin)],
      members: const <CarpoolMember>[_hoda, testMe],
      consents: consents,
      requests: const <JoinRequest>[
        JoinRequest(uid: 'p2', firstName: 'Tarek', children: <CarpoolChild>[CarpoolChild(id: 't1', firstName: 'Omar', grade: Grade.kg2)]),
      ],
    );

    testWidgets("members show children's first names and grades and who can drive", (WidgetTester tester) async {
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: memberRepo()));
      expect(find.text('Members'), findsOneWidget);
      expect(find.text('Laila, Grade 2'), findsOneWidget);
      expect(find.text('Mona (you)'), findsOneWidget);
      // Hoda has no car in this fake; nobody can drive yet.
      expect(find.text('No car'), findsWidgets);
      // Not the admin: no requests section.
      expect(find.text('Join requests'), findsNothing);
    });

    testWidgets('Pay contribution (F25, F43) opens Send with the agreed amount for my children; nothing is sent', (WidgetTester tester) async {
      // testCarpool: 50 EGP per child a week; testMe (Mona) has one child.
      final GoRouter router = await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: memberRepo()));
      await _tapVisible(tester, 'detail.payContribution');
      final Uri uri = router.routerDelegate.currentConfiguration.uri;
      expect(uri.path, '${ProfileRoutes.wallet}/${WalletRoutes.sendSegment}');
      expect(uri.queryParameters, <String, String>{'carpool': 'k1', 'amount': '5000'});
    });

    testWidgets('accepting a driver asks first, says to meet, and can be withdrawn', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = memberRepo();
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools));
      await _tapVisible(tester, 'detail.consent.p1');
      expect(find.text('Accept Hoda?'), findsOneWidget);
      expect(find.text('Meet Hoda before the first ride. You can withdraw any time.'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Accept'));
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('consent:p1:true'));
      expect(find.text('Can drive my children'), findsOneWidget);

      await _tapVisible(tester, 'detail.consent.p1');
      expect(find.text('Withdraw consent?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Withdraw'));
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('consent:p1:false'));
      expect(find.text('Meet before the first ride'), findsOneWidget);
    });

    testWidgets('the admin approves and declines join requests', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = memberRepo(admin: true);
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools));
      expect(find.text('Join requests'), findsOneWidget);
      expect(find.text('Omar, KG2'), findsOneWidget);
      await _tapVisible(tester, 'detail.approve.p2');
      expect(carpools.calls, contains('decide:p2:true'));
      expect(find.byKey(const Key('detail.requestsEmpty')), findsOneWidget);
    });

    testWidgets('invite parents shares a link by WhatsApp or copies it (F31)', (WidgetTester tester) async {
      final FakeLinkSharer sharer = FakeLinkSharer();
      await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: memberRepo(), sharer: sharer));
      await _tapVisible(tester, 'detail.invite');
      expect(find.text('https://links.example/c/ABCDEFGH23'), findsOneWidget);
      await tester.tap(find.byKey(const Key('invite.whatsapp')));
      await tester.pumpAndSettle();
      expect(sharer.shared.single, 'Join our school carpool: https://links.example/c/ABCDEFGH23');
      sharer.whatsAppOpens = false;
      await tester.tap(find.byKey(const Key('invite.whatsapp')));
      await tester.pumpAndSettle();
      expect(sharer.copied, <String>['https://links.example/c/ABCDEFGH23']);
      expect(find.text('Link copied'), findsOneWidget);
    });

    testWidgets('leaving asks first and goes back to Carpools', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = memberRepo();
      final GoRouter router = await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools));
      await _tapVisible(tester, 'detail.leave');
      expect(find.text('Leave carpool?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'Leave carpool').last);
      await tester.pumpAndSettle();
      expect(carpools.calls, contains('leave:k1'));
      expect(_path(router), AppTab.carpools.path);
    });

    testWidgets('a carpool that does not exist says so', (WidgetTester tester) async {
      await _pump(tester, '/carpools/nope');
      expect(find.byKey(const Key('detail.notFound')), findsOneWidget);
    });
  });

  group('invite links (F31)', () {
    testWidgets('a verified parent goes straight to the carpool', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      // The shared link /c/<code> leads to the invite screen in the Carpools tab.
      final GoRouter router = await _pump(tester, CarpoolRoutes.link('abcdefgh23'), overrides: _overrides(carpools: carpools));
      expect(carpools.calls, contains('open:ABCDEFGH23'));
      expect(_path(router), '/carpools/k1');
    });

    testWidgets('a parent who is not verified sees nothing but "Verify first", and the code waits', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      final InMemorySettingsStore store = InMemorySettingsStore();
      await _pump(
        tester,
        CarpoolRoutes.link('ABCDEFGH23'),
        overrides: _overrides(carpools: carpools, session: testUnverifiedSession, store: store),
      );
      expect(find.byKey(const Key('invite.verifyFirst')), findsOneWidget);
      expect(carpools.calls, isEmpty);
      expect(find.text('Nile International School'), findsNothing);
      expect(store.read(PendingInvite.storageKey), 'ABCDEFGH23');
    });

    testWidgets('an expired code says so', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository()..failure = const CarpoolFailure(CarpoolFailureKind.inviteInvalid);
      await _pump(tester, CarpoolRoutes.invite('ABCDEFGH23'), overrides: _overrides(carpools: carpools));
      expect(find.byKey(const Key('invite.invalid')), findsOneWidget);
    });
  });

  group('looking for a carpool (F32)', () {
    const WantedList three = WantedList(
      posts: <WantedPost>[
        WantedPost(id: 'uid-1', firstName: 'Mona', days: <Weekday>[Weekday.sun], childrenCount: 1, morning: '07:30', mine: true),
        WantedPost(id: 'p1', firstName: 'Hoda', days: <Weekday>[Weekday.sun], childrenCount: 2, morning: '07:45', areaNameEn: 'Degla'),
        WantedPost(id: 'p2', firstName: 'Tarek', days: <Weekday>[Weekday.sun], childrenCount: 1, morning: '07:15'),
      ],
      suggestion: WantedSuggestion(families: 3, days: <Weekday>[Weekday.sun], morning: '07:30', areaId: 'degla'),
    );

    testWidgets('three matching families get a suggestion to start a group', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, CarpoolRoutes.looking, overrides: _overrides(carpools: FakeCarpoolRepository(wanted: three)));
      expect(find.text('3 families match'), findsOneWidget);
      expect(find.text('Hoda'), findsOneWidget);
      expect(find.text('2 children'), findsOneWidget);
      await tester.tap(find.byKey(const Key('looking.start')));
      await tester.pumpAndSettle();
      expect(_path(router), CarpoolRoutes.create);
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['morning'], '07:30');
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters['area'], 'degla');
    });

    testWidgets('posting a request sends school, times, days and children', (WidgetTester tester) async {
      final FakeCarpoolRepository carpools = FakeCarpoolRepository();
      await _pump(tester, CarpoolRoutes.looking, overrides: _overrides(carpools: carpools));
      expect(find.byKey(const Key('looking.empty')), findsOneWidget);
      await _tapVisible(tester, 'looking.post');
      await tester.tap(find.byKey(const Key('looking.form.save')));
      await tester.pumpAndSettle();
      final WantedDraft? draft = carpools.savedWanted;
      expect(draft?.schoolId, 'nile');
      expect(draft?.morning, '07:30');
      expect(draft?.days, Weekday.schoolDays);
      expect(draft?.childIds, <String>['c1']);
      expect(find.text('Posted'), findsOneWidget);
    });
  });

  group('one line at 320 dp', () {
    Finder oneLineIn(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(OneLineText));

    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;
      for (final double scale in <double>[1, 2]) {
        testWidgets('[$lang] carpools, search and detail at text x$scale', (WidgetTester tester) async {
          final FakeCarpoolRepository carpools = FakeCarpoolRepository(
            memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved, isAdmin: true)],
            members: const <CarpoolMember>[_hoda, testMe],
            requests: const <JoinRequest>[
              JoinRequest(uid: 'p2', firstName: 'Tarek', children: <CarpoolChild>[CarpoolChild(id: 't1', firstName: 'Omar', grade: Grade.kg2)]),
            ],
          );
          final bool normal = scale == 1;
          void check(String where) {
            expectOneLine(find.byType(AppBarTitle), '$where title');
            // Buttons and titles shrink at 200 percent but never wrap.
            expectOneLine(find.byType(AppButton), '$where buttons', allowEllipsis: !normal);
            expectOneLine(find.byType(AppSectionHeader), '$where sections', allowEllipsis: !normal);
            expectOneLine(find.byType(AppChip), '$where chips', allowEllipsis: !normal);
            expectOneLine(find.byType(AppStatusBadge), '$where badges', allowEllipsis: !normal);
          }

          await _pump(tester, AppTab.carpools.path, overrides: _overrides(carpools: carpools), locale: locale, width: 320, height: 2400, textScale: scale);
          check('carpools tab');
          expectOneLine(find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)), 'rows', allowEllipsis: !normal);

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, CarpoolRoutes.search, overrides: _overrides(carpools: carpools), locale: locale, width: 320, height: 2400, textScale: scale);
          check('search');

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, '/carpools/k1', overrides: _overrides(carpools: carpools), locale: locale, width: 320, height: 4000, textScale: scale);
          check('detail');
          expectOneLine(oneLineIn('detail.consent.p1'), 'consent switch', allowEllipsis: !normal);
          expectOneLine(oneLineIn('detail.pickup'), 'pickup switch', allowEllipsis: !normal);
        });

        testWidgets('[$lang] create steps and looking at text x$scale', (WidgetTester tester) async {
          await _pump(
            tester,
            '${CarpoolRoutes.create}?school=nile',
            overrides: _overrides(vehicle: _car),
            locale: locale,
            width: 320,
            height: 2400,
            textScale: scale,
          );
          final bool normal = scale == 1;
          for (int step = 0; step < 4; step++) {
            expectOneLine(find.byType(AppBarTitle), 'create title');
            expectOneLine(find.byType(AppButton), 'create buttons step $step', allowEllipsis: !normal);
            expectOneLine(find.byType(AppChip), 'create chips step $step', allowEllipsis: !normal);
            expectOneLine(find.byType(AppSectionHeader), 'create section step $step', allowEllipsis: !normal);
            if (step == 2) {
              await _tapVisible(tester, 'create.child.c1');
            }
            if (step == 3) {
              await _tapVisible(tester, 'create.contribution');
              expectOneLine(oneLineIn('create.contribution'), 'contribution switch', allowEllipsis: !normal);
              break;
            }
            await _tapVisible(tester, 'create.next');
          }

          await tester.pumpWidget(const SizedBox());
          await _pump(tester, CarpoolRoutes.looking, overrides: _overrides(), locale: locale, width: 320, height: 2400, textScale: scale);
          expectOneLine(find.byType(AppBarTitle), 'looking title');
          expectOneLine(find.byType(AppButton), 'looking buttons', allowEllipsis: !normal);
          expectOneLine(find.byType(AppSectionHeader), 'looking sections', allowEllipsis: !normal);
        });
      }

      testWidgets('[$lang] every rule, day, period and badge label fits a chip at 320 dp', (WidgetTester tester) async {
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
                  l10n.ruleNoSmoking,
                  l10n.ruleMothersOnly,
                  l10n.ruleSeatBelts,
                  l10n.ruleChildSeats,
                  l10n.ruleWait5Min,
                  l10n.ruleNoPhone,
                  l10n.ruleNoFood,
                  l10n.ruleGirlsOnly,
                  l10n.carpoolAnyArea,
                  l10n.carpoolAnyTime,
                  l10n.carpoolActivities,
                  l10n.carpoolOnlyParent('Mohamed'),
                  l10n.carpoolKindSchool,
                  l10n.carpoolKindActivity,
                  l10n.driverCanDrive,
                  l10n.driverNoCar,
                  l10n.driverCarExpired,
                  l10n.driverCarTooSmall,
                  l10n.driverNeedsConsent,
                  l10n.carpoolRequested,
                  l10n.carpoolAdmin,
                  l10n.carpoolFull,
                  l10n.carpoolSeatsLeft(8),
                  l10n.contributionPerMonth(10000),
                  l10n.contributionNone,
                  l10n.lookingChildren(3),
                  l10n.daySat,
                  l10n.dayTue,
                  l10n.dayWed,
                ];
                return Scaffold(
                  body: ListView(
                    children: <Widget>[
                      for (int i = 0; i < labels.length; i++)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Padding(
                            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                            child: AppChip(key: Key('label.$i'), label: labels[i], icon: Icons.rule_rounded),
                          ),
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
        expectOneLine(find.byType(AppChip), 'carpool labels', requireText: true);
      });
    }
  });
}
