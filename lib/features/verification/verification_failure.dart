import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum VerificationFailureKind {
  invalidDetails,
  invalidNationalId,
  idExpired,
  invalidChild,
  unknownSchool,
  invalidDriver,
  licenseExpired,
  duplicateId,
  bannedId,
  caseOpen,
  missingUpload,
  uploadFailed,
  outdatedConsent,

  /// R3: the typed name is not a full name, or does not match the ID name.
  signatureName,
  signatureMismatch,

  /// R3: no phone passcode and the sign-in is older than 10 minutes.
  reauthRequired,
  suspended,
  camera,
  cameraDenied,
  offline,
  unknown,
}

/// A verification problem the parent can act on, from the `details.reason`
/// our functions send (functions/src/verification/submission.ts) or from
/// Storage and the camera.
class VerificationFailure implements AppFailure {
  const VerificationFailure(this.kind, {this.demo, this.missing = const <String>[]});

  factory VerificationFailure.from(Object error) {
    if (error is VerificationFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return VerificationFailure(VerificationFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      String? reason;
      List<String> missing = const <String>[];
      if (details is Map<Object?, Object?>) {
        final Object? r = details['reason'];
        final Object? m = details['missing'];
        reason = r is String ? r : null;
        if (m is List<Object?>) {
          missing = m.whereType<String>().toList();
        }
      }
      final VerificationFailureKind kind = switch (reason) {
        'invalid-name' || 'invalid-expiry' || 'invalid-request' || 'missing-children' || 'too-many-children' =>
          VerificationFailureKind.invalidDetails,
        'invalid-national-id' => VerificationFailureKind.invalidNationalId,
        'id-expired' => VerificationFailureKind.idExpired,
        'invalid-child' => VerificationFailureKind.invalidChild,
        'unknown-school' => VerificationFailureKind.unknownSchool,
        'invalid-driver' => VerificationFailureKind.invalidDriver,
        'license-expired' => VerificationFailureKind.licenseExpired,
        'duplicate-id' => VerificationFailureKind.duplicateId,
        'banned-id' => VerificationFailureKind.bannedId,
        'case-open' => VerificationFailureKind.caseOpen,
        'missing-upload' => VerificationFailureKind.missingUpload,
        'outdated-consent' => VerificationFailureKind.outdatedConsent,
        'signature-name' || 'signature-required' => VerificationFailureKind.signatureName,
        'signature-name-mismatch' => VerificationFailureKind.signatureMismatch,
        'reauth-required' => VerificationFailureKind.reauthRequired,
        'suspended' => VerificationFailureKind.suspended,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => VerificationFailureKind.offline,
          _ => VerificationFailureKind.unknown,
        },
      };
      return VerificationFailure(kind, missing: missing);
    }
    if (error is FirebaseException) {
      // Storage: 'retry-limit-exceeded' means the connection kept dropping.
      return VerificationFailure(switch (error.code) {
        'unavailable' || 'retry-limit-exceeded' || 'network-request-failed' => VerificationFailureKind.offline,
        _ => VerificationFailureKind.uploadFailed,
      });
    }
    return const VerificationFailure(VerificationFailureKind.unknown);
  }

  final VerificationFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  /// Upload names the server did not find (missingUpload).
  final List<String> missing;

  @override
  bool get isOffline => kind == VerificationFailureKind.offline;

  /// What to tell the parent, including what to do.
  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    VerificationFailureKind.invalidDetails => l10n.verifyErrorDetails,
    VerificationFailureKind.invalidNationalId => l10n.idNumberErrorInvalid,
    VerificationFailureKind.idExpired => l10n.idExpiryErrorPast,
    VerificationFailureKind.invalidChild => l10n.verifyErrorChild,
    VerificationFailureKind.unknownSchool => l10n.verifyErrorSchool,
    VerificationFailureKind.invalidDriver => l10n.verifyErrorDriver,
    VerificationFailureKind.licenseExpired => l10n.verifyErrorLicenseExpired,
    VerificationFailureKind.duplicateId => l10n.verifyErrorDuplicate,
    VerificationFailureKind.bannedId => l10n.verifyErrorBanned,
    VerificationFailureKind.caseOpen => l10n.verifyErrorCaseOpen,
    VerificationFailureKind.missingUpload || VerificationFailureKind.uploadFailed => l10n.verifyErrorUpload,
    VerificationFailureKind.outdatedConsent => l10n.errorOutdatedTerms,
    VerificationFailureKind.signatureName => l10n.signNameError,
    VerificationFailureKind.signatureMismatch => l10n.signNameMismatchShort,
    VerificationFailureKind.reauthRequired => l10n.signReauth,
    VerificationFailureKind.suspended => l10n.errorSuspended,
    VerificationFailureKind.camera => l10n.captureErrorCamera,
    VerificationFailureKind.cameraDenied => l10n.captureErrorDenied,
    VerificationFailureKind.offline => l10n.verifyErrorOffline,
    VerificationFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'VerificationFailure(${kind.name})';
}
