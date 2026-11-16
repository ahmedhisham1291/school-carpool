// Admin panel wallet (Prompt 11B: F14, F43) with fake functions. Written,
// not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_wallet.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/one_line.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const AdminSessionState signedIn = AdminSignedIn(testReviewer);

  testWidgets('read-only log and open alerts; no money buttons anywhere', (WidgetTester tester) async {
    final FakeAdminWalletApi wallet = FakeAdminWalletApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.wallets, wallet: wallet, locale: 'en');
    await _settle(tester);
    expect(find.byKey(const Key('adminWallet.alert.new-receivers_u-ali_1')), findsOneWidget);
    expect(find.text('Many new receivers'), findsOneWidget);
    expect(find.byKey(const Key('adminWallet.transfer.t_1')), findsOneWidget);
    expect(find.text('Ali to Hoda'), findsOneWidget);
    for (final String money in <String>['Send money', 'Add money', 'Withdraw', 'Refund']) {
      expect(find.text(money), findsNothing, reason: 'admins cannot move money');
    }
  });

  testWidgets('resolve an alert with an outcome', (WidgetTester tester) async {
    final FakeAdminWalletApi wallet = FakeAdminWalletApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.wallets, wallet: wallet, locale: 'en');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminWallet.resolve.new-receivers_u-ali_1')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminWallet.outcome.noIssue')));
    await _settle(tester);
    expect(wallet.calls, contains('resolve:new-receivers_u-ali_1:noIssue'));
    expect(find.byKey(const Key('adminWallet.noAlerts')), findsOneWidget);
  });

  testWidgets('freeze a wallet with a reason, after confirming; then unfreeze', (WidgetTester tester) async {
    final FakeAdminWalletApi wallet = FakeAdminWalletApi();
    final GoRouter router = await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.wallet('u-ali'), wallet: wallet, locale: 'en');
    await _settle(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, AdminRoutes.wallet('u-ali'));
    expect(find.text('Active'), findsOneWidget);
    await tester.tap(find.byKey(const Key('adminWallet.freeze')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('freeze.reason')));
    await _settle(tester);
    await tester.tap(find.text('Suspected fraud').last);
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('freeze.note')), 'Four new receivers');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('freeze.submit')));
    await _settle(tester);
    expect(wallet.frozenWith, isNull, reason: 'asks before freezing');
    await tester.tap(find.text('Freeze wallet').last);
    await _settle(tester);
    expect(wallet.frozenWith, (true, FreezeReason.fraudSuspected, 'Four new receivers'));
    expect(find.text('Frozen'), findsOneWidget);
    expect(find.byKey(const Key('adminWallet.unfreeze')), findsOneWidget);
  });

  testWidgets('wallet off (the default): no Wallet section and no wallet link on a user page', (WidgetTester tester) async {
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.user('u-1'), api: FakeAdminApi(), locale: 'en');
    await _settle(tester);
    expect(find.byKey(const Key('user.wallet')), findsNothing);
    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsNothing);
  });

  testWidgets('a user page links to the wallet', (WidgetTester tester) async {
    final FakeAdminApi api = FakeAdminApi();
    final GoRouter router = await pumpAdminPanel(
      tester,
      session: signedIn,
      location: AdminRoutes.user('u-1'),
      api: api,
      features: FakeAdminFeaturesApi()..switches = FeatureSwitches.allOn,
      locale: 'en',
    );
    await _settle(tester);
    final Finder link = find.byKey(const Key('user.wallet'));
    await tester.ensureVisible(link);
    await _settle(tester);
    await tester.tap(link);
    await _settle(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, AdminRoutes.wallet('u-1'));
  });

  testWidgets('wallet page titles and buttons stay on one line (Arabic)', (WidgetTester tester) async {
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.wallet('u-ali'), wallet: FakeAdminWalletApi(), size: const Size(1024, 800));
    await _settle(tester);
    expectOneLine(find.byKey(const Key('adminWallet.freeze')), 'freeze', requireText: true);
    expectOneLine(find.byKey(const Key('adminWallet.status')), 'status', requireText: true);
  });
}
