import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum AdminFailureKind {
  wrongPassword,
  wrongCode,
  tooManyAttempts,
  notAdmin,
  mfaRequired,
  sessionExpired,
  notSuperAdmin,
  rateLimited,
  invalid,
  notFound,
  alreadyExists,
  invalidState,
  ownAccount,
  targetIsAdmin,
  alreadyDecided,
  nameCheckMissing,

  /// The feature is switched off (Settings): its functions refuse.
  featureOff,
  offline,
  unknown,
}

/// An admin panel problem with a message that says what to do. Built from
/// `details.reason` of our functions or from Firebase Auth errors.
class AdminFailure implements Exception {
  const AdminFailure(this.kind, {this.field});

  factory AdminFailure.from(Object error) {
    if (error is AdminFailure) {
      return error;
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      String? reason;
      String? field;
      if (details is Map<Object?, Object?>) {
        final Object? r = details['reason'];
        final Object? f = details['field'];
        reason = r is String ? r : null;
        field = f is String ? f : null;
      }
      final AdminFailureKind kind = switch (reason) {
        'not-admin' || 'unauthenticated' => AdminFailureKind.notAdmin,
        'mfa-required' => AdminFailureKind.mfaRequired,
        // Over 8 hours, idle for 15 minutes on the server, or the admin was
        // disabled (tokens revoked): sign in again.
        'session-expired' || 'session-idle' || 'session-revoked' => AdminFailureKind.sessionExpired,
        'not-super-admin' => AdminFailureKind.notSuperAdmin,
        'rate-limited' => AdminFailureKind.rateLimited,
        'invalid-request' || 'invalid-decision' => AdminFailureKind.invalid,
        'not-found' => AdminFailureKind.notFound,
        'already-exists' => AdminFailureKind.alreadyExists,
        'invalid-state' => AdminFailureKind.invalidState,
        'own-account' || 'own-case' => AdminFailureKind.ownAccount,
        'target-is-admin' => AdminFailureKind.targetIsAdmin,
        'already-decided' => AdminFailureKind.alreadyDecided,
        'name-check-missing' => AdminFailureKind.nameCheckMissing,
        'feature-off' => AdminFailureKind.featureOff,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => AdminFailureKind.offline,
          'unauthenticated' => AdminFailureKind.sessionExpired,
          _ => AdminFailureKind.unknown,
        },
      };
      return AdminFailure(kind, field: field);
    }
    if (error is FirebaseAuthException) {
      return AdminFailure(switch (error.code) {
        'wrong-password' || 'user-not-found' || 'invalid-credential' || 'invalid-email' || 'user-disabled' =>
          AdminFailureKind.wrongPassword,
        // The blocking function refuses accounts that are not admins.
        'permission-denied' || 'internal-error' => AdminFailureKind.notAdmin,
        'invalid-verification-code' || 'invalid-mfa-pending-credential' || 'missing-code' =>
          AdminFailureKind.wrongCode,
        'too-many-requests' => AdminFailureKind.tooManyAttempts,
        'network-request-failed' => AdminFailureKind.offline,
        'requires-recent-login' || 'user-token-expired' => AdminFailureKind.sessionExpired,
        _ => AdminFailureKind.unknown,
      });
    }
    return const AdminFailure(AdminFailureKind.unknown);
  }

  final AdminFailureKind kind;

  /// The form field the server refused, when it said.
  final String? field;

  bool get isOffline => kind == AdminFailureKind.offline;

  String message(AppLocalizations l10n) => switch (kind) {
    AdminFailureKind.wrongPassword => l10n.adminErrWrongPassword,
    AdminFailureKind.wrongCode => l10n.adminErrWrongCode,
    AdminFailureKind.tooManyAttempts => l10n.adminErrTooMany,
    AdminFailureKind.notAdmin => l10n.adminErrNotAdmin,
    AdminFailureKind.mfaRequired => l10n.adminErrMfa,
    AdminFailureKind.sessionExpired => l10n.adminErrSession,
    AdminFailureKind.notSuperAdmin => l10n.adminErrNotSuper,
    AdminFailureKind.rateLimited => l10n.adminErrRateLimited,
    AdminFailureKind.invalid => l10n.adminErrInvalid,
    AdminFailureKind.notFound => l10n.adminErrNotFound,
    AdminFailureKind.alreadyExists => l10n.adminErrExists,
    AdminFailureKind.invalidState => l10n.adminErrState,
    AdminFailureKind.ownAccount => l10n.adminErrOwn,
    AdminFailureKind.targetIsAdmin => l10n.adminErrTargetAdmin,
    AdminFailureKind.alreadyDecided => l10n.adminErrDecided,
    AdminFailureKind.nameCheckMissing => l10n.adminErrNameCheck,
    AdminFailureKind.featureOff => l10n.adminErrFeatureOff,
    AdminFailureKind.offline => l10n.adminErrOffline,
    AdminFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'AdminFailure(${kind.name})';
}
