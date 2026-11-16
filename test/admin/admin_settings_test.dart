// Admin panel: Settings (pilot feature switches) and a parent's settle-up
// records on the user page, with fake functions. Written, not run here (no
// Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/settings_screen.dart';
import 'package:school_carpool/admin/shell/admin_shell.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/one_line.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

AppSwitchRow _row(WidgetTester tester, AppFeature f) => tester.widget<AppSwitchRow>(find.byKey(Key('adminSettings.${f.name}')));

void main() {
  setUpAll(loadAppFonts);

  const AdminSessionState superAdmin = AdminSignedIn(testSuperAdmin);
  const AdminSessionState reviewer = AdminSignedIn(testReviewer);

  group('Settings: launch gate (R5)', () {
    AppSwitchRow launchRow(WidgetTester tester) => tester.widget<AppSwitchRow>(find.byKey(const Key('adminSettings.launch')));

    testWidgets('prod starts closed; a super admin opens it only with the licence numbers', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('adminSettings.launch')));
      expect(launchRow(tester).value, isFalse);
      expect(find.textContaining('new parents cannot sign up in prod'), findsOneWidget);
      launchRow(tester).onChanged!(true);
      await _settle(tester);
      expect(find.text('Open to new parents?'), findsOneWidget);
      final FilledButton confirm = tester.widget<FilledButton>(find.byKey(const Key('adminSettings.launchConfirm')));
      expect(confirm.onPressed, isNull, reason: 'no licence numbers yet');
      await tester.enterText(find.descendant(of: find.byKey(const Key('adminSettings.launchRefs')), matching: find.byType(TextFormField)), 'C-1, S-2, T-3');
      await _settle(tester);
      await tester.tap(find.byKey(const Key('adminSettings.launchConfirm')));
      await _settle(tester);
      expect(api.calls, contains('setLaunch:true:C-1, S-2, T-3'));
      expect(launchRow(tester).value, isTrue);
    });

    testWidgets('other admins see it but cannot change it', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: reviewer, location: AdminRoutes.settings, features: FakeAdminFeaturesApi(), locale: 'en');
      await _settle(tester);
      await tester.ensureVisible(find.byKey(const Key('adminSettings.launch')));
      expect(launchRow(tester).onChanged, isNull);
    });
  });

  group('Settings: feature switches', () {
    testWidgets('one switch per feature, showing the pilot defaults', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      // The shell reads the switches too (Wallet section only while on).
      expect(api.calls.toSet(), <String>{'features', 'launch'});
      expect(_row(tester, AppFeature.wallet).value, isFalse);
      expect(_row(tester, AppFeature.ratingsAndVouching).value, isFalse);
      expect(_row(tester, AppFeature.yearlyChecks).value, isFalse);
      // No money in the app (16 Nov 2026): every money switch starts off.
      expect(_row(tester, AppFeature.settleUp).value, isFalse);
      expect(_row(tester, AppFeature.contributions).value, isFalse);
      // One per feature, plus the launch gate (R5).
      expect(find.byType(AppSwitchRow), findsNWidgets(AppFeature.values.length + 1));
      // Core features are named as always on, with no switch.
      expect(find.textContaining('are always on'), findsOneWidget);
    });

    testWidgets('a super admin turns the wallet on after a confirmation', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      _row(tester, AppFeature.wallet).onChanged!(true);
      await _settle(tester);
      expect(find.text('Turn this on?'), findsOneWidget);
      expect(find.textContaining('Wallet will show for every parent'), findsOneWidget);
      // Nothing changes before the confirmation; Cancel keeps it off.
      expect(api.calls.where((String c) => c.startsWith('setFeature')), isEmpty);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(api.calls.where((String c) => c.startsWith('setFeature')), isEmpty);
      expect(_row(tester, AppFeature.wallet).value, isFalse);

      _row(tester, AppFeature.wallet).onChanged!(true);
      await _settle(tester);
      await tester.tap(find.text('Turn on'));
      await _settle(tester);
      expect(api.calls, contains('setFeature:wallet:true'));
      expect(_row(tester, AppFeature.wallet).value, isTrue);
      expect(_row(tester, AppFeature.settleUp).value, isFalse, reason: 'the other switches keep their value');
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('turning a feature off asks too and says nothing is deleted', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi()..switches = FeatureSwitches.allOn;
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      _row(tester, AppFeature.settleUp).onChanged!(false);
      await _settle(tester);
      expect(find.text('Turn this off?'), findsOneWidget);
      expect(find.textContaining('Nothing is deleted'), findsOneWidget);
      await tester.tap(find.text('Turn off'));
      await _settle(tester);
      expect(api.calls, contains('setFeature:settleUp:false'));
      expect(_row(tester, AppFeature.settleUp).value, isFalse);
    });

    testWidgets('an ordinary admin sees the switches but cannot change them', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: reviewer, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      for (final AppFeature f in AppFeature.values) {
        expect(_row(tester, f).onChanged, isNull, reason: f.name);
      }
      expect(find.text('Only a super admin can change these switches.'), findsOneWidget);
      expect(api.calls.toSet(), <String>{'features', 'launch'});
    });

    testWidgets('a refused change shows the reason and leaves the switch as it was', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      api.failure = const AdminFailure(AdminFailureKind.notSuperAdmin);
      _row(tester, AppFeature.yearlyChecks).onChanged!(true);
      await _settle(tester);
      await tester.tap(find.text('Turn on'));
      await _settle(tester);
      expect(api.switches.yearlyChecks, isFalse);
      expect(_row(tester, AppFeature.yearlyChecks).value, isFalse);
    });

    testWidgets('loading error: the page says so with Retry', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi()..failure = const AdminFailure(AdminFailureKind.offline);
      await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: api, locale: 'en');
      await _settle(tester);
      expect(find.byType(OfflineStateView), findsOneWidget);
      api.failure = null;
      await tester.tap(find.byTooltip('Refresh').first);
      await _settle(tester);
      expect(find.byKey(const Key('adminSettings.list')), findsOneWidget);
    });

    test('every admin has the Settings section; the feature-off error has its own words', () {
      expect(adminSections(superAdmin: false).map((AdminSection s) => s.path), contains(AdminRoutes.settings));
      expect(adminSections(superAdmin: true).map((AdminSection s) => s.path), contains(AdminRoutes.settings));
      // No money in the app: the Wallet section only while the wallet is on.
      expect(adminSections(superAdmin: true).map((AdminSection s) => s.path), isNot(contains(AdminRoutes.wallets)));
      expect(adminSections(superAdmin: true, wallet: true).map((AdminSection s) => s.path), contains(AdminRoutes.wallets));
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(const AdminFailure(AdminFailureKind.featureOff).message(en), contains('switched off'));
      for (final AppFeature f in AppFeature.values) {
        expect(adminFeatureTitle(en, f), isNotEmpty);
        expect(adminFeatureHelper(en, f), isNotEmpty);
      }
    });
  });

  group('user page: settle-up records (read only, logged reason)', () {
    testWidgets('nothing is asked for until a reason is picked; then the list shows without an address', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi()..switches = FeatureSwitches.allOn;
      await pumpAdminPanel(tester, session: reviewer, location: AdminRoutes.user('parent1'), features: api, locale: 'en', size: const Size(1280, 2400));
      await _settle(tester);
      expect(find.byKey(const Key('user.settleUp')), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const Key('user.settleUp.show'))).onPressed, isNull);
      expect(api.calls.where((String c) => c != 'features'), isEmpty);
      await tester.tap(find.byKey(const Key('user.settleUp.reason')));
      await _settle(tester);
      await tester.tap(find.text('Investigation').last);
      await _settle(tester);
      await tester.tap(find.byKey(const Key('user.settleUp.show')));
      await _settle(tester);
      expect(api.calls.where((String c) => c != 'features'), <String>['settleUps:parent1:investigation']);
      expect(find.byKey(const Key('user.settleUp.s_1')), findsOneWidget);
      expect(find.byKey(const Key('user.settleUp.s_2')), findsOneWidget);
      expect(find.textContaining('From Hoda'), findsOneWidget);
      expect(find.textContaining('To Badr'), findsOneWidget);
      expect(find.textContaining('Not received: 2'), findsOneWidget);
      expect(find.textContaining('instapay'), findsNothing);
      // Read only: no button changes a record.
      expect(find.byKey(const Key('user.settleUp.show')), findsNothing);
    });

    testWidgets('Settle up off (the default): no settle-up section, nothing asked for', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi();
      await pumpAdminPanel(tester, session: reviewer, location: AdminRoutes.user('parent1'), features: api, locale: 'en', size: const Size(1280, 2400));
      await _settle(tester);
      expect(find.byKey(const Key('user.settleUp')), findsNothing);
      expect(api.calls.where((String c) => c.startsWith('settleUps')), isEmpty);
    });

    testWidgets('no records, and a refusal, each say so', (WidgetTester tester) async {
      final FakeAdminFeaturesApi api = FakeAdminFeaturesApi()
        ..switches = FeatureSwitches.allOn
        ..records = <AdminSettleRecord>[];
      await pumpAdminPanel(tester, session: reviewer, location: AdminRoutes.user('parent1'), features: api, locale: 'en', size: const Size(1280, 2400));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('user.settleUp.reason')));
      await _settle(tester);
      await tester.tap(find.text('Report').last);
      await _settle(tester);
      await tester.tap(find.byKey(const Key('user.settleUp.show')));
      await _settle(tester);
      expect(find.byKey(const Key('user.settleUp.none')), findsOneWidget);
    });
  });

  group('one line', () {
    for (final String locale in <String>['ar', 'en']) {
      testWidgets('[$locale] Settings title, switch titles and the rail label', (WidgetTester tester) async {
        await pumpAdminPanel(tester, session: superAdmin, location: AdminRoutes.settings, features: FakeAdminFeaturesApi(), locale: locale);
        await _settle(tester);
        expectOneLine(find.byType(AppBarTitle), 'settings title ($locale)', requireText: true);
        for (final AppFeature f in AppFeature.values) {
          expectOneLine(
            find.descendant(of: find.byKey(Key('adminSettings.${f.name}')), matching: find.byType(OneLineText)).first,
            'switch ${f.name} ($locale)',
            requireText: true,
          );
        }
        expectOneLine(find.byType(NavigationRail), 'rail ($locale)', requireText: true);
      });
    }
  });
}
