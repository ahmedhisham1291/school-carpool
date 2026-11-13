// Admin panel logic (F14): session from the ID token, the router gate,
// map pin input, parsing of function results, error mapping.
// Written, not run here (no Flutter SDK in the build workspace).
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/geo_pin_input.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/two_step_setup_screen.dart';
import 'package:school_carpool/features/auth/account.dart';

import '../helpers/admin_fakes.dart';

void main() {
  final DateTime now = DateTime(2026, 11, 13, 12);

  AdminSessionState sessionFor(Map<String, dynamic>? claims, {String? factor = 'totp', Duration age = Duration.zero, bool mfa = true}) =>
      adminSessionFor(
        uid: 'u1',
        email: 'a@example.com',
        displayName: 'A Admin',
        claims: claims,
        secondFactor: factor,
        authTime: now.subtract(age),
        now: now,
        mfaRequired: mfa,
      );

  group('adminSessionFor', () {
    test('an admin with the second factor is signed in, with the role', () {
      final AdminSessionState s = sessionFor(<String, dynamic>{'admin': true});
      expect(s, isA<AdminSignedIn>());
      expect((s as AdminSignedIn).user.role, AdminRole.admin);
      final AdminSessionState sup = sessionFor(<String, dynamic>{'admin': true, 'superAdmin': true});
      expect((sup as AdminSignedIn).user.isSuperAdmin, isTrue);
    });

    test('a parent or any account without the admin claim is not allowed', () {
      expect(sessionFor(<String, dynamic>{'verified': true}), isA<AdminNotAllowed>());
      expect(sessionFor(null), isA<AdminNotAllowed>());
      expect(sessionFor(<String, dynamic>{'superAdmin': true}), isA<AdminNotAllowed>());
    });

    test('an admin without the second factor must add it (not on the emulators)', () {
      expect(sessionFor(<String, dynamic>{'admin': true}, factor: null), isA<AdminNeedsSecondFactor>());
      expect(sessionFor(<String, dynamic>{'admin': true}, factor: null, mfa: false), isA<AdminSignedIn>());
    });

    test('a sign-in older than 8 hours has expired', () {
      final AdminSessionState s = sessionFor(<String, dynamic>{'admin': true}, age: const Duration(hours: 8, minutes: 1));
      expect(s, isA<AdminSignedOut>());
      expect((s as AdminSignedOut).reason, AdminSignOutReason.expired);
    });
  });

  group('adminRedirect', () {
    test('signed out, loading and parents only reach sign-in', () {
      for (final String path in <String>[AdminRoutes.queue, AdminRoutes.users, AdminRoutes.audit, '/queue/case1']) {
        expect(adminRedirect(const AdminSignedOut(), path), AdminRoutes.signIn);
        expect(adminRedirect(const AdminNotAllowed(), path), AdminRoutes.signIn);
        expect(adminRedirect(const AdminSessionLoading(), path), AdminRoutes.starting);
      }
      expect(adminRedirect(const AdminSignedOut(), AdminRoutes.signIn), isNull);
    });

    test('an admin without the second factor only sets it up', () {
      expect(adminRedirect(const AdminNeedsSecondFactor(testReviewer), AdminRoutes.queue), AdminRoutes.twoStepSetup);
      expect(adminRedirect(const AdminNeedsSecondFactor(testReviewer), AdminRoutes.twoStepSetup), isNull);
    });

    test('a signed-in admin uses the panel; Admins is for super admins', () {
      expect(adminRedirect(const AdminSignedIn(testReviewer), AdminRoutes.signIn), AdminRoutes.queue);
      expect(adminRedirect(const AdminSignedIn(testReviewer), AdminRoutes.users), isNull);
      expect(adminRedirect(const AdminSignedIn(testReviewer), AdminRoutes.admins), AdminRoutes.queue);
      expect(adminRedirect(const AdminSignedIn(testSuperAdmin), AdminRoutes.admins), isNull);
    });
  });

  group('parsePin', () {
    test('reads a pin copied from Google Maps, Arabic digits too', () {
      expect(parsePin('29.9602, 31.2569').$1?.lat, 29.9602);
      expect(parsePin('29.9602 31.2569').$1?.lng, 31.2569);
      expect(parsePin('٢٩٫٩٦٠٢، ٣١٫٢٥٦٩').$1?.lat, 29.9602);
    });

    test('refuses bad input and points outside Egypt (swapped order)', () {
      expect(parsePin('29.96').$2, PinError.format);
      expect(parsePin('abc, def').$2, PinError.format);
      expect(parsePin('31.2569, 29.9602').$2, isNull, reason: 'still inside Egypt');
      expect(parsePin('48.85, 2.35').$2, PinError.outsideEgypt);
      expect(formatPin(const GeoPin(29.96, 31.2569)), '29.96000, 31.25690');
    });
  });

  group('parsing', () {
    test('a case with identity, children and signed links', () {
      final CaseDetail c = CaseDetail.fromJson(
        Json.of(const <Object?, Object?>{
          'caseId': 'c1',
          'uid': 'p1',
          'scope': 'identity',
          'status': 'awaiting_review',
          'identity': <Object?, Object?>{'firstName': 'Mona', 'lastName': 'Test', 'idExpiry': '2030-01-31', 'livenessChallenge': 'right'},
          'children': <Object?>[
            <Object?, Object?>{'childId': 'k1', 'firstName': 'Omar Test', 'age': 8, 'grade': 'g3', 'schoolName': 'Nile', 'imageUrl': 'https://x/1'},
          ],
          'driver': null,
          'kyc': <Object?, Object?>{'result': 'no_match', 'score': 0.4},
          'submittedAtMs': 1000,
          'images': <Object?, Object?>{'id_front.jpg': 'https://x/2'},
        }),
      );
      expect(c.fullName, 'Mona Test');
      expect(c.children.single.imageUrl, 'https://x/1');
      expect(c.kycResult, KycResult.noMatch);
      expect(c.images['id_front.jpg'], 'https://x/2');
      expect(c.driver, isNull);
      expect(c.decided, isFalse);
    });

    test('a user summary keeps the phone masked as sent', () {
      final UserSummary u = UserSummary.fromJson(
        Json.of(const <Object?, Object?>{'uid': 'p1', 'parentId': 'ABCD2345', 'status': 'suspended', 'banned': true, 'phone': '+20********01'}),
      );
      expect(u.status, AccountStatus.suspended);
      expect(u.banned, isTrue);
      expect(u.maskedPhone, '+20********01');
    });

    test('the school input sends the pin', () {
      const SchoolInput input = SchoolInput(nameAr: 'م', nameEn: 'S', governorate: 'cairo', city: 'Maadi', pin: GeoPin(29.9, 31.2));
      expect(input.toJson().containsKey('id'), isFalse);
      expect(input.toJson()['location'], <String, Object?>{'lat': 29.9, 'lng': 31.2});
    });
  });

  test('AdminFailure reads details.reason from the functions', () {
    AdminFailure from(String reason, [String code = 'permission-denied']) => AdminFailure.from(
      FirebaseFunctionsException(message: reason, code: code, details: <Object?, Object?>{'reason': reason}),
    );
    expect(from('mfa-required').kind, AdminFailureKind.mfaRequired);
    expect(from('session-expired').kind, AdminFailureKind.sessionExpired);
    expect(from('session-idle').kind, AdminFailureKind.sessionExpired);
    expect(from('session-revoked').kind, AdminFailureKind.sessionExpired);
    expect(from('rate-limited', 'resource-exhausted').kind, AdminFailureKind.rateLimited);
    expect(from('name-check-missing', 'failed-precondition').kind, AdminFailureKind.nameCheckMissing);
    expect(AdminFailure.from(FirebaseFunctionsException(message: 'x', code: 'unavailable')).isOffline, isTrue);
  });

  test('the setup key is grouped by 4 for typing', () {
    expect(groupedSetupKey('JBSWY3DPEHPK3PXP'), 'JBSW Y3DP EHPK 3PXP');
  });
}
