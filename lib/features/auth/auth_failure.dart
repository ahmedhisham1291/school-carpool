import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum AuthFailureKind {
  invalidPhone,
  wrongCode,
  expiredCode,
  tooManyAttempts,
  locked,
  rateLimited,
  sendFailed,
  suspended,
  invalidEmail,
  emailInUse,
  outdatedTerms,

  /// The session was revoked or expired; sign in again with a new code.
  signInAgain,
  offline,
  unknown,
}

/// A sign-up or sign-in problem the parent can act on. Built from the
/// `details.reason` that our Cloud Functions send (functions/src/auth).
class AuthFailure implements AppFailure {
  const AuthFailure(this.kind, {this.demo, this.attemptsLeft, this.retryAfter});

  /// Maps any error from Firebase or our functions to a failure.
  factory AuthFailure.from(Object error) {
    if (error is AuthFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return AuthFailure(AuthFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      return _fromFunctions(error);
    }
    if (error is FirebaseAuthException) {
      return AuthFailure(switch (error.code) {
        'network-request-failed' => AuthFailureKind.offline,
        'too-many-requests' => AuthFailureKind.rateLimited,
        'invalid-email' => AuthFailureKind.invalidEmail,
        'email-already-in-use' => AuthFailureKind.emailInUse,
        'user-disabled' => AuthFailureKind.suspended,
        'user-token-expired' ||
        'invalid-user-token' ||
        'requires-recent-login' ||
        'user-not-found' => AuthFailureKind.signInAgain,
        _ => AuthFailureKind.unknown,
      });
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const AuthFailure(AuthFailureKind.offline);
    }
    return const AuthFailure(AuthFailureKind.unknown);
  }

  final AuthFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;
  final int? attemptsLeft;
  final Duration? retryAfter;

  @override
  bool get isOffline => kind == AuthFailureKind.offline;

  static AuthFailure _fromFunctions(FirebaseFunctionsException error) {
    final Object? details = error.details;
    String? reason;
    int? attemptsLeft;
    int? retryAfterSeconds;
    if (details is Map<Object?, Object?>) {
      final Object? r = details['reason'];
      final Object? a = details['attemptsLeft'];
      final Object? s = details['retryAfterSeconds'];
      reason = r is String ? r : null;
      attemptsLeft = a is num ? a.toInt() : null;
      retryAfterSeconds = s is num ? s.toInt() : null;
    }
    final Duration? retryAfter = retryAfterSeconds == null ? null : Duration(seconds: retryAfterSeconds);
    final AuthFailureKind kind = switch (reason) {
      'invalid-phone' => AuthFailureKind.invalidPhone,
      'wrong-code' => AuthFailureKind.wrongCode,
      'expired' => AuthFailureKind.expiredCode,
      'too-many-attempts' => AuthFailureKind.tooManyAttempts,
      'locked' => AuthFailureKind.locked,
      'rate-limited' || 'too-soon' => AuthFailureKind.rateLimited,
      'send-failed' => AuthFailureKind.sendFailed,
      'suspended' => AuthFailureKind.suspended,
      'outdated-terms' => AuthFailureKind.outdatedTerms,
      _ => switch (error.code) {
        'unavailable' || 'deadline-exceeded' => AuthFailureKind.offline,
        'unauthenticated' => AuthFailureKind.signInAgain,
        _ => AuthFailureKind.unknown,
      },
    };
    return AuthFailure(kind, attemptsLeft: attemptsLeft, retryAfter: retryAfter);
  }

  /// What to tell the parent, including how to fix it.
  @override
  String message(AppLocalizations l10n) {
    final String? demoText = demoRefusalText(l10n, demo);
    if (demoText != null) {
      return demoText;
    }
    final int seconds = retryAfter?.inSeconds ?? 60;
    final int minutes = seconds <= 60 ? 1 : (seconds + 59) ~/ 60;
    return switch (kind) {
      AuthFailureKind.invalidPhone => l10n.phoneErrorInvalid,
      AuthFailureKind.wrongCode => l10n.errorWrongCode(attemptsLeft ?? 0),
      AuthFailureKind.expiredCode => l10n.errorExpiredCode,
      AuthFailureKind.tooManyAttempts => l10n.errorTooManyAttempts,
      AuthFailureKind.locked => l10n.errorLocked(minutes),
      AuthFailureKind.rateLimited => l10n.errorRateLimited(minutes),
      AuthFailureKind.sendFailed => l10n.errorSendFailed,
      AuthFailureKind.suspended => l10n.errorSuspended,
      AuthFailureKind.invalidEmail => l10n.emailErrorInvalid,
      AuthFailureKind.emailInUse => l10n.errorEmailInUse,
      AuthFailureKind.outdatedTerms => l10n.errorOutdatedTerms,
      AuthFailureKind.signInAgain => l10n.errorSignInAgain,
      AuthFailureKind.offline => l10n.errorOffline,
      AuthFailureKind.unknown => l10n.errorGeneric,
    };
  }

  @override
  String toString() => 'AuthFailure(${kind.name})';
}

/// True when [error] means the phone has no connection.
bool isOfflineError(Object error) => AuthFailure.from(error).isOffline;
