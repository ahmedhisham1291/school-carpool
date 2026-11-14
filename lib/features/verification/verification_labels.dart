import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Display texts for verification codes.

String gradeLabel(AppLocalizations l10n, Grade grade) => switch (grade) {
  Grade.kg1 => l10n.gradeKg1,
  Grade.kg2 => l10n.gradeKg2,
  _ => l10n.gradeNumber(grade.index - Grade.g1.index + 1),
};

String rejectionReasonText(AppLocalizations l10n, RejectionReason reason) => switch (reason) {
  RejectionReason.photoUnclear => l10n.reasonPhotoUnclear,
  RejectionReason.idMismatch => l10n.reasonIdMismatch,
  RejectionReason.selfieMismatch => l10n.reasonSelfieMismatch,
  RejectionReason.livenessFailed => l10n.reasonLivenessFailed,
  RejectionReason.idExpired => l10n.reasonIdExpired,
  RejectionReason.schoolIdUnclear => l10n.reasonSchoolIdUnclear,
  RejectionReason.childNameMismatch => l10n.reasonChildNameMismatch,
  RejectionReason.licenseInvalid => l10n.reasonLicenseInvalid,
  RejectionReason.other => l10n.reasonOther,
};

String reviewStatusLabel(AppLocalizations l10n, ReviewStatus status) => switch (status) {
  ReviewStatus.pending => l10n.statusPending,
  ReviewStatus.approved => l10n.reviewApproved,
  ReviewStatus.rejected => l10n.statusRejected,
  ReviewStatus.left => l10n.statusLeftSchool,
};
