import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Texts of the privacy screens (Prompt 12). Every data type the app keeps
/// is listed with what it is, who sees it and how long it is kept.

String dataTypeTitle(AppLocalizations l10n, DataType t) => switch (t) {
  DataType.account => l10n.dataAccount,
  DataType.consents => l10n.dataConsents,
  DataType.idPhotos => l10n.dataIdPhotos,
  DataType.children => l10n.dataChildren,
  DataType.vehicle => l10n.dataVehicle,
  DataType.home => l10n.dataHome,
  DataType.carpools => l10n.dataCarpools,
  DataType.schedule => l10n.dataSchedule,
  DataType.trips => l10n.dataTrips,
  DataType.liveLocation => l10n.dataLiveLocation,
  DataType.routeArchive => l10n.dataRouteArchive,
  DataType.chat => l10n.dataChat,
  DataType.ratings => l10n.dataRatings,
  DataType.familyLinks => l10n.dataFamilyLinks,
  DataType.handover => l10n.dataHandover,
  DataType.emergencyContact => l10n.dataEmergencyContact,
  DataType.notifications => l10n.dataNotifications,
  DataType.devices => l10n.dataDevices,
  DataType.wallet => l10n.dataWallet,
  DataType.settleUp => l10n.dataSettleUp,
  DataType.reports => l10n.dataReports,
  DataType.analytics => l10n.dataAnalytics,
  DataType.crashReports => l10n.dataCrashReports,
};

/// What it holds, why, and who sees it (one short paragraph).
String dataTypeBody(AppLocalizations l10n, DataType t) => switch (t) {
  DataType.account => l10n.dataAccountBody,
  DataType.consents => l10n.dataConsentsBody,
  DataType.idPhotos => l10n.dataIdPhotosBody,
  DataType.children => l10n.dataChildrenBody,
  DataType.vehicle => l10n.dataVehicleBody,
  DataType.home => l10n.dataHomeBody,
  DataType.carpools => l10n.dataCarpoolsBody,
  DataType.schedule => l10n.dataScheduleBody,
  DataType.trips => l10n.dataTripsBody,
  DataType.liveLocation => l10n.dataLiveLocationBody,
  DataType.routeArchive => l10n.dataRouteArchiveBody,
  DataType.chat => l10n.dataChatBody,
  DataType.ratings => l10n.dataRatingsBody,
  DataType.familyLinks => l10n.dataFamilyLinksBody,
  DataType.handover => l10n.dataHandoverBody,
  DataType.emergencyContact => l10n.dataEmergencyContactBody,
  DataType.notifications => l10n.dataNotificationsBody,
  DataType.devices => l10n.dataDevicesBody,
  DataType.wallet => l10n.dataWalletBody,
  DataType.settleUp => l10n.dataSettleUpBody,
  DataType.reports => l10n.dataReportsBody,
  DataType.analytics => l10n.dataAnalyticsBody,
  DataType.crashReports => l10n.dataCrashReportsBody,
};

String keepLabel(AppLocalizations l10n, Keep k) => switch (k) {
  Keep.untilDeletion => l10n.keepUntilDeletion,
  Keep.yearAfterClosure => l10n.keepYearAfterClosure,
  Keep.threeYearsAfterClosure => l10n.keepThreeYearsAfterClosure,
  Keep.oneDay => l10n.keepOneDay,
  Keep.yearAfterRun => l10n.keepYearAfterRun,
  Keep.yearAfterChat => l10n.keepYearAfterChat,
  Keep.sixtyDays => l10n.keepSixtyDays,
  Keep.ninetyDays => l10n.keepNinetyDays,
  Keep.days180 => l10n.keepDays180,
  Keep.law => l10n.keepLaw,
  Keep.untilHandled => l10n.keepUntilHandled,
};

String consentTitle(AppLocalizations l10n, ConsentKind k) => switch (k) {
  ConsentKind.terms => l10n.consentTerms,
  ConsentKind.privacy => l10n.consentPrivacy,
  ConsentKind.conduct => l10n.consentConduct,
  ConsentKind.transferAbroad => l10n.consentTransferAbroad,
  ConsentKind.whatsapp => l10n.consentWhatsapp,
  ConsentKind.id => l10n.consentId,
  ConsentKind.face => l10n.consentFace,
  ConsentKind.childData => l10n.consentChildData,
  ConsentKind.teenAgreement => l10n.consentTeenAgreement,
  ConsentKind.walletTerms => l10n.consentWalletTerms,
  ConsentKind.analytics => l10n.consentAnalytics,
  ConsentKind.showOnMap => l10n.consentShowOnMap,
};

String requestTitle(AppLocalizations l10n, PrivacyRequest r) => switch (r.kind) {
  RequestKind.exportData => l10n.requestExport,
  RequestKind.delete => l10n.requestDelete,
  RequestKind.correct => l10n.requestCorrect,
  RequestKind.withdraw => l10n.requestWithdraw,
  RequestKind.consent => l10n.requestConsent,
  RequestKind.photoCopy => l10n.requestPhotoCopy,
};

(String, AppBadgeTone) requestStatus(AppLocalizations l10n, RequestStatus s) => switch (s) {
  RequestStatus.done => (l10n.requestDone, AppBadgeTone.success),
  RequestStatus.open => (l10n.requestOpen, AppBadgeTone.warning),
  RequestStatus.refused => (l10n.requestRefused, AppBadgeTone.neutral),
  RequestStatus.failed => (l10n.requestFailed, AppBadgeTone.error),
};

String platformLabel(AppLocalizations l10n, DevicePlatform p) => switch (p) {
  DevicePlatform.ios => l10n.deviceIphone,
  DevicePlatform.android => l10n.deviceAndroid,
  DevicePlatform.web => l10n.deviceWeb,
};

/// "14 Nov 2026" in the app's language (Latin digits; dates are LTR-safe).
String shortDate(BuildContext context, DateTime utc) =>
    DateFormat.yMMMd(Localizations.localeOf(context).languageCode).format(utc.toLocal());

/// "14 Nov 2026, 09:30".
String shortDateTime(BuildContext context, DateTime utc) =>
    DateFormat.yMMMd(Localizations.localeOf(context).languageCode).add_Hm().format(utc.toLocal());

/// Full-screen error or offline view with Retry.
Widget privacyErrorView(BuildContext context, PrivacyFailure failure, VoidCallback onRetry) => failure.isOffline
    ? OfflineStateView(onRetry: onRetry)
    : ErrorStateView(body: failure.message(context.l10n), onRetry: onRetry);
