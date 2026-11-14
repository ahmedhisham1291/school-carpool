// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:run_recovery/run_recovery.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/run_recovery.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/carpool_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/schedule_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/trip_fakes.dart';

const String _am = '2026-11-14_am';

ScheduleRun _today() => ScheduleRun(
  id: _am,
  date: DateTime(2026, 11, 14),
  direction: RunDirection.toSchool,
  time: '10:30',
  status: RunStatus.confirmed,
  driverUid: 'uid-1',
  driverFirstName: 'Mona',
  riders: const <Rider>[Rider(id: 'c1', firstName: 'Adam', parentUid: 'uid-1')],
  start: DateTime(2026, 11, 14, 10, 30),
  confirmBy: DateTime(2026, 11, 13, 21),
);

class _RecordingSink implements AnalyticsSink {
  final List<(String, Map<String, Object>)> events = <(String, Map<String, Object>)>[];

  @override
  Future<void> event(String name, Map<String, Object> parameters) async => events.add((name, parameters));

  @override
  Future<void> screen(String name) async {}

  @override
  Future<void> setEnabled(bool enabled) async {}
}

void main() {
  setUpAll(loadAppFonts);

  Future<(FakeTripRepository, FakeLocationTracker, InMemorySettingsStore, _RecordingSink)> pump(
    WidgetTester tester,
    FakeRecoveryNative native, {
    Locale locale = AppLocales.english,
    double width = 400,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    final FakeTripRepository trips = FakeTripRepository(run: _today(), trip: testTrip());
    final FakeLocationTracker tracker = FakeLocationTracker();
    final InMemorySettingsStore store = InMemorySettingsStore();
    final _RecordingSink sink = _RecordingSink();
    addTearDown(trips.dispose);
    addTearDown(tracker.dispose);
    tester.view
      ..devicePixelRatio = 2
      ..physicalSize = Size(width * 2, 2400 * 2);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: CarpoolRoutes.drive('k1', _am));
    addTearDown(router.dispose);
    final List<Override> overrides = <Override>[
      flavorConfigProvider.overrideWithValue(testDevConfig),
      settingsStoreProvider.overrideWithValue(store),
      analyticsSinkProvider.overrideWithValue(sink),
      ...authOverrides(
        carpools: FakeCarpoolRepository(memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved)]),
        schedule: FakeScheduleRepository(),
        trips: trips,
        tracker: tracker,
        recovery: native,
      ),
    ];
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
    return (trips, tracker, store, sink);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  group('the optional Always step (run recovery)', () {
    testWidgets('iPhone with While Using: offered once before the first run; Allow asks iOS, the run starts', (WidgetTester tester) async {
      final FakeRecoveryNative native = FakeRecoveryNative(
        supported: true,
        status: RecoveryAuthorization.whenInUse,
        afterRequest: RecoveryAuthorization.always,
      );
      final (FakeTripRepository trips, FakeLocationTracker tracker, InMemorySettingsStore store, _RecordingSink sink) = await pump(tester, native);
      await tap(tester, 'drive.start');
      expect(find.byKey(const Key('always.screen')), findsOneWidget);
      expect(find.text('Resume runs by itself'), findsOneWidget);
      expect(trips.calls.contains('start'), isFalse, reason: 'the run waits for the answer');
      await tap(tester, 'always.allow');
      expect(native.requests, 1);
      expect(find.byKey(const Key('always.screen')), findsNothing);
      expect(tracker.starts, 1);
      expect(native.starts, 1, reason: 'the native side starts with the run');
      expect(store.read(RunRecoveryService.markerKey), isNotNull);
      expect(sink.events.where(((String, Map<String, Object>) e) => e.$1 == 'always_location').single.$2, <String, Object>{'granted': 1});
    });

    testWidgets('Not now: the run starts the same; never asked again', (WidgetTester tester) async {
      final FakeRecoveryNative native = FakeRecoveryNative(supported: true, status: RecoveryAuthorization.whenInUse);
      final (FakeTripRepository trips, FakeLocationTracker tracker, InMemorySettingsStore store, _RecordingSink _) = await pump(tester, native);
      await tap(tester, 'drive.start');
      await tap(tester, 'always.notNow');
      expect(native.requests, 0);
      expect(tracker.starts, 1);
      expect(trips.calls, contains('start'));
      expect(find.text('Keep the app open — you can lock the phone.'), findsOneWidget, reason: 'the hint stays');
      expect(store.read(RunRecoveryService.alwaysAskedKey), isNotNull);
    });

    testWidgets('not an iPhone, or Always already given: no step', (WidgetTester tester) async {
      for (final FakeRecoveryNative native in <FakeRecoveryNative>[
        FakeRecoveryNative(status: RecoveryAuthorization.whenInUse),
        FakeRecoveryNative(supported: true, status: RecoveryAuthorization.always),
      ]) {
        final (FakeTripRepository _, FakeLocationTracker tracker, InMemorySettingsStore _, _RecordingSink _) = await pump(tester, native);
        await tap(tester, 'drive.start');
        expect(find.byKey(const Key('always.screen')), findsNothing);
        expect(tracker.starts, 1);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('[${locale.languageCode}] Always screen at text x$scale', (WidgetTester tester) async {
          final FakeRecoveryNative native = FakeRecoveryNative(supported: true, status: RecoveryAuthorization.whenInUse);
          await pump(tester, native, locale: locale, width: 320, textScale: scale);
          await tap(tester, 'drive.start');
          expectOneLine(find.byType(AppBarTitle), 'title');
          expectOneLine(find.byType(AppButton), 'buttons', allowEllipsis: scale != 1);
        });
      }
    }
  });
}
