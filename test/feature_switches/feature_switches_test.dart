// Pilot feature switches (owner decision 14 Nov 2026): the model, the one
// provider, hidden entry points on Profile, and the calm "Not available
// yet" screen on a deep link. Fake repositories: no Firebase. Written, not
// run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/feature_switches/feature_gate.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/settle_up/settle_up_screen.dart';
import 'package:school_carpool/features/trust/rate_screen.dart';
import 'package:school_carpool/features/trust/school_year_screen.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/wallet/wallet_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/settle_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/trust_fakes.dart';
import '../helpers/wallet_fakes.dart';

class _World {
  final FakeWalletRepository wallet = FakeWalletRepository();
  final FakeSettleUpRepository settle = FakeSettleUpRepository();

  /// A yearly check that is due and two parents to rate: both would show
  /// on Profile if their features were on.
  final FakeTrustRepository trust = FakeTrustRepository(
    overviewValue: const TrustOverview(summary: TrustSummary(ratings: 4, average: 4.5, vouches: 2), toRate: 2, yearCheck: sampleYearCheck, requests: 1),
  );
}

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(_World w, FeatureSwitches features) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(wallet: w.wallet, trust: w.trust, settle: w.settle, features: features),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location,
  _World w,
  FeatureSwitches features, {
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
}) async {
  // Tall: the whole Profile list is built without scrolling.
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 4000 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(w.settle.dispose);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      // A fresh scope for every pump (some tests open several links).
      key: UniqueKey(),
      overrides: _overrides(w, features),
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

Finder _key(String k) => find.byKey(Key(k));

void main() {
  // Real fonts, so the one-line checks measure real widths.
  setUpAll(loadAppFonts);

  group('the switches', () {
    test('pilot defaults: everything off; no money in the app (wallet, Settle up, contributions)', () {
      expect(FeatureSwitches.pilot.wallet, isFalse);
      expect(FeatureSwitches.pilot.ratingsAndVouching, isFalse);
      expect(FeatureSwitches.pilot.yearlyChecks, isFalse);
      expect(FeatureSwitches.pilot.settleUp, isFalse);
      expect(FeatureSwitches.pilot.contributions, isFalse);
      expect(FeatureSwitches.pilot.anyMoney, isFalse);
      expect(FeatureSwitches.allOn.anyMoney, isTrue);
      expect(
        AppFeature.values.map((AppFeature f) => f.name),
        <String>['wallet', 'ratingsAndVouching', 'yearlyChecks', 'settleUp', 'contributions'],
      );
    });

    test('a missing document reads as the pilot defaults', () {
      expect(FeatureSwitches.fromMap(null), FeatureSwitches.pilot);
      expect(FeatureSwitches.fromMap(const <String, Object?>{}), FeatureSwitches.pilot);
    });

    test('only real booleans count; anything else keeps the default', () {
      expect(
        FeatureSwitches.fromMap(const <String, Object?>{'wallet': true, 'settleUp': false}),
        const FeatureSwitches(wallet: true, ratingsAndVouching: false, yearlyChecks: false, settleUp: false, contributions: false),
      );
      expect(
        FeatureSwitches.fromMap(const <String, Object?>{'wallet': 'true', 'ratingsAndVouching': 1, 'yearlyChecks': null, 'settleUp': 'no', 'chat': false}),
        FeatureSwitches.pilot,
      );
    });

    test('isOn follows each field', () {
      const FeatureSwitches s = FeatureSwitches(wallet: true, ratingsAndVouching: false, yearlyChecks: true, settleUp: false, contributions: false);
      expect(s.isOn(AppFeature.wallet), isTrue);
      expect(s.isOn(AppFeature.ratingsAndVouching), isFalse);
      expect(s.isOn(AppFeature.yearlyChecks), isTrue);
      expect(s.isOn(AppFeature.settleUp), isFalse);
      expect(FeatureSwitches.pilot.copyWith(wallet: true).wallet, isTrue);
      expect(FeatureSwitches.pilot.copyWith(wallet: true).settleUp, isFalse);
      expect(FeatureSwitches.pilot.copyWith(contributions: true).contributions, isTrue);
      expect(AppFeature.values.every(FeatureSwitches.allOn.isOn), isTrue);
    });
  });

  group('the provider', () {
    test('pilot defaults while loading, then the stored values; a change needs no restart', () async {
      final StreamController<FeatureSwitches> stored = StreamController<FeatureSwitches>();
      addTearDown(stored.close);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[featureSwitchesStreamProvider.overrideWith((Ref ref) => stored.stream)],
      );
      addTearDown(container.dispose);
      // Kept alive for the whole test (closed with the container).
      container.listen<FeatureSwitches>(featureSwitchesProvider, (_, _) {});
      expect(container.read(featureSwitchesProvider), FeatureSwitches.pilot);
      stored.add(FeatureSwitches.allOn);
      await pumpEventQueue();
      expect(container.read(featureSwitchesProvider), FeatureSwitches.allOn);
      // The owner turns the wallet off again from the admin panel.
      stored.add(FeatureSwitches.allOn.copyWith(wallet: false));
      await pumpEventQueue();
      expect(container.read(featureSwitchesProvider).wallet, isFalse);
      expect(container.read(featureSwitchesProvider).ratingsAndVouching, isTrue);
    });

    test('a failed read (offline with nothing cached, refused) falls back to the pilot defaults', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          featureSwitchesStreamProvider.overrideWith((Ref ref) => Stream<FeatureSwitches>.error(StateError('permission-denied'))),
        ],
      );
      addTearDown(container.dispose);
      container.listen<FeatureSwitches>(featureSwitchesProvider, (_, _) {});
      await pumpEventQueue();
      expect(container.read(featureSwitchesProvider), FeatureSwitches.pilot);
    });

    test('signed out: the pilot defaults, with no listener on the server', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[sessionProvider.overrideWithValue(const SessionSignedOut())],
      );
      addTearDown(container.dispose);
      container.listen<FeatureSwitches>(featureSwitchesProvider, (_, _) {});
      await pumpEventQueue();
      // firestoreProvider is not overridden: reading it would throw.
      expect(container.read(featureSwitchesStreamProvider).value, FeatureSwitches.pilot);
      expect(container.read(featureSwitchesProvider), FeatureSwitches.pilot);
    });
  });

  group('Profile hides what is switched off', () {
    testWidgets('pilot: no money UI (no wallet, no Settle up), no ratings row, no yearly check card; family links stay', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, AppTab.profile.path, w, FeatureSwitches.pilot);
      expect(_key('profile.wallet'), findsNothing);
      expect(_key('profile.ratings'), findsNothing);
      expect(_key('profile.yearCheck'), findsNothing);
      expect(_key('profile.settleUp'), findsNothing);
      expect(find.textContaining('InstaPay'), findsNothing);
      expect(w.settle.calls, isEmpty);
      // Not switchable: family links, driving papers, children, privacy.
      expect(_key('profile.family'), findsOneWidget);
      expect(find.text('1 request to answer'), findsOneWidget);
      expect(_key('profile.driving'), findsOneWidget);
      expect(_key('profile.children'), findsOneWidget);
      expect(_key('profile.privacy'), findsOneWidget);
      // Nothing of the wallet was asked for.
      expect(w.wallet.calls, isEmpty);
    });

    testWidgets('everything on: every row and the yearly check card show', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, AppTab.profile.path, w, FeatureSwitches.allOn);
      for (final String k in <String>['profile.wallet', 'profile.ratings', 'profile.yearCheck', 'profile.settleUp', 'profile.family']) {
        expect(_key(k), findsOneWidget, reason: k);
      }
    });

    testWidgets('each switch hides only its own entry point', (WidgetTester tester) async {
      const Map<AppFeature, String> rows = <AppFeature, String>{
        AppFeature.wallet: 'profile.wallet',
        AppFeature.ratingsAndVouching: 'profile.ratings',
        AppFeature.yearlyChecks: 'profile.yearCheck',
        AppFeature.settleUp: 'profile.settleUp',
      };
      final FeatureSwitches oneOff = FeatureSwitches.allOn.copyWith(ratingsAndVouching: false);
      await _pump(tester, AppTab.profile.path, _World(), oneOff);
      for (final MapEntry<AppFeature, String> e in rows.entries) {
        expect(_key(e.value), oneOff.isOn(e.key) ? findsOneWidget : findsNothing, reason: e.value);
      }
    });

    testWidgets('Settle up is for verified parents: no row before verification', (WidgetTester tester) async {
      tester.view
        ..devicePixelRatio = 2
        ..physicalSize = const Size(800, 8000);
      addTearDown(tester.view.reset);
      final _World w = _World();
      addTearDown(w.settle.dispose);
      final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: AppTab.profile.path);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            flavorConfigProvider.overrideWithValue(testDevConfig),
            settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
            ...authOverrides(
              session: testUnverifiedSession,
              wallet: w.wallet,
              trust: w.trust,
              settle: w.settle,
              features: FeatureSwitches.pilot.copyWith(settleUp: true),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: AppLocales.english,
            supportedLocales: AppLocales.supported,
            localizationsDelegates: AppLocales.delegates,
            theme: AppTheme.light(DesignDirection.a),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_key('profile.settleUp'), findsNothing);
    });

    testWidgets('the Settle up row opens Settle up', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, AppTab.profile.path, _World(), FeatureSwitches.pilot.copyWith(settleUp: true));
      await tester.ensureVisible(_key('profile.settleUp'));
      await tester.pumpAndSettle();
      await tester.tap(_key('profile.settleUp'));
      await tester.pumpAndSettle();
      expect(_path(router), SettleUpRoutes.home);
      expect(find.byType(SettleUpScreen), findsOneWidget);
    });
  });

  group('a deep link to a switched-off feature', () {
    testWidgets('wallet off: every wallet link shows "Not available yet", never the wallet, and asks the server nothing', (WidgetTester tester) async {
      for (final String link in <String>[ProfileRoutes.wallet, WalletRoutes.send(), WalletRoutes.add, WalletRoutes.withdraw, WalletRoutes.transfer('t_1')]) {
        final _World w = _World();
        await _pump(tester, link, w, FeatureSwitches.pilot);
        expect(_key('feature.off'), findsOneWidget, reason: link);
        expect(find.text('Not available yet'), findsWidgets, reason: link);
        expect(find.byType(WalletScreen), findsNothing, reason: link);
        expect(find.byType(ErrorStateView), findsNothing, reason: link);
        expect(w.wallet.calls, isEmpty, reason: link);
      }
    });

    testWidgets('ratings and the yearly check off: their screens are not built', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, ProfileRoutes.ratings, w, FeatureSwitches.pilot);
      expect(_key('feature.off'), findsOneWidget);
      expect(find.byType(RateParentsScreen), findsNothing);
      await _pump(tester, ProfileRoutes.schoolYear, _World(), FeatureSwitches.pilot);
      expect(_key('feature.off'), findsOneWidget);
      expect(find.byType(SchoolYearScreen), findsNothing);
    });

    testWidgets('Settle up off (the default): its four screens show "Not available yet"', (WidgetTester tester) async {
      const FeatureSwitches off = FeatureSwitches.pilot;
      for (final String link in <String>[SettleUpRoutes.home, SettleUpRoutes.create(), SettleUpRoutes.address, SettleUpRoutes.record('s_owe')]) {
        final _World w = _World();
        await _pump(tester, link, w, off);
        expect(_key('feature.off'), findsOneWidget, reason: link);
        expect(find.byType(SettleUpScreen), findsNothing, reason: link);
        expect(w.settle.calls, isEmpty, reason: link);
      }
    });

    testWidgets('the one action goes back to Profile', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, ProfileRoutes.wallet, _World(), FeatureSwitches.pilot);
      await tester.tap(find.text('Back to Profile'));
      await tester.pumpAndSettle();
      expect(_path(router), AppTab.profile.path);
    });

    testWidgets('switched on: the same links open the real screens (no release)', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.wallet, _World(), FeatureSwitches.allOn);
      expect(_key('feature.off'), findsNothing);
      expect(find.byType(WalletScreen), findsOneWidget);
      await _pump(tester, ProfileRoutes.ratings, _World(), FeatureSwitches.allOn);
      expect(find.byType(RateParentsScreen), findsOneWidget);
      await _pump(tester, ProfileRoutes.schoolYear, _World(), FeatureSwitches.allOn);
      expect(find.byType(SchoolYearScreen), findsOneWidget);
    });

    testWidgets('FeatureGate shows its child only while the feature is on', (WidgetTester tester) async {
      Widget app(FeatureSwitches f) => buildTestApp(
        const FeatureGate(feature: AppFeature.wallet, child: Text('inside')),
        locale: AppLocales.english,
        extraOverrides: <Override>[featureSwitchesProvider.overrideWithValue(f)],
      );
      await tester.pumpWidget(app(FeatureSwitches.pilot));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsNothing);
      expect(find.byType(FeatureOffScreen), findsOneWidget);
      await tester.pumpWidget(app(FeatureSwitches.allOn));
      await tester.pumpAndSettle();
      expect(find.text('inside'), findsOneWidget);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('[${locale.languageCode} x$scale] the feature-off screen and the Settle up row', (WidgetTester tester) async {
          final String where = '(${locale.languageCode}, x$scale)';
          await _pump(tester, ProfileRoutes.wallet, _World(), FeatureSwitches.pilot, locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'feature off app bar $where', requireText: true);
          expectOneLine(find.byType(AppButton), 'feature off action $where', requireText: true);
          // The Settle up row shows only while Settle up is on (off by default: no money in the app).
          await _pump(tester, AppTab.profile.path, _World(), FeatureSwitches.allOn, locale: locale, width: 320, textScale: scale);
          expectOneLine(
            find.descendant(of: _key('profile.settleUp'), matching: find.byType(OneLineText)).first,
            'profile settle up row $where',
            allowEllipsis: scale > 1,
            requireText: true,
          );
        });
      }
    }
  });
}
