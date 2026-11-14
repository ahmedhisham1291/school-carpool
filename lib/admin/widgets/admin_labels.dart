import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Short display texts for codes in the admin panel. Every label fits on
/// one line in Arabic and English.

String governorateLabel(AppLocalizations l10n, String code) => switch (code) {
  'alexandria' => l10n.adminGovAlexandria,
  'aswan' => l10n.adminGovAswan,
  'asyut' => l10n.adminGovAsyut,
  'beheira' => l10n.adminGovBeheira,
  'beni_suef' => l10n.adminGovBeniSuef,
  'cairo' => l10n.adminGovCairo,
  'dakahlia' => l10n.adminGovDakahlia,
  'damietta' => l10n.adminGovDamietta,
  'faiyum' => l10n.adminGovFaiyum,
  'gharbia' => l10n.adminGovGharbia,
  'giza' => l10n.adminGovGiza,
  'ismailia' => l10n.adminGovIsmailia,
  'kafr_el_sheikh' => l10n.adminGovKafrElSheikh,
  'luxor' => l10n.adminGovLuxor,
  'matruh' => l10n.adminGovMatruh,
  'minya' => l10n.adminGovMinya,
  'monufia' => l10n.adminGovMonufia,
  'new_valley' => l10n.adminGovNewValley,
  'north_sinai' => l10n.adminGovNorthSinai,
  'port_said' => l10n.adminGovPortSaid,
  'qalyubia' => l10n.adminGovQalyubia,
  'qena' => l10n.adminGovQena,
  'red_sea' => l10n.adminGovRedSea,
  'sharqia' => l10n.adminGovSharqia,
  'sohag' => l10n.adminGovSohag,
  'south_sinai' => l10n.adminGovSouthSinai,
  'suez' => l10n.adminGovSuez,
  _ => code,
};

String accountStatusLabel(AppLocalizations l10n, AccountStatus status, {bool banned = false}) {
  if (banned) {
    return l10n.adminStatusBanned;
  }
  return switch (status) {
    AccountStatus.unverified => l10n.statusUnverified,
    AccountStatus.pending => l10n.statusPending,
    AccountStatus.verified => l10n.statusVerified,
    AccountStatus.rejected => l10n.statusRejected,
    AccountStatus.suspended => l10n.statusSuspended,
  };
}

AppBadgeTone accountStatusTone(AccountStatus status, {bool banned = false}) => switch (status) {
  _ when banned => AppBadgeTone.error,
  AccountStatus.verified => AppBadgeTone.success,
  AccountStatus.pending => AppBadgeTone.warning,
  AccountStatus.rejected || AccountStatus.suspended => AppBadgeTone.error,
  AccountStatus.unverified => AppBadgeTone.neutral,
};

/// Short reason labels for the reviewer (the parent sees the longer texts).
String rejectionReasonShort(AppLocalizations l10n, RejectionReason reason) => switch (reason) {
  RejectionReason.photoUnclear => l10n.adminRejPhotoUnclear,
  RejectionReason.idMismatch => l10n.adminRejIdMismatch,
  RejectionReason.selfieMismatch => l10n.adminRejSelfieMismatch,
  RejectionReason.livenessFailed => l10n.adminRejLiveness,
  RejectionReason.idExpired => l10n.adminRejIdExpired,
  RejectionReason.schoolIdUnclear => l10n.adminRejSchoolId,
  RejectionReason.childNameMismatch => l10n.adminRejChildName,
  RejectionReason.licenseInvalid => l10n.adminRejLicense,
  RejectionReason.other => l10n.adminRejOther,
};

String moderationReasonLabel(AppLocalizations l10n, ModerationReason reason) => switch (reason) {
  ModerationReason.reports => l10n.adminModReports,
  ModerationReason.fakeDocuments => l10n.adminModFakeDocs,
  ModerationReason.unsafeDriving => l10n.adminModUnsafeDriving,
  ModerationReason.harassment => l10n.adminModHarassment,
  ModerationReason.duplicateAccount => l10n.adminModDuplicate,
  ModerationReason.other => l10n.adminModOther,
};

String moderationActionLabel(AppLocalizations l10n, ModerationAction action) => switch (action) {
  ModerationAction.suspend => l10n.adminActionSuspend,
  ModerationAction.unsuspend => l10n.adminActionUnsuspend,
  ModerationAction.ban => l10n.adminActionBan,
};

String kycLabel(AppLocalizations l10n, KycResult? result) => switch (result) {
  KycResult.match => l10n.adminKycMatch,
  KycResult.noMatch => l10n.adminKycNoMatch,
  KycResult.error => l10n.adminKycError,
  null => l10n.adminKycNone,
};

