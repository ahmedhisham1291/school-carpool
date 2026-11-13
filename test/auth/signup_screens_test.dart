// Widget tests for the sign-up screens and the profile (F1, F44).
// Written, not run here (no Flutter SDK in the build workspace).

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/test_app.dart';

class _CodeSent extends SignupFlowController {
  @override
  SignupFlowState build() => SignupFlowState(
    phoneE164: '+201000000001',
    resendAvailableAt: DateTime.now().add(const Duration(seconds: 30)),
  );
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  required String location,
  required FakeAuthRepository repository,
  SessionState session = const SessionSignedOut(),
  bool codeSent = false,
}) async {
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testStagingConfig),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ...authOverrides(session: session, repository: repository),
        if (codeSent) signupFlowProvider.overrideWith(_CodeSent.new),
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
  await tester.pump();
  return router;
}

void main() {
  group('phone step', () {
    testWidgets('the button stays off until the number is valid, then sends', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository();
      final GoRouter router = await _pump(tester, location: AuthRoutes.phone, repository: repository);

      await tester.enterText(find.byKey(const Key('phone.field')), '0101234');
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone.send')));
      await tester.pump();
      expect(repository.calls, isEmpty);

      await tester.enterText(find.byKey(const Key('phone.field')), '01312345678');
      await tester.pump();
      expect(find.text('Enter 11 digits starting with 010, 011, 012 or 015.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('phone.field')), '٠١٠١٢٣٤٥٦٧٨');
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone.send')));
      // The code screen ticks a countdown, so pump instead of settling.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(repository.calls, <String>['requestCode']);
      expect(repository.lastPhone, '+201012345678');
      expect(router.routerDelegate.currentConfiguration.uri.path, AuthRoutes.code);
    });

    testWidgets('shows what to do when offline', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository()
        ..failure = const AuthFailure(AuthFailureKind.offline);
      await _pump(tester, location: AuthRoutes.phone, repository: repository);
      await tester.enterText(find.byKey(const Key('phone.field')), '01012345678');
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone.send')));
      await tester.pumpAndSettle();
      expect(find.text('No internet connection. Try again when you are back online.'), findsOneWidget);
    });
  });

  group('code step', () {
    testWidgets('a wrong code is refused with the tries left', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository()
        ..failure = const AuthFailure(AuthFailureKind.wrongCode, attemptsLeft: 4);
      await _pump(tester, location: AuthRoutes.code, repository: repository, codeSent: true);
      await tester.enterText(find.byKey(const Key('code.field')), '123456');
      await tester.pump();
      await tester.pump();
      expect(repository.calls, <String>['verifyCode']);
      expect(repository.lastCode, '123456');
      expect(find.text('That code is wrong. 4 tries left.'), findsOneWidget);
    });

    testWidgets('an expired code says to ask for a new one', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository()
        ..failure = const AuthFailure(AuthFailureKind.expiredCode);
      await _pump(tester, location: AuthRoutes.code, repository: repository, codeSent: true);
      await tester.enterText(find.byKey(const Key('code.field')), '654321');
      await tester.pump();
      await tester.pump();
      expect(find.text('This code has expired. Ask for a new one.'), findsOneWidget);
    });

    testWidgets('resend waits for the countdown', (WidgetTester tester) async {
      await _pump(tester, location: AuthRoutes.code, repository: FakeAuthRepository(), codeSent: true);
      expect(find.byKey(const Key('code.resend')), findsNothing);
      expect(find.textContaining('You can ask for a new code in'), findsOneWidget);
    });

    testWidgets('without a number it offers to go back', (WidgetTester tester) async {
      await _pump(tester, location: AuthRoutes.code, repository: FakeAuthRepository());
      expect(find.text('Change number'), findsOneWidget);
    });
  });

  group('email step', () {
    const SessionState emailStage = SessionSignedIn(
      uid: 'uid-1',
      account: Account(
        parentId: 'ABCD2345',
        status: AccountStatus.unverified,
        phone: '+201000000001',
        email: null,
        emailVerified: false,
        termsAccepted: false,
        language: 'ar',
      ),
    );

    testWidgets('checks once on open, quietly, so a returning parent moves on', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository();
      await _pump(tester, location: AuthRoutes.email, repository: repository, session: emailStage);
      await tester.pump();
      await tester.pump();
      expect(repository.calls, <String>['confirmEmail']);
      // Not confirmed yet: no message, the address field is shown.
      expect(find.byKey(const Key('email.field')), findsOneWidget);
      expect(find.textContaining('Not confirmed yet'), findsNothing);
    });

    testWidgets('an ended session offers to sign in again', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository()
        ..failure = const AuthFailure(AuthFailureKind.signInAgain);
      await _pump(tester, location: AuthRoutes.email, repository: repository, session: emailStage);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Sign in again with your number'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('email.signInAgain')));
      await tester.tap(find.byKey(const Key('email.signInAgain')));
      await tester.pump();
      expect(repository.calls, <String>['confirmEmail', 'signOut']);
    });

    testWidgets('sends the link and waits for the confirmation', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository();
      await _pump(tester, location: AuthRoutes.email, repository: repository, session: emailStage);
      await tester.pump();
      await tester.enterText(find.byKey(const Key('email.field')), 'parent@example.com');
      await tester.pump();
      await tester.tap(find.byKey(const Key('email.send')));
      await tester.pump();
      await tester.pump();
      expect(repository.calls, <String>['confirmEmail', 'sendEmailLink']);
      await tester.tap(find.byKey(const Key('email.confirmed')));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Not confirmed yet'), findsOneWidget);
    });
  });

  group('terms step', () {
    testWidgets('needs all three documents; WhatsApp is optional', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository();
      await _pump(tester, location: AuthRoutes.terms, repository: repository);

      await tester.tap(find.byKey(const Key('terms.accept')));
      await tester.pump();
      expect(repository.calls, isEmpty);
      expect(find.text('Accept all three documents to continue.'), findsOneWidget);

      for (final String key in <String>['terms.terms', 'terms.privacy', 'terms.conduct']) {
        final Finder box = find.descendant(of: find.byKey(Key(key)), matching: find.byType(Checkbox));
        await tester.ensureVisible(box);
        await tester.pump();
        await tester.tap(box);
        await tester.pump();
      }
      await tester.ensureVisible(find.byKey(const Key('terms.accept')));
      await tester.tap(find.byKey(const Key('terms.accept')));
      await tester.pump();
      expect(repository.calls, <String>['acceptConsents']);
      expect(repository.acceptedWhatsApp, isFalse);
    });
  });

  group('profile', () {
    testWidgets('shows the parent ID and copies it', (WidgetTester tester) async {
      final List<MethodCall> clipboard = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
        MethodCall call,
      ) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(call);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await _pump(
        tester,
        location: AppTab.profile.path,
        repository: FakeAuthRepository(),
        session: testUnverifiedSession,
      );
      expect(find.text('ABCD2345'), findsOneWidget);
      expect(find.text('Not verified'), findsOneWidget);

      await tester.tap(find.byKey(const Key('copyValue.button')));
      await tester.pump();
      expect(clipboard, hasLength(1));
      expect((clipboard.single.arguments as Map<Object?, Object?>)['text'], 'ABCD2345');
      expect(find.text('Copied.'), findsOneWidget);
    });

    testWidgets('sign out asks first', (WidgetTester tester) async {
      final FakeAuthRepository repository = FakeAuthRepository();
      await _pump(
        tester,
        location: AppTab.profile.path,
        repository: repository,
        session: testUnverifiedSession,
      );
      await tester.scrollUntilVisible(find.byKey(const Key('profile.signOut')), 200);
      await tester.tap(find.byKey(const Key('profile.signOut')));
      await tester.pumpAndSettle();
      expect(repository.calls, isEmpty);
      await tester.tap(find.text('Sign out').last);
      await tester.pumpAndSettle();
      expect(repository.calls, <String>['signOut']);
    });
  });

  testWidgets('verify-account screen explains the next steps', (WidgetTester tester) async {
    await _pump(
      tester,
      location: AuthRoutes.verifyAccount,
      repository: FakeAuthRepository(),
      session: testUnverifiedSession,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Verify your account'), findsWidgets);
    expect(find.text('Your national ID, front and back'), findsOneWidget);
    expect(find.byKey(const Key('verify.openProfile')), findsOneWidget);
  });
}
