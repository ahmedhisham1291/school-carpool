import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/onboarding/account_status_badge.dart';
import 'package:school_carpool/features/onboarding/sign_out.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Where an account that is not verified yet lands (spec section 10,
/// screen 9), and the verification status screen (Prompt 3, F2):
/// - unverified: why and what it takes, "Start verification";
/// - pending: "Under review" and what happens next;
/// - rejected: the reason (and the reviewer's note) with "Fix and resubmit";
/// - suspended: no access, sign out only.
/// A verified account never sees it: the router opens the app.
///
/// States: loading (skeleton until the account record arrives) and the
/// statuses above. Errors and offline are handled by the start screen,
/// which the router shows when the session cannot load.
class VerifyAccountScreen extends ConsumerWidget {
  const VerifyAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final Account? account = accountOf(ref.watch(sessionProvider));

    if (account == null) {
      return Scaffold(
        appBar: AppBar(title: AppBarTitle(l10n.verifyTitle)),
        body: const Skeleton(
          child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow()]),
        ),
      );
    }

    if (account.status == AccountStatus.suspended) {
      return Scaffold(
        body: SafeArea(
          child: AppStateView(
            icon: Icons.block_rounded,
            title: l10n.suspendedTitle,
            body: l10n.suspendedBody,
            tone: AppStateTone.error,
            actionLabel: l10n.profileSignOut,
            onAction: () => unawaited(confirmAndSignOut(context, ref)),
          ),
        ),
      );
    }

    final VerificationSummary? summary = account.verification;
    final RejectionReason? reason = summary?.reason;
    final String? note = summary?.note;
    final bool canSubmit = account.status == AccountStatus.unverified || account.status == AccountStatus.rejected;
    final String statusBody = switch (account.status) {
      AccountStatus.pending => l10n.verifyPendingBody,
      AccountStatus.rejected => l10n.verifyRejectedBody,
      _ => l10n.verifyBody,
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.verifyTitle)),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s24),
                children: <Widget>[
                  Padding(
                    padding: AppSpacing.screenPadding,
                    child: AppCard(
                      key: const Key('verify.statusCard'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          AccountStatusBadge(status: account.status),
                          const SizedBox(height: AppSpacing.s16),
                          Text(statusBody, style: context.text.bodyLarge),
                          if (account.status == AccountStatus.rejected && reason != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.s16),
                            OneLineText(l10n.verifyRejectedReasonLabel, style: context.text.titleSmall),
                            const SizedBox(height: AppSpacing.s4),
                            Text(
                              rejectionReasonText(l10n, reason),
                              key: const Key('verify.reason'),
                              style: context.text.bodyLarge,
                            ),
                          ],
                          if (account.status == AccountStatus.rejected && note != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.s16),
                            OneLineText(l10n.verifyReviewerNoteLabel, style: context.text.titleSmall),
                            const SizedBox(height: AppSpacing.s4),
                            Text(note, key: const Key('verify.note'), style: context.text.bodyLarge),
                          ],
                        ],
                      ),
                    ),
                  ),
                  // Short one-line row titles; the detail goes in the subtitle.
                  if (account.status == AccountStatus.pending) ...<Widget>[
                    AppSectionHeader(l10n.verifyPendingNextTitle),
                    AppListRow(
                      title: l10n.verifyPendingNext1Title,
                      subtitle: l10n.verifyPendingNext1,
                      leadingIcon: Icons.fact_check_outlined,
                    ),
                    AppListRow(
                      title: l10n.verifyPendingNext2Title,
                      subtitle: l10n.verifyPendingNext2,
                      leadingIcon: Icons.notifications_outlined,
                    ),
                    AppListRow(
                      title: l10n.verifyPendingNext3Title,
                      subtitle: l10n.verifyPendingNext3,
                      leadingIcon: Icons.delete_sweep_outlined,
                    ),
                  ] else ...<Widget>[
                    AppSectionHeader(l10n.verifyStepsTitle),
                    AppListRow(
                      title: l10n.verifyStepId,
                      subtitle: l10n.verifyStepIdDetail,
                      leadingIcon: Icons.badge_outlined,
                    ),
                    AppListRow(
                      title: l10n.verifyStepSelfie,
                      subtitle: l10n.verifyStepSelfieDetail,
                      leadingIcon: Icons.face_outlined,
                    ),
                    AppListRow(
                      title: l10n.verifyStepChild,
                      subtitle: l10n.verifyStepChildDetail,
                      leadingIcon: Icons.school_outlined,
                    ),
                    AppListRow(
                      title: l10n.verifyStepDriver,
                      subtitle: l10n.verifyStepDriverDetail,
                      leadingIcon: Icons.directions_car_outlined,
                    ),
                    Padding(
                      padding: AppSpacing.screenPadding,
                      child: AppInlineMessage(message: l10n.verifyPrivacyNote, icon: Icons.lock_outline_rounded),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (account.status == AccountStatus.pending && summary != null) ...<Widget>[
                    AppButton(
                      key: const Key('verify.withdraw'),
                      label: l10n.verifyWithdraw,
                      variant: AppButtonVariant.secondary,
                      expand: true,
                      onPressed: () => unawaited(_withdraw(context, ref, summary.caseId)),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                  ],
                  if (canSubmit) ...<Widget>[
                    AppButton(
                      key: const Key('verify.start'),
                      label: account.status == AccountStatus.rejected ? l10n.verifyResubmit : l10n.verifyStart,
                      expand: true,
                      onPressed: () => context.go(AuthRoutes.verifySubmit),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                  ],
                  AppButton(
                    key: const Key('verify.openProfile'),
                    label: l10n.verifyOpenProfile,
                    variant: canSubmit ? AppButtonVariant.tertiary : AppButtonVariant.primary,
                    expand: true,
                    onPressed: () => context.go(AppTab.profile.path),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Takes the documents out of review after a confirmation (they are
/// deleted and the parent can send them again).
Future<void> _withdraw(BuildContext context, WidgetRef ref, String caseId) async {
  final AppLocalizations l10n = context.l10n;
  final VerificationRepository repository = ref.read(verificationRepositoryProvider);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool ok = await showConfirmDialog(
    context: context,
    title: l10n.verifyWithdrawTitle,
    body: l10n.verifyWithdrawBody,
    confirmLabel: l10n.verifyWithdraw,
    destructive: true,
  );
  if (!ok) {
    return;
  }
  try {
    await repository.withdraw(caseId);
    showAppSnackBarOn(messenger, l10n.verifyWithdrawn);
  } on VerificationFailure {
    showAppSnackBarOn(messenger, l10n.verifyWithdrawFailed);
  }
}