AppBadgeTone kycTone(KycResult? result) => switch (result) {
  KycResult.match => AppBadgeTone.success,
  KycResult.noMatch => AppBadgeTone.error,
  KycResult.error || null => AppBadgeTone.warning,
};

/// Audit log and history actions, for example "verification.approve".
String auditActionLabel(AppLocalizations l10n, String action) => switch (action) {
  'admin.signIn' => l10n.adminAuditSignIn,
  'admin.create' => l10n.adminAuditAdminCreate,
  'admin.disable' => l10n.adminAuditAdminDisable,
  'admin.enable' => l10n.adminAuditAdminEnable,
  'verification.view' => l10n.adminAuditCaseView,
  'verification.approve' || 'verification.approved' => l10n.adminAuditApprove,
  'verification.reject' || 'verification.rejected' => l10n.adminAuditReject,
  'verification.ban' => l10n.adminAuditCaseBan,
  'verification.withdraw' => l10n.adminWithdrawn,
  'user.search' => l10n.adminAuditUserSearch,
  'user.view' => l10n.adminAuditUserView,
  'user.suspend' => l10n.adminActionSuspend,
  'user.unsuspend' => l10n.adminActionUnsuspend,
  'user.ban' => l10n.adminActionBan,
  'school.create' => l10n.adminAuditSchoolCreate,
  'school.update' => l10n.adminAuditSchoolUpdate,
  'school.approve' => l10n.adminAuditSchoolApprove,
  'school.merge' => l10n.adminAuditSchoolMerge,
  'area.create' => l10n.adminAuditAreaCreate,
  'area.update' => l10n.adminAuditAreaUpdate,
  // Prompt 11B.
  'wallet.view' => l10n.adminAuditWalletView,
  'wallet.transfers.view' => l10n.adminAuditWalletLog,
  'wallet.freeze' => l10n.adminWalletFreeze,
  'wallet.unfreeze' => l10n.adminWalletUnfreeze,
  'wallet.alert.resolve' => l10n.adminWalletResolve,
  // Pilot feature switches and Settle up (F45).
  'feature.on' => l10n.adminAuditFeatureOn,
  'feature.off' => l10n.adminAuditFeatureOff,
  'settle-up.view' => l10n.adminAuditSettleView,
  // Prompt 13.
  'device.check.approved' => l10n.adminAuditDeviceApproved,
  'device.check.confirmedOtherWay' => l10n.adminAuditDeviceOther,
  _ => action,
};

String reportTargetLabel(AppLocalizations l10n, String type) => switch (type) {
  'user' => l10n.adminReportUser,
  'message' => l10n.adminReportMessage,
  'group' => l10n.adminReportGroup,
  _ => type,
};

String reportReasonLabel(AppLocalizations l10n, String reason) => switch (reason) {
  'spam' => l10n.adminReportSpam,
  'harassment' => l10n.adminModHarassment,
  'fake_profile' => l10n.adminReportFake,
  'unsafe_driving' => l10n.adminModUnsafeDriving,
  // Prompt 9 (chat reports).
  'inappropriate' => l10n.adminReportInappropriate,
  'privacy' => l10n.adminReportPrivacy,
  'childSafety' => l10n.adminReportChildSafety,
  'dangerousDriving' => l10n.adminModUnsafeDriving,
  _ => l10n.adminModOther,
};

/// Prompt 9: which chat a report came from.
String reportKindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'private' => l10n.chatKindPrivate,
  'school' => l10n.chatKindSchool,
  'area' => l10n.chatKindArea,
  'carpool' => l10n.chatKindCarpool,
  _ => '',
};

String adminRoleLabel(AppLocalizations l10n, AdminRole role) =>
    role == AdminRole.superAdmin ? l10n.adminRoleSuper : l10n.adminRoleAdmin;

String accessReasonLabel(AppLocalizations l10n, AccessReasonCode r) => switch (r) {
  AccessReasonCode.review => l10n.adminAccessReview,
  AccessReasonCode.investigation => l10n.adminAccessInvestigation,
  AccessReasonCode.report => l10n.adminAccessReport,
  AccessReasonCode.legalRequest => l10n.adminAccessLegal,
  AccessReasonCode.parentRequest => l10n.adminAccessParent,
  AccessReasonCode.appeal => l10n.adminAccessAppeal,
};

String deviceOutcomeLabel(AppLocalizations l10n, DeviceCheckOutcome o) => switch (o) {
  DeviceCheckOutcome.approved => l10n.adminDeviceOutcomeApproved,
  DeviceCheckOutcome.confirmedOtherWay => l10n.adminDeviceOutcomeOther,
};
