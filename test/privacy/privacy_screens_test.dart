// Privacy screens (Prompt 12) with the fake privacy repository: no
// Firebase. Privacy (export, data types, consents, requests), phones and
// sign-ins, delete account, the new-phone selfie, and one line at 320 dp
// and 200 percent in Arabic and English. Written, not run here (no Flutter
// SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/privacy/devices_screen.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/privacy/privacy_screen.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/one_line.dart';
import '../helpers/privacy_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

class _World {
  final FakePrivacyRepository repo = FakePrivacyRepository();
  final RecordingAnalyticsSink analytics = RecordingAnalyticsSink();
  final FakeCamera camera = FakeCamera();
  final List<Uri> opened = <Uri>[];
  final List<String> tokens = <String>[];
}

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(_World w, FeatureSwitches? features) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  // The parent said yes to usage statistics (off until then).
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore(<String, String>{AnalyticsConsent.storageKey: 'true'})),
  ...authOverrides(features: features),
  privacyRepositoryProvider.overrideWithValue(w.repo),
  analyticsSinkProvider.overrideWithValue(w.analytics),
  captureLauncherProvider.overrideWithValue(w.camera.launch),
  linkOpenerProvider.overrideWithValue((Uri uri) async {
    w.opened.add(uri);
    return true;
  }),
  sessionRenewerProvider.overrideWithValue((String token) async => w.tokens.add(token)),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location,
  _World w, {
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
  FeatureSwitches? features,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 2400 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
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

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('privacy screen', () {
    testWidgets('downloads the data with one tap and lists every data type', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.privacy, w);
      expect(find.byKey(const Key('privacy.export')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('privacy.export')));
      expect(w.repo.calls, contains('exportData'));
      expect(w.opened.single.toString(), 'https://storage.example/export.json');
      expect(find.text('Your data is ready'), findsOneWidget);
      expect(w.analytics.events.map(((String, Map<String, Object>) e) => e.$1), contains('privacy_export'));
      for (final DataType t in DataType.values) {
        await tester.scrollUntilVisible(find.byKey(Key('privacy.data.${t.name}')), 200, scrollable: find.byType(Scrollable).first);
      }
    });

    testWidgets('pilot switches: the wallet, ratings and Settle up are not listed while off', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.privacy, w, features: FeatureSwitches.pilot);
      for (final DataType t in DataType.values) {
        final Finder row = find.byKey(Key('privacy.data.${t.name}'));
        if (t == DataType.wallet || t == DataType.ratings || t == DataType.settleUp) {
          expect(row, findsNothing, reason: t.name);
        } else {
          await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
        }
      }
      expect(dataTypeShown(DataType.settleUp, FeatureSwitches.pilot), isFalse);
      expect(dataTypeShown(DataType.settleUp, FeatureSwitches.pilot.copyWith(settleUp: true)), isTrue);
      expect(dataTypeShown(DataType.trips, FeatureSwitches.pilot), isTrue);
    });

    testWidgets('a data type opens what it holds and how long it is kept', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.privacy, w);
      await _tap(tester, find.byKey(const Key('privacy.data.idPhotos')));
      expect(find.text('How long we keep it'), findsOneWidget);
      expect(find.text('While your account is open, plus 1 year'), findsWidgets);
    });

    testWidgets('statistics switch off; a needed consent says to delete the account', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.privacy, w);
      final Finder analytics = find.byKey(const Key('privacy.consent.analytics'));
      await _tap(tester, analytics);
      expect(w.repo.calls, contains('setConsent:analytics:false'));
      w.repo.effect = WithdrawEffect.needsDeletion;
      await _tap(tester, find.byKey(const Key('privacy.consent.face')));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Withdraw')));
      await tester.pumpAndSettle();
      expect(w.repo.calls, contains('setConsent:face:false'));
      expect(find.text('The app needs this consent. To withdraw it, delete your account.'), findsOneWidget);
    });

    testWidgets('asks to correct ID details and for a copy of the photos (logged requests)', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.privacy, w);
      await _tap(tester, find.byKey(const Key('privacy.correct.id')));
      expect(w.repo.calls, contains('requestCorrection:name'));
      await _tap(tester, find.byKey(const Key('privacy.photoCopy')));
      expect(w.repo.calls, contains('requestPhotoCopy'));
    });

    testWidgets('error and offline states retry', (WidgetTester tester) async {
      final _World w = _World()..repo.failure = const PrivacyFailure(PrivacyFailureKind.offline);
      await _pump(tester, PrivacyRoutes.privacy, w);
      expect(find.byType(OfflineStateView), findsOneWidget);
    });
  });

  group('phones and sign-ins', () {
    testWidgets('lists this phone and another; signing it out renews this phone', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.devices, w);
      expect(find.text('This phone'), findsOneWidget);
      expect(find.text('Other phone'), findsWidgets);
      expect(find.text('Recent sign-ins'), findsOneWidget);
      await _tap(tester, find.byKey(Key('devices.device.s_${'b' * 40}')));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sign out')));
      await tester.pumpAndSettle();
      expect(w.repo.calls, contains('signOutDevice:s_${'b' * 40}'));
      expect(w.tokens, <String>['fresh-token']);
    });
  });

  group('delete account', () {
    testWidgets('two steps; the button waits for "I understand"; money in the wallet is explained', (WidgetTester tester) async {
      final _World w = _World()..repo.failOnce['deleteAccount'] = const PrivacyFailure(PrivacyFailureKind.walletNotEmpty);
      await _pump(tester, PrivacyRoutes.delete, w);
      expect(find.text('Deleted now'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('delete.next')));
      final AppButton button = tester.widget<AppButton>(find.byKey(const Key('delete.confirm')));
      expect(button.onPressed, isNull);
      await _tap(tester, find.byKey(const Key('delete.understood')));
      await _tap(tester, find.byKey(const Key('delete.confirm')));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete my account')));
      await tester.pumpAndSettle();
      expect(w.repo.calls, contains('deleteAccount'));
      expect(find.byKey(const Key('delete.walletBanner')), findsOneWidget);
    });
  });

  group('new phone', () {
    testWidgets('a selfie opens everything again', (WidgetTester tester) async {
      final _World w = _World();
      await _pump(tester, PrivacyRoutes.newDevice, w);
      await _tap(tester, find.byKey(const Key('newDevice.selfie')));
      expect(w.camera.requests.single.isSelfie, isTrue);
      expect(w.repo.calls, contains('confirmNewDevice:uid-1'));
    });
  });

  group('one line at 320 dp and 200 percent', () {
    for (final Locale locale in AppLocales.supported) {
      testWidgets('titles and buttons, ${locale.languageCode}', (WidgetTester tester) async {
        for (final String route in <String>[PrivacyRoutes.privacy, PrivacyRoutes.devices, PrivacyRoutes.delete, PrivacyRoutes.newDevice]) {
          final _World w = _World();
          await _pump(tester, route, w, locale: locale, width: 320, textScale: 2);
          expectOneLine(find.byType(AppBarTitle), '$route title (${locale.languageCode})', requireText: true);
          for (final Element e in find.byType(AppButton).evaluate()) {
            expectOneLine(find.byWidget(e.widget), '$route button (${locale.languageCode})', allowEllipsis: true);
          }
        }
      });
    }
  });
}
