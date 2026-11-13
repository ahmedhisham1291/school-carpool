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
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Where an account that is not verified yet lands (spec section 10,
/// screen 9). Explains why verification is needed and what it takes.
/// The capture steps arrive in Prompt 3, so the main action opens Profile
/// (the only other screen allowed before verification).
///
/// States: loading (skeleton until the account record arrives), the
/// status itself (unverified, pending, rejected), and suspended (no access,
/// sign out only). Errors and offline are handled by the start screen,
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          AccountStatusBadge(status: account.status),
                          const SizedBox(height: AppSpacing.s16),
                          Text(statusBody, style: context.text.bodyLarge),
                        ],
                      ),
                    ),
                  ),
                  AppSectionHeader(l10n.verifyStepsTitle),
                  // Short one-line titles; the detail goes in the subtitle.
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
                    child: AppInlineMessage(message: l10n.verifyComingSoon),
                  ),
                ],
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: AppButton(
                key: const Key('verify.openProfile'),
                label: l10n.verifyOpenProfile,
                expand: true,
                onPressed: () => context.go(AppTab.profile.path),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
