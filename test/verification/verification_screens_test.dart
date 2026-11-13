// Widget tests for verification (F2, F3): status screens (pending,
// rejected with reason and resubmit), the steps with a fake camera, submit,
// and the children list. Written, not run here (no Flutter SDK in the
// build workspace).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_flow_screen.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

Account _account(AccountStatus status, {VerificationSummary? verification}) => Account(
  parentId: 'ABCD2345',
  status: status,
  phone: '+201000000001',
  email: 'parent@example.com',
  emailVerified: true,
  termsAccepted: true,
  language: 'ar',
  verification: verification,
);

Future<GoRouter> _pump(
  WidgetTester tester, {
  required String location,
  required Account account,
  required FakeVerificationRepository repository,
  FakeCamera? camera,
  List<ChildRecord>? children,
}) async {
  tester.view.physicalSize = const Size(1200, 2800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testStagingConfig),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ...authOverrides(session: SessionSignedIn(uid: 'uid-1', account: account)),
        ...verificationOverrides(repository: repository, camera: camera, children: children),
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
  return router;
}

void main() {
  group('status screens', () {
    testWidgets('unverified: start verification opens the steps', (WidgetTester tester) async {
      final GoRouter router = await _pump(
        tester,
        location: AuthRoutes.verifyAccount,
        account: _account(AccountStatus.unverified),
        repository: FakeVerificationRepository(),
      );
      expect(find.text('Not verified'), findsOneWidget);
      await tester.tap(find.byKey(const Key('verify.start')));
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, AuthRoutes.verifySubmit);
      expect(find.text('Your details'), findsOneWidget);
    });

    testWidgets('pending: under review, what happens next, no submit button', (WidgetTester tester) async {
      await _pump(
        tester,
        location: AuthRoutes.verifyAccount,
        account: _account(
          AccountStatus.pending,
          verification: const VerificationSummary(caseId: 'c1', status: ReviewStatus.pending),
        ),
        repository: FakeVerificationRepository(),
      );
      expect(find.text('Under review'), findsOneWidget);
      expect(find.text('What happens next'), findsOneWidget);
      expect(find.byKey(const Key('verify.start')), findsNothing);
    });

    testWidgets('rejected: the reason, the reviewer note and resubmit', (WidgetTester tester) async {
      await _pump(
        tester,
        location: AuthRoutes.verifyAccount,
        account: _account(
          AccountStatus.rejected,
          verification: const VerificationSummary(
            caseId: 'c1',
            status: ReviewStatus.rejected,
            reason: RejectionReason.selfieMismatch,
            note: 'Please remove your sunglasses.',
          ),
        ),
        repository: FakeVerificationRepository(),
      );
      expect(find.text('Not approved'), findsOneWidget);
      expect(find.byKey(const Key('verify.reason')), findsOneWidget);
      expect(find.textContaining('Your selfie did not match the ID photo'), findsOneWidget);
      expect(find.text('Please remove your sunglasses.'), findsOneWidget);
      expect(find.text('Fix and resubmit'), findsOneWidget);
    });
  });

  group('verification steps', () {
    testWidgets('details are checked as typed; continue stays off until valid', (WidgetTester tester) async {
      await _pump(
        tester,
        location: AuthRoutes.verifySubmit,
        account: _account(AccountStatus.unverified),
        repository: FakeVerificationRepository(),
      );
      await tester.enterText(find.byKey(const Key('verify.nationalId')), '2900115');
      await tester.pump();
      expect(find.text('Enter all 14 digits.'), findsOneWidget);
      final FilledButton next = tester.widget<FilledButton>(
        find.descendant(of: find.byKey(const Key('verify.next')), matching: find.byType(FilledButton)),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('a full submission: photos from the camera, a child, consent, uploads, then the status screen', (
      WidgetTester tester,
    ) async {
      final FakeVerificationRepository repository = FakeVerificationRepository();
      final FakeCamera camera = FakeCamera();
      final GoRouter router = await _pump(
        tester,
        location: AuthRoutes.verifySubmit,
        account: _account(AccountStatus.unverified),
        repository: repository,
        camera: camera,
      );
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(VerificationFlowScreen)));
      // Details are filled through the draft (date pickers are tested by Flutter).
      container.read(verificationDraftProvider.notifier).update(
        (VerificationDraft d) => d.copyWith(
          firstName: 'Mona',
          lastName: 'Hassan',
          nationalId: '29001150123456',
          idExpiry: DateTime(DateTime.now().year + 2),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      // ID photos.
      await tester.tap(find.descendant(of: find.byKey(const Key('verify.idFront')), matching: find.text('Take photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byKey(const Key('verify.idBack')), matching: find.text('Take photo')));
      await tester.pumpAndSettle();
      expect(find.text('Photo taken'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      // Selfie with the liveness prompt: two photos.
      await tester.tap(find.text('Take selfie'));
      await tester.pumpAndSettle();
      expect(camera.requests.last.kind, CaptureKind.selfie);
      expect(container.read(verificationDraftProvider).selfieComplete, isTrue);
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      // A child.
      await tester.tap(find.byKey(const Key('verify.addChild')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('child.firstName')), 'Omar');
      await tester.tap(find.byKey(const Key('child.age')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('8 years').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('child.grade')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grade 3').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('child.school')), 'Nile School');
      await tester.tap(find.descendant(of: find.byKey(const Key('child.schoolIdTile')), matching: find.text('Take photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('child.save')));
      await tester.pumpAndSettle();
      expect(find.text('Omar'), findsOneWidget);
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      // Driving: skipped.
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      // Review: consent, then send.
      // The ID number is shown masked, never in full.
      expect(find.textContaining('3456'), findsOneWidget);
      expect(find.textContaining('29001150123456'), findsNothing);
      await tester.tap(find.byKey(const Key('verify.consent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();

      expect(repository.uploads, <String>['id_front.jpg', 'id_back.jpg', 'selfie.jpg', 'selfie_turn.jpg', 'school_id_c1.jpg']);
      expect(repository.submissions, hasLength(1));
      expect((repository.submissions.single['identity']! as Map<String, Object?>)['nationalId'], '29001150123456');
      expect(router.routerDelegate.currentConfiguration.uri.path, AuthRoutes.verifyAccount);
      expect(container.read(verificationDraftProvider).idFront, isNull, reason: 'captures are dropped after sending');
    });

    testWidgets('a duplicate ID is refused with a clear message', (WidgetTester tester) async {
      final FakeVerificationRepository repository = FakeVerificationRepository()
        ..submitFailure = const VerificationFailure(VerificationFailureKind.duplicateId);
      await _pump(
        tester,
        location: AuthRoutes.verifySubmit,
        account: _account(AccountStatus.unverified),
        repository: repository,
      );
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(VerificationFlowScreen)));
      container.read(verificationDraftProvider.notifier).update(
        (VerificationDraft d) => d.copyWith(
          firstName: 'Mona',
          lastName: 'Hassan',
          nationalId: '29001150123456',
          idExpiry: DateTime(DateTime.now().year + 2),
          idFront: fakePhoto,
          idBack: fakePhoto,
          selfie: fakePhoto,
          selfieTurn: fakePhoto,
          children: <ChildDraft>[
            ChildDraft(ref: 'c1', firstName: 'Omar', age: 8, grade: Grade.g3, schoolName: 'Nile', schoolIdPhoto: fakePhoto),
          ],
          consent: true,
        ),
      );
      for (int i = 0; i < VerificationStep.values.length - 1; i++) {
        await tester.tap(find.byKey(const Key('verify.next')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('verify.next')));
      await tester.pumpAndSettle();
      expect(find.textContaining('already used by another account'), findsOneWidget);
      expect(repository.submissions, isEmpty);
    });
  });

  group('children (F3)', () {
    const List<ChildRecord> kids = <ChildRecord>[
      ChildRecord(id: 'k1', firstName: 'Omar', age: 8, grade: Grade.g3, schoolName: 'Nile', status: ReviewStatus.approved),
      ChildRecord(
        id: 'k2',
        firstName: 'Laila',
        age: 5,
        grade: Grade.kg2,
        schoolName: 'Nile',
        status: ReviewStatus.rejected,
        reason: RejectionReason.schoolIdUnclear,
      ),
    ];

    testWidgets('a verified parent sees each child with its status and can remove one', (WidgetTester tester) async {
      final FakeVerificationRepository repository = FakeVerificationRepository();
      await _pump(
        tester,
        location: ProfileRoutes.children,
        account: _account(AccountStatus.verified),
        repository: repository,
        children: kids,
      );
      expect(find.text('Omar'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.textContaining('A school ID photo could not be read'), findsOneWidget);
      await tester.tap(find.text('Laila'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove child').last);
      await tester.pumpAndSettle();
      // Confirmation dialog.
      await tester.tap(find.widgetWithText(FilledButton, 'Remove child'));
      await tester.pumpAndSettle();
      expect(repository.removed, <String>['k2']);
    });

    testWidgets('while a review is pending, changes are paused', (WidgetTester tester) async {
      await _pump(
        tester,
        location: ProfileRoutes.children,
        account: _account(
          AccountStatus.verified,
          verification: const VerificationSummary(caseId: 'c2', status: ReviewStatus.pending, identity: false),
        ),
        repository: FakeVerificationRepository(),
        children: kids,
      );
      expect(find.text('Changes are paused while your documents are under review.'), findsOneWidget);
      final FilledButton add = tester.widget<FilledButton>(
        find.descendant(of: find.byKey(const Key('children.add')), matching: find.byType(FilledButton)),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('empty list before verification explains where children are added', (WidgetTester tester) async {
      await _pump(
        tester,
        location: ProfileRoutes.children,
        account: _account(AccountStatus.unverified),
        repository: FakeVerificationRepository(),
        children: const <ChildRecord>[],
      );
      expect(find.text('You add your children in the verification steps.'), findsOneWidget);
    });
  });
}
