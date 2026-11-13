// Logic of identity verification (F2, F3): national ID checks, the draft
// and its payload, uploads that resume, failures, the status record and
// the router gate. Written, not run here (no Flutter SDK in the build
// workspace).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/national_id.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

import '../helpers/verification_fakes.dart';

final DateTime today = DateTime(2026, 11, 13);
const String fakeId = '29001150123456';

VerificationDraft completeDraft() => VerificationDraft(
  challenge: LivenessChallenge.right,
  firstName: 'Mona',
  lastName: 'Hassan',
  nationalId: fakeId,
  idExpiry: DateTime(2030, 5),
  idFront: fakePhoto,
  idBack: fakePhoto,
  selfie: fakePhoto,
  selfieTurn: fakePhoto,
  children: <ChildDraft>[
    ChildDraft(
      ref: 'c1',
      firstName: 'Omar',
      age: 8,
      grade: Grade.g3,
      schoolId: 'nile',
      schoolName: 'Nile School',
      schoolIdPhoto: fakePhoto,
    ),
  ],
  consent: true,
);

Account account(AccountStatus status, {VerificationSummary? verification}) => Account(
  parentId: 'ABCD2345',
  status: status,
  phone: '+201000000001',
  email: 'parent@example.com',
  emailVerified: true,
  termsAccepted: true,
  language: 'ar',
  verification: verification,
);

