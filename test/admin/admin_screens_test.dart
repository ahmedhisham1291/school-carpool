// Admin panel screens (F14) with fake functions and a fixed session.
// Written, not run here (no Flutter SDK in the build workspace).
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

import '../helpers/admin_fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> choose(WidgetTester tester, Key field, String option) async {
  await tester.tap(find.byKey(field));
  await settle(tester);
  await tester.tap(find.text(option).last);
  await settle(tester);
}

void main() {
  const AdminSessionState signedIn = AdminSignedIn(testReviewer);

  group('sign-in', () {
    testWidgets('two steps: password, then the authenticator code', (WidgetTester tester) async {
      final FakeAdminAuthRepository auth = FakeAdminAuthRepository();
      await pumpAdminPanel(tester, session: const AdminSignedOut(), location: AdminRoutes.signIn, auth: auth, locale: 'en');

      final Finder submit = find.byKey(const Key('admin.signIn.submit'));
      expect(tester.widget<FilledButton>(find.descendant(of: submit, matching: find.byType(FilledButton))).onPressed, isNull);

      await tester.enterText(find.byKey(const Key('admin.signIn.email')), 'reviewer@example.com');
      await tester.enterText(find.byKey(const Key('admin.signIn.password')), 'secret-password');
      await tester.pump();
      await tester.tap(submit);
      await settle(tester);
      expect(auth.calls, <String>['signIn:reviewer@example.com']);

      expect(find.byKey(const Key('admin.signIn.code')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('admin.signIn.code')), '123456');
      await settle(tester);
      expect(auth.calls.last, 'verifyCode:123456');
    });

    testWidgets('a parent account is told it cannot open the panel', (WidgetTester tester) async {
      final FakeAdminAuthRepository auth = FakeAdminAuthRepository()
        ..failure = const AdminFailure(AdminFailureKind.notAdmin);
      await pumpAdminPanel(tester, session: const AdminSignedOut(), location: AdminRoutes.signIn, auth: auth, locale: 'en');
      await tester.enterText(find.byKey(const Key('admin.signIn.email')), 'parent@example.com');
      await tester.enterText(find.byKey(const Key('admin.signIn.password')), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const Key('admin.signIn.submit')));
      await settle(tester);
      expect(find.text('This account cannot open the admin panel.'), findsOneWidget);
    });

    testWidgets('parents and signed-out visitors never reach a panel screen', (WidgetTester tester) async {
      for (final AdminSessionState session in <AdminSessionState>[const AdminNotAllowed(), const AdminSignedOut()]) {
        final FakeAdminApi api = FakeAdminApi();
        await pumpAdminPanel(tester, session: session, location: AdminRoutes.queue, api: api, locale: 'en');
        expect(find.byKey(const Key('admin.signIn.email')), findsOneWidget);
        expect(api.calls, isEmpty, reason: 'no admin function is called');
      }
    });

    testWidgets('an admin without a second factor is sent to set it up', (WidgetTester tester) async {
      final FakeAdminAuthRepository auth = FakeAdminAuthRepository();
      await pumpAdminPanel(
        tester,
        session: const AdminNeedsSecondFactor(testReviewer),
        location: AdminRoutes.queue,
        auth: auth,
        locale: 'en',
      );
      await settle(tester);
      expect(auth.calls, contains('startTotpSetup'));
      expect(find.textContaining('JBSW Y3DP EHPK 3PXP'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('admin.setup.code')), '654321');
      await settle(tester);
      expect(auth.calls.last, 'finishTotpSetup:654321');
    });
  });

  group('verification', () {
    testWidgets('the queue lists cases; an empty queue says so', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.queue, locale: 'en');
      await settle(tester);
      expect(find.byKey(const Key('queue.case1')), findsOneWidget);
      expect(find.text('ID check: no match'), findsOneWidget);

      final FakeAdminApi empty = FakeAdminApi()..queueItems = const <QueueCase>[];
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.queue, api: empty, locale: 'en');
      await settle(tester);
      expect(find.text('All caught up'), findsOneWidget);
    });

    testWidgets('approve needs every check and the name check, then asks first', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: '/queue/case1', api: api, locale: 'en', size: const Size(1280, 2400));
      await settle(tester);
      expect(api.calls, <String>['openCase:case1']);

      FilledButton approve() => tester.widget<FilledButton>(
        find.descendant(of: find.byKey(const Key('case.approve')), matching: find.byType(FilledButton)),
      );
      expect(approve().onPressed, isNull);

      for (final String check in <String>['photos', 'selfie', 'headTurn', 'idValid']) {
        await tester.tap(find.byKey(Key('case.check.$check')));
        await tester.pump();
      }
      expect(approve().onPressed, isNull, reason: 'the name check is still open');
      await choose(tester, const Key('case.nameCheck'), 'Birth certificate seen');
      expect(approve().onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('case.approve')));
      await settle(tester);
      await tester.tap(find.text('Approve').last);
      await settle(tester);
      expect(api.decisions.single, <String, Object?>{
        'caseId': 'case1',
        'approve': true,
        'nameCheck': NameCheck.birthCertificate,
        'reason': null,
        'note': null,
        'ban': false,
      });
    });

    testWidgets('reject with a reason', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: '/queue/case1', api: api, locale: 'en', size: const Size(1280, 2400));
      await settle(tester);
      await tester.tap(find.byKey(const Key('case.reject')));
      await settle(tester);
      await choose(tester, const Key('reject.reason'), 'Selfie does not match');
      await tester.tap(find.byKey(const Key('reject.submit')));
      await settle(tester);
      expect(api.decisions.single['approve'], isFalse);
      expect(api.decisions.single['reason'], RejectionReason.selfieMismatch);
      expect(api.decisions.single['ban'], isFalse);
    });

    testWidgets('documents without an image link say so', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: '/queue/case1', locale: 'en', size: const Size(1280, 2400));
      await settle(tester);
      // No images in the fake case: each document shows "No image".
      expect(find.text('No image'), findsWidgets);
    });
  });

  group('users', () {
    testWidgets('search shows masked phones only', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.users, api: api, locale: 'en');
      expect(find.text('Find a parent'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('users.query')), '01000000001');
      await tester.pump();
      await tester.tap(find.byKey(const Key('users.search')));
      await settle(tester);
      expect(api.calls, <String>['search:01000000001']);
      expect(find.textContaining('+20********01', findRichText: true), findsOneWidget);
    });

    testWidgets('a rate-limited search says to wait', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi()..failure = const AdminFailure(AdminFailureKind.rateLimited);
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.users, api: api, locale: 'en');
      await tester.enterText(find.byKey(const Key('users.query')), 'Mona');
      await tester.pump();
      await tester.tap(find.byKey(const Key('users.search')));
      await settle(tester);
      expect(find.text('Too many searches. Wait 10 minutes, then search again.'), findsOneWidget);
    });

    testWidgets('suspend asks for a reason and a confirmation', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: '/users/parent1', api: api, locale: 'en', size: const Size(1280, 1600));
      await settle(tester);
      await tester.tap(find.byKey(const Key('user.suspend')));
      await settle(tester);
      await choose(tester, const Key('moderation.reason'), 'Reports from parents');
      await tester.tap(find.byKey(const Key('moderation.submit')));
      await settle(tester);
      await tester.tap(find.text('Suspend').last);
      await settle(tester);
      expect(api.moderations.single.$2, ModerationAction.suspend);
      expect(api.moderations.single.$3, ModerationReason.reports);
    });
  });

  group('schools', () {
    testWidgets('a new school needs names, governorate, city and a pin inside Egypt', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.newSchool, api: api, locale: 'en', size: const Size(1280, 1600));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('school.nameAr')), 'مدرسة الاختبار');
      await tester.enterText(find.byKey(const Key('school.nameEn')), 'Test School');
      await tester.enterText(find.byKey(const Key('school.city')), 'Maadi');
      await choose(tester, const Key('school.governorate'), 'Cairo');
      await tester.enterText(find.byKey(const Key('school.pin')), '48.85, 2.35');
      await tester.pump();
      expect(find.text('This point is outside Egypt. Check the order: latitude first.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('school.pin')), '29.9602, 31.2569');
      await tester.pump();
      await tester.tap(find.byKey(const Key('school.save')));
      await settle(tester);
      expect(api.savedSchools.single.pin.lat, 29.9602);
      expect(api.savedSchools.single.governorate, 'cairo');
    });

    testWidgets('a typed "Other" school is merged into an existing one', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(tester, session: signedIn, location: '/other-schools/p1', api: api, locale: 'en', size: const Size(1280, 1600));
      await settle(tester);
      await tester.tap(find.byKey(const Key('school.merge')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('merge.s1')));
      await settle(tester);
      await tester.tap(find.text('Merge').last);
      await settle(tester);
      expect(api.calls, contains('merge:p1>s1'));
    });
  });

  group('audit log and roles', () {
    testWidgets('the audit log lists actions, read only', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.audit, locale: 'en');
      await settle(tester);
      expect(find.text('Case approved'), findsOneWidget);
      expect(find.text('School added'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('only super admins see Admins', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.queue, locale: 'en');
      expect(find.text('Admins'), findsNothing);
      await pumpAdminPanel(tester, session: const AdminSignedIn(testSuperAdmin), location: AdminRoutes.admins, locale: 'en');
      await settle(tester);
      expect(find.text('Admins'), findsWidgets);
      expect(find.byKey(const Key('admins.admin1')), findsOneWidget);
    });
  });
}
