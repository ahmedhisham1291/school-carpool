// Owner decision 16 Nov 2026 (App Review: look around before the ID
// check). Written, not run here (no Flutter SDK in the build workspace).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/onboarding/verify_prompt_card.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/test_app.dart';

SessionState _with(AccountStatus status) => SessionSignedIn(
  uid: 'uid-1',
  account: Account(
    parentId: 'ABCD2345',
    status: status,
    phone: '+201000000001',
    email: 'parent@example.com',
    emailVerified: true,
    termsAccepted: true,
    language: 'ar',
  ),
);

Future<void> _pump(WidgetTester tester, SessionState session, {Locale locale = AppLocales.english, double width = 400}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 1600 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestApp(
      const Scaffold(body: VerifyPromptCard()),
      locale: locale,
      extraOverrides: <Override>[...authOverrides(session: session)],
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('not verified yet: says what opens after the check', (WidgetTester tester) async {
    await _pump(tester, _with(AccountStatus.unverified));
    expect(find.byKey(const Key('verifyPrompt.card')), findsOneWidget);
    expect(find.text('Why and how'), findsOneWidget);
  });

  testWidgets('rejected: the same card (fix and send again from the screen)', (WidgetTester tester) async {
    await _pump(tester, _with(AccountStatus.rejected));
    expect(find.byKey(const Key('verifyPrompt.card')), findsOneWidget);
  });

  testWidgets('pending: says the documents are being checked', (WidgetTester tester) async {
    await _pump(tester, _with(AccountStatus.pending));
    expect(find.text('Checking your ID'), findsOneWidget);
    expect(find.text('See status'), findsOneWidget);
  });

  testWidgets('verified or suspended: nothing', (WidgetTester tester) async {
    await _pump(tester, _with(AccountStatus.verified));
    expect(find.byKey(const Key('verifyPrompt.card')), findsNothing);
    await _pump(tester, _with(AccountStatus.suspended));
    expect(find.byKey(const Key('verifyPrompt.card')), findsNothing);
  });

  for (final Locale locale in AppLocales.supported) {
    for (final AccountStatus status in <AccountStatus>[AccountStatus.unverified, AccountStatus.pending]) {
      testWidgets('[${locale.languageCode}] ${status.name}: title and button fit on one line at 320 dp', (WidgetTester tester) async {
        await _pump(tester, _with(status), locale: locale, width: 320);
        final Finder card = find.byKey(const Key('verifyPrompt.card'));
        expectOneLine(find.descendant(of: card, matching: find.byType(OneLineText)), 'title');
        expectOneLine(find.descendant(of: card, matching: find.byType(AppButton)), 'button');
      });
    }
  }
}