void main() {
  group('EgyptNationalId', () {
    test('accepts a valid number, with Arabic digits too', () {
      expect(EgyptNationalId.check(fakeId, today), isNull);
      expect(EgyptNationalId.check('٢٩٠٠١١٥٠١٢٣٤٥٦', today), isNull);
    });

    test('says what is wrong', () {
      expect(EgyptNationalId.check('2900115', today), NationalIdProblem.length);
      expect(EgyptNationalId.check('19001150123456', today), NationalIdProblem.invalid);
      expect(EgyptNationalId.check('29002300123456', today), NationalIdProblem.invalid);
      expect(EgyptNationalId.check('29001159923456', today), NationalIdProblem.invalid);
      expect(EgyptNationalId.check('30811140112345', today), NationalIdProblem.underAge);
      expect(EgyptNationalId.check('30811130112345', today), isNull);
    });
  });

  group('VerificationDraft', () {
    test('a complete draft is ready and lists every upload', () {
      final VerificationDraft draft = completeDraft();
      expect(draft.readyToSubmit(today), isTrue);
      expect(draft.files().keys, <String>[
        'id_front.jpg',
        'id_back.jpg',
        'selfie.jpg',
        'selfie_turn.jpg',
        'school_id_c1.jpg',
      ]);
    });

    test('needs consent, a child, both selfies and a valid expiry', () {
      expect(completeDraft().copyWith(consent: false).readyToSubmit(today), isFalse);
      expect(completeDraft().copyWith(children: <ChildDraft>[]).readyToSubmit(today), isFalse);
      expect(
        const VerificationDraft(challenge: LivenessChallenge.left).copyWith(selfie: fakePhoto).selfieComplete,
        isFalse,
      );
      expect(completeDraft().copyWith(idExpiry: DateTime(2026, 11, 12)).detailsComplete(today), isFalse);
      expect(completeDraft().copyWith(firstName: 'M0na').detailsComplete(today), isFalse);
    });

    test('driving details are needed only when driving', () {
      final VerificationDraft driving = completeDraft().copyWith(drives: true);
      expect(driving.readyToSubmit(today), isFalse);
      final VerificationDraft full = driving.copyWith(
        driver: DriverDraft(
          plate: 'ق ط ر 1234',
          model: 'Toyota Corolla',
          color: 'White',
          seats: 4,
          licenseExpiry: DateTime(2029),
          carLicenseExpiry: DateTime(2027, 6, 30),
          licensePhoto: fakePhoto,
          carLicensePhoto: fakePhoto,
        ),
      );
      expect(full.readyToSubmit(today), isTrue);
      expect(full.files().keys, containsAll(<String>['license.jpg', 'car_license.jpg']));
      expect((full.toPayload()['driver']! as Map<String, Object?>)['licenseExpiry'], '2029-01-01');
    });

    test('the payload matches the server fields and holds no images', () {
      final Map<String, Object?> payload = completeDraft().toPayload();
      final Map<String, Object?> identity = payload['identity']! as Map<String, Object?>;
      expect(identity['nationalId'], fakeId);
      expect(identity['idExpiry'], '2030-05-01');
      expect(identity['livenessChallenge'], 'right');
      expect(payload['driver'], isNull);
      expect(payload['consents'], <String, String>{'id': '2026-11-13', 'face': '2026-11-13', 'childData': '2026-11-13'});
      final List<Map<String, Object?>> children = payload['children']! as List<Map<String, Object?>>;
      expect(children.single, <String, Object?>{
        'ref': 'c1',
        'childId': null,
        'firstName': 'Omar',
        'age': 8,
        'grade': 'g3',
        'schoolId': 'nile',
        'schoolName': 'Nile School',
      });
    });

    test('a child needs a school picked from the list (F4)', () {
      final ChildDraft typedOnly = ChildDraft(
        ref: 'c1',
        firstName: 'Omar',
        age: 8,
        grade: Grade.g3,
        schoolName: 'Nile',
        schoolIdPhoto: fakePhoto,
      );
      expect(typedOnly.isComplete, isFalse);
      final ChildDraft picked = ChildDraft(
        ref: 'c1',
        firstName: 'Omar',
        age: 8,
        grade: Grade.g3,
        schoolId: 'nile',
        schoolName: 'Nile',
        schoolIdPhoto: fakePhoto,
      );
      expect(picked.isComplete, isTrue);
    });

    test('child slots are c1 to c10, reusing freed ones', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final VerificationDraftController controller = container.read(verificationDraftProvider.notifier);
      for (int i = 0; i < VerificationDraftController.maxChildren; i++) {
        controller.saveChild(ChildDraft(ref: controller.newChildRef()!));
      }
      expect(controller.newChildRef(), isNull);
      controller.removeChild('c4');
      expect(controller.newChildRef(), 'c4');
    });

    test('a retake forgets that the old photo was uploaded', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      final VerificationDraftController controller = container.read(verificationDraftProvider.notifier)
        ..markUploaded('id_front.jpg')
        ..markUploaded('selfie.jpg');
      controller.setPhoto(VerificationDocument.idFront, fakePhoto);
      expect(container.read(verificationDraftProvider).uploaded, <String>{'selfie.jpg'});
      controller.reset();
      expect(container.read(verificationDraftProvider).uploaded, isEmpty);
    });
  });

  group('uploadAndSubmit', () {
    Future<String> run(FakeVerificationRepository repository, Set<String> uploaded) => uploadAndSubmit(
      repository: repository,
      uid: 'uid-1',
      files: completeDraft().files(),
      payload: completeDraft().toPayload(),
      isUploaded: uploaded.contains,
      markUploaded: uploaded.add,
      forgetUploads: uploaded.removeAll,
    );

    test('a broken upload is resumed: the retry sends only what is missing', () async {
      final FakeVerificationRepository repository = FakeVerificationRepository()..failUploadsOf.add('selfie.jpg');
      final Set<String> uploaded = <String>{};
      await expectLater(run(repository, uploaded), throwsA(isA<VerificationFailure>()));
      expect(repository.uploads, <String>['id_front.jpg', 'id_back.jpg']);
      expect(repository.submissions, isEmpty);

      repository.uploads.clear();
      expect(await run(repository, uploaded), 'case-1');
      expect(repository.uploads, <String>['selfie.jpg', 'selfie_turn.jpg', 'school_id_c1.jpg']);
    });

    test('uploads again what the server says is missing, then submits once', () async {
      final FakeVerificationRepository repository = FakeVerificationRepository()
        ..submitFailure = const VerificationFailure(
          VerificationFailureKind.missingUpload,
          missing: <String>['id_back.jpg'],
        );
      final Set<String> uploaded = <String>{};
      expect(await run(repository, uploaded), 'case-1');
      expect(repository.uploads.where((String n) => n == 'id_back.jpg'), hasLength(2));
      expect(repository.submissions, hasLength(1));
    });
  });

  group('VerificationFailure', () {
    FirebaseFunctionsException err(String code, Map<String, Object?> details) =>
        FirebaseFunctionsException(code: code, message: 'x', details: details);

    test('maps server reasons', () {
      expect(VerificationFailure.from(err('already-exists', <String, Object?>{'reason': 'duplicate-id'})).kind,
          VerificationFailureKind.duplicateId);
      expect(VerificationFailure.from(err('permission-denied', <String, Object?>{'reason': 'banned-id'})).kind,
          VerificationFailureKind.bannedId);
      final VerificationFailure missing = VerificationFailure.from(
        err('failed-precondition', <String, Object?>{'reason': 'missing-upload', 'missing': <Object?>['selfie.jpg']}),
      );
      expect(missing.kind, VerificationFailureKind.missingUpload);
      expect(missing.missing, <String>['selfie.jpg']);
      expect(VerificationFailure.from(err('unavailable', <String, Object?>{})).isOffline, isTrue);
      expect(VerificationFailure.from(StateError('x')).kind, VerificationFailureKind.unknown);
    });
  });

  group('records', () {
    test('the status summary reads the reason and note', () {
      final VerificationSummary? summary = VerificationSummary.fromMap(<String, dynamic>{
        'caseId': 'c1',
        'scope': 'identity',
        'status': 'rejected',
        'reasonCode': 'selfie_mismatch',
        'note': 'Glasses',
      });
      expect(summary?.status, ReviewStatus.rejected);
      expect(summary?.reason, RejectionReason.selfieMismatch);
      expect(summary?.note, 'Glasses');
      expect(VerificationSummary.fromMap(null), isNull);
      expect(RejectionReason.fromCode('new_reason'), RejectionReason.other);
    });

    test('the account record reads the verification summary', () {
      final Account a = Account.fromMap(const <String, dynamic>{
        'parentId': 'ABCD2345',
        'status': 'pending',
        'firstName': 'Mona',
        'verification': <String, dynamic>{'caseId': 'c1', 'status': 'pending', 'scope': 'identity'},
      });
      expect(a.firstName, 'Mona');
      expect(a.reviewPending, isTrue);
      expect(account(AccountStatus.verified).reviewPending, isFalse);
    });

    test('children and grades', () {
      final ChildRecord child = ChildRecord.fromDoc('k1', const <String, dynamic>{
        'firstName': 'Omar',
        'age': 8,
        'grade': 'kg2',
        'schoolName': 'Nile',
        'schoolId': 'nile',
        'status': 'approved',
      });
      expect(child.schoolId, 'nile');
      expect(child.grade, Grade.kg2);
      expect(child.status, ReviewStatus.approved);
      expect(parseIsoDate('2030-05-01'), DateTime(2030, 5));
      expect(isoDate(DateTime(2030, 5)), '2030-05-01');
    });
  });

  group('token refresh after a decision (claims marker)', () {
    Account withMarker(AccountStatus status, int? marker) => Account(
      parentId: 'ABCD2345',
      status: status,
      phone: '+201000000001',
      email: 'parent@example.com',
      emailVerified: true,
      termsAccepted: true,
      language: 'ar',
      claimsUpdatedAtMs: marker,
    );

    test('refreshes when the marker changes, not when only the status changes', () {
      expect(
        tokenRefreshFor(first: false, previousMarker: null, account: withMarker(AccountStatus.verified, null)),
        TokenRefresh.none,
      );
      expect(
        tokenRefreshFor(first: false, previousMarker: null, account: withMarker(AccountStatus.verified, 1000)),
        TokenRefresh.force,
      );
      expect(
        tokenRefreshFor(first: false, previousMarker: 1000, account: withMarker(AccountStatus.verified, 1000)),
        TokenRefresh.none,
      );
      expect(
        tokenRefreshFor(first: false, previousMarker: 1000, account: withMarker(AccountStatus.rejected, 2000)),
        TokenRefresh.force,
      );
    });

    test('the first record of a verified account checks the cached token', () {
      expect(
        tokenRefreshFor(first: true, previousMarker: null, account: withMarker(AccountStatus.verified, 1000)),
        TokenRefresh.ifClaimMissing,
      );
      expect(
        tokenRefreshFor(first: true, previousMarker: null, account: withMarker(AccountStatus.pending, null)),
        TokenRefresh.none,
      );
      expect(tokenRefreshFor(first: false, previousMarker: null, account: null), TokenRefresh.none);
    });

    test('the marker is read from the record', () {
      final Account a = Account.fromMap(<String, dynamic>{
        'parentId': 'ABCD2345',
        'status': 'verified',
        'claimsUpdatedAt': Timestamp.fromMillisecondsSinceEpoch(5000),
      });
      expect(a.claimsUpdatedAtMs, 5000);
    });
  });

  group('router gate', () {
    SessionState signedIn(AccountStatus status) => SessionSignedIn(uid: 'u1', account: account(status));

    test('submission is open while unverified or rejected', () {
      expect(sessionRedirect(signedIn(AccountStatus.unverified), AuthRoutes.verifySubmit), isNull);
      expect(sessionRedirect(signedIn(AccountStatus.rejected), AuthRoutes.verifySubmit), isNull);
    });

    test('not while pending, verified or suspended', () {
      expect(sessionRedirect(signedIn(AccountStatus.pending), AuthRoutes.verifySubmit), AuthRoutes.verifyAccount);
      expect(sessionRedirect(signedIn(AccountStatus.verified), AuthRoutes.verifySubmit), AppRoutes.initial);
      expect(sessionRedirect(signedIn(AccountStatus.suspended), AuthRoutes.verifySubmit), AuthRoutes.verifyAccount);
    });

    test('children and driving pages sit under Profile', () {
      expect(sessionRedirect(signedIn(AccountStatus.pending), ProfileRoutes.children), isNull);
      expect(sessionRedirect(signedIn(AccountStatus.unverified), ProfileRoutes.driving), isNull);
    });
  });
}
