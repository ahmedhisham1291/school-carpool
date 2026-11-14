// Admin panel trust (Prompt 11: F14, F17) with fake functions. Written,
// not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/one_line.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const AdminSessionState signedIn = AdminSignedIn(testReviewer);

  testWidgets('links to review and rating flags are listed with names, not IDs', (WidgetTester tester) async {
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.trust, trust: FakeAdminTrustApi(), locale: 'en');
    await _settle(tester);
    expect(find.byKey(const Key('adminTrust.link.k9_u-dina')), findsOneWidget);
    expect(find.text('Dina for Laila'), findsOneWidget);
    expect(find.byKey(const Key('adminTrust.flag.2026-11_u-hoda_u-ali')), findsOneWidget);
    expect(find.text('Ali: 2 of 5 stars'), findsOneWidget);
  });

  testWidgets('approving a link asks first, then the row goes', (WidgetTester tester) async {
    final FakeAdminTrustApi trust = FakeAdminTrustApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.trust, trust: trust, locale: 'en');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminTrust.approve.k9_u-dina')));
    await _settle(tester);
    expect(find.text('Approve this link?'), findsOneWidget);
    expect(trust.calls.where((String c) => c.startsWith('decideLink')), isEmpty);
    await tester.tap(find.text('Approve').last);
    await _settle(tester);
    expect(trust.calls, contains('decideLink:k9_u-dina:true'));
    expect(find.byKey(const Key('adminTrust.noLinks')), findsOneWidget);
  });

  testWidgets('a flag is closed with an outcome; tapping it opens the rated parent', (WidgetTester tester) async {
    final FakeAdminTrustApi trust = FakeAdminTrustApi();
    final GoRouter router = await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.trust, trust: trust, locale: 'en');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminTrust.resolve.2026-11_u-hoda_u-ali')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminTrust.outcome.contacted')));
    await _settle(tester);
    expect(trust.calls, contains('resolveFlag:2026-11_u-hoda_u-ali:contacted'));
    expect(find.byKey(const Key('adminTrust.noFlags')), findsOneWidget);
    trust.flags = FakeAdminTrustApi().flags;
    await tester.tap(find.byTooltip('Refresh').first);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('adminTrust.flag.2026-11_u-hoda_u-ali')));
    await _settle(tester);
    expect(router.routerDelegate.currentConfiguration.uri.path, AdminRoutes.user('u-ali'));
  });

  for (final String locale in <String>['ar', 'en']) {
    testWidgets('one line: buttons and section headers ($locale)', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.trust, trust: FakeAdminTrustApi(), locale: locale);
      await _settle(tester);
      for (final String k in <String>['adminTrust.approve.k9_u-dina', 'adminTrust.reject.k9_u-dina', 'adminTrust.resolve.2026-11_u-hoda_u-ali']) {
        expectOneLine(find.byKey(Key(k)), '$k $locale', requireText: true);
      }
    });
  }
}
