import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Words for trust codes (Prompt 11). Every label is short: one line at
/// 320 dp in Arabic and English (test/trust/trust_screens_test.dart).

String ratingTagLabel(AppLocalizations l10n, RatingTag t) => switch (t) {
  RatingTag.onTime => l10n.rateTagOnTime,
  RatingTag.safeDriving => l10n.rateTagSafe,
  RatingTag.friendly => l10n.rateTagFriendly,
  RatingTag.clear => l10n.rateTagClear,
  RatingTag.late => l10n.rateTagLate,
  RatingTag.unsafeDriving => l10n.rateTagUnsafe,
  RatingTag.rude => l10n.rateTagRude,
};

String guardianRelationLabel(AppLocalizations l10n, GuardianRelation r) => switch (r) {
  GuardianRelation.father => l10n.relationFather,
  GuardianRelation.mother => l10n.relationMother,
  GuardianRelation.guardian => l10n.relationGuardian,
};

/// "Drove your child · 12 Nov 2026" / "Rode with you · ...".
String rateableSubtitle(BuildContext context, RateableParent p) {
  final AppLocalizations l10n = context.l10n;
  final String role = p.drove ? l10n.rateRoleDriver : l10n.rateRoleParent;
  final DateTime? date = p.date;
  return date == null ? role : '$role · ${MaterialLocalizations.of(context).formatMediumDate(date)}';
}

/// "4.6 from 5 ratings · 3 vouches", or "No ratings yet".
String summaryLine(AppLocalizations l10n, TrustSummary s) {
  if (s.ratings == 0) {
    return l10n.trustNoRatings;
  }
  final double? average = s.average;
  final String ratings = average == null ? l10n.trustRatingsCount(s.ratings) : l10n.trustAverage(average.toStringAsFixed(1), s.ratings);
  return '$ratings · ${l10n.trustVouches(s.vouches)}';
}

/// "2027/28".
String schoolYearLabel(AppLocalizations l10n, int year) => l10n.schoolYearName(year.toString(), ((year + 1) % 100).toString().padLeft(2, '0'));

/// Full-screen view for a failed load: offline, not verified, or an error with retry.
Widget trustErrorView(BuildContext context, TrustFailure f, VoidCallback retry) {
  final AppLocalizations l10n = context.l10n;
  return switch (f.kind) {
    TrustFailureKind.offline => OfflineStateView(onRetry: retry),
    TrustFailureKind.notVerified => EmptyStateView(
      key: const Key('trust.notVerified'),
      icon: Icons.verified_user_outlined,
      title: l10n.walletVerifyTitle,
      body: l10n.trustErrorNotVerified,
      actionLabel: l10n.walletVerifyAction,
      onAction: () => context.go(AuthRoutes.verifyAccount),
    ),
    _ => ErrorStateView(key: const Key('trust.error'), body: f.message(l10n), onRetry: retry),
  };
}
