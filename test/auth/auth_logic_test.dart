// Sign-up logic (F1, F44): phone numbers, account record, error mapping,
// install ID and the router gate. Written, not run here (no Flutter SDK in
// the build workspace); CI runs `flutter test`.

import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/digits_input_formatter.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/install_id.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

Account _account({
  AccountStatus status = AccountStatus.unverified,
  bool emailVerified = true,
  bool termsAccepted = true,
}) => Account(
  parentId: 'ABCD2345',
  status: status,
  phone: '+201000000001',
  email: 'parent@example.com',
  emailVerified: emailVerified,
  termsAccepted: termsAccepted,
  language: 'ar',
);

SessionState _signedIn(Account account) => SessionSignedIn(uid: 'u1', account: account);

void main() {
  group('EgyptPhone', () {
    test('accepts the usual ways of writing a mobile number', () {
      const Map<String, String> valid = <String, String>{
        '01012345678': '+201012345678',
        '1112345678': '+201112345678',
        '+20 122 123 4567': '+201221234567',
        '00201512345678': '+201512345678',
        '٠١٠١٢٣٤٥٦٧٨': '+201012345678',
      };
      for (final MapEntry<String, String> entry in valid.entries) {
        expect(EgyptPhone.toE164(entry.key), entry.value, reason: entry.key);
      }
    });

    test('refuses landlines, other countries and wrong lengths', () {
      for (final String input in <String>['', '0101234567', '010123456789', '01312345678', '0221234567', '+966501234567']) {
        expect(EgyptPhone.toE164(input), isNull, reason: input);
      }
    });

    test('displays left to right with spaces', () {
      expect(EgyptPhone.display('+201012345678'), ltrIsolate('+20 10 1234 5678'));
    });

    test('digits formatter converts Arabic digits and drops the rest', () {
      expect(DigitsInputFormatter.normalize('٠١٠-۱۲ 3a'), '010123');
    });
  });

  group('Account', () {
    test('reads the record written by the server', () {
      final Account account = Account.fromMap(const <String, dynamic>{
        'parentId': 'WXYZ6789',
        'status': 'pending',
        'phone': '+201000000002',
        'email': null,
        'emailVerified': false,
        'termsAcceptedAt': null,
        'language': 'en',
      });
      expect(account.parentId, 'WXYZ6789');
      expect(account.status, AccountStatus.pending);
      expect(account.stage, RegistrationStage.email);
    });

    test('an unknown status counts as unverified', () {
      expect(AccountStatus.fromName('admin'), AccountStatus.unverified);
    });

    test('stage follows email, then terms', () {
      expect(_account(emailVerified: false, termsAccepted: false).stage, RegistrationStage.email);
      expect(_account(termsAccepted: false).stage, RegistrationStage.terms);
      expect(_account().stage, RegistrationStage.complete);
    });
  });

  group('AuthFailure', () {
    FirebaseFunctionsException functionsError(String code, Map<String, Object?> details) =>
        FirebaseFunctionsException(message: code, code: code, details: details);

    test('maps the server reasons', () {
      final AuthFailure wrong = AuthFailure.from(
        functionsError('invalid-argument', <String, Object?>{'reason': 'wrong-code', 'attemptsLeft': 3}),
      );
      expect(wrong.kind, AuthFailureKind.wrongCode);
      expect(wrong.attemptsLeft, 3);

      final AuthFailure locked = AuthFailure.from(
        functionsError('resource-exhausted', <String, Object?>{'reason': 'locked', 'retryAfterSeconds': 3600}),
      );
      expect(locked.kind, AuthFailureKind.locked);
      expect(locked.retryAfter, const Duration(hours: 1));

      expect(
        AuthFailure.from(functionsError('failed-precondition', <String, Object?>{'reason': 'expired'})).kind,
        AuthFailureKind.expiredCode,
      );
      expect(
        AuthFailure.from(functionsError('resource-exhausted', <String, Object?>{'reason': 'too-soon'})).kind,
        AuthFailureKind.rateLimited,
      );
    });

    test('an ended session asks to sign in again', () {
      expect(
        AuthFailure.from(FirebaseAuthException(code: 'user-token-expired')).kind,
        AuthFailureKind.signInAgain,
      );
      expect(
        AuthFailure.from(functionsError('unauthenticated', <String, Object?>{})).kind,
        AuthFailureKind.signInAgain,
      );
    });

    test('no connection is offline', () {
      expect(AuthFailure.from(functionsError('unavailable', <String, Object?>{})).isOffline, isTrue);
      expect(AuthFailure.from(FirebaseAuthException(code: 'network-request-failed')).isOffline, isTrue);
      expect(isOfflineError(StateError('x')), isFalse);
    });
  });

  group('InstallId', () {
    test('is 32 hex characters and random', () {
      final String a = InstallId.generate(Random(1));
      final String b = InstallId.generate(Random(2));
      expect(InstallId.pattern.hasMatch(a), isTrue);
      expect(a, isNot(b));
    });
  });

  group('sessionRedirect', () {
    test('loading and failed sessions go to the start screen', () {
      expect(sessionRedirect(const SessionLoading(), '/home'), AuthRoutes.starting);
      expect(sessionRedirect(const SessionFailed(offline: true), '/profile'), AuthRoutes.starting);
      expect(sessionRedirect(const SessionLoading(), AuthRoutes.starting), isNull);
    });

    test('signed out: welcome, phone and code only', () {
      const SessionState out = SessionSignedOut();
      expect(sessionRedirect(out, '/home'), AuthRoutes.welcome);
      expect(sessionRedirect(out, '/profile'), AuthRoutes.welcome);
      expect(sessionRedirect(out, AuthRoutes.email), AuthRoutes.welcome);
      expect(sessionRedirect(out, AuthRoutes.phone), isNull);
      expect(sessionRedirect(out, AuthRoutes.code), isNull);
    });

    test('a new account waits on the start screen until its record exists', () {
      expect(sessionRedirect(const SessionSignedIn(uid: 'u1', account: null), '/home'), AuthRoutes.starting);
    });

    test('email first, then terms', () {
      expect(sessionRedirect(_signedIn(_account(emailVerified: false)), AuthRoutes.code), AuthRoutes.email);
      expect(sessionRedirect(_signedIn(_account(emailVerified: false)), '/profile'), AuthRoutes.email);
      expect(sessionRedirect(_signedIn(_account(termsAccepted: false)), AuthRoutes.email), AuthRoutes.terms);
      expect(sessionRedirect(_signedIn(_account(termsAccepted: false)), AuthRoutes.terms), isNull);
    });

    test('unverified, pending and rejected: verification screen and Profile only', () {
      for (final AccountStatus status in <AccountStatus>[
        AccountStatus.unverified,
        AccountStatus.pending,
        AccountStatus.rejected,
      ]) {
        final SessionState session = _signedIn(_account(status: status));
        expect(sessionRedirect(session, AuthRoutes.terms), AuthRoutes.verifyAccount);
        expect(sessionRedirect(session, AppTab.home.path), AuthRoutes.verifyAccount);
        expect(sessionRedirect(session, AppTab.chats.path), AuthRoutes.verifyAccount);
        expect(sessionRedirect(session, AuthRoutes.verifyAccount), isNull);
        expect(sessionRedirect(session, AppTab.profile.path), isNull);
      }
    });

    test('suspended: the verification screen only', () {
      final SessionState session = _signedIn(_account(status: AccountStatus.suspended));
      expect(sessionRedirect(session, AppTab.profile.path), AuthRoutes.verifyAccount);
      expect(sessionRedirect(session, AuthRoutes.verifyAccount), isNull);
    });

    test('verified: the full app, onboarding sends home', () {
      final SessionState session = _signedIn(_account(status: AccountStatus.verified));
      expect(sessionRedirect(session, AppTab.chats.path), isNull);
      expect(sessionRedirect(session, AuthRoutes.welcome), AppRoutes.initial);
      expect(sessionRedirect(session, AuthRoutes.verifyAccount), AppRoutes.initial);
    });

    test('the dev gallery is never redirected', () {
      expect(sessionRedirect(const SessionSignedOut(), AppRoutes.gallery), isNull);
    });
  });
}
