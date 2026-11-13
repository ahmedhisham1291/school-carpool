import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/onboarding/account_status_badge.dart';
import 'package:school_carpool/features/onboarding/sign_out.dart';
import 'package:school_carpool/features/settings/settings_section.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Profile tab (spec section 10): parent ID with a copy button (F44), the
/// account's status, phone and email, children and driving (Prompt 3),
/// settings, About (with the OpenStreetMap credit, Prompt 4B) and sign out. The wallet comes in a later prompt.
///
/// States: loading (skeleton), empty (signed out or record not created
/// yet), error and offline (full-screen with retry). Settings stay usable
/// in every state.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final SessionState session = ref.watch(sessionProvider);
    void retry() => ref.invalidate(sessionStreamProvider);

    final List<Widget> top = switch (session) {
      SessionSignedIn(account: final Account account) => _accountSection(context, account),
      SessionSignedIn() || SessionLoading() => const <Widget>[_ProfileSkeleton()],
      SessionFailed(offline: true) => <Widget>[
        SizedBox(height: _stateHeight, child: OfflineStateView(onRetry: retry)),
      ],
      SessionFailed() => <Widget>[
        SizedBox(height: _stateHeight, child: ErrorStateView(onRetry: retry)),
      ],
      SessionSignedOut() => <Widget>[
        SizedBox(
          height: _stateHeight,
          child: EmptyStateView(icon: Icons.person_outline_rounded, body: l10n.placeholderProfileBody),
        ),
      ],
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.tabProfile)),
      body: ListView(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          ...top,
          const SettingsSection(),
          AppListRow(
            key: const Key('profile.about'),
            title: l10n.aboutTitle,
            subtitle: l10n.profileAboutHelper,
            leadingIcon: Icons.info_outline_rounded,
            onTap: () => context.go(ProfileRoutes.about),
          ),
          if (session is SessionSignedIn)
            Padding(
              padding: AppSpacing.screenPadding,
              child: AppButton(
                key: const Key('profile.signOut'),
                label: l10n.profileSignOut,
                icon: Icons.logout_rounded,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => unawaited(confirmAndSignOut(context, ref)),
              ),
            ),
        ],
      ),
    );
  }

  static const double _stateHeight = AppSpacing.s64 * 6;

  List<Widget> _accountSection(BuildContext context, Account account) {
    final AppLocalizations l10n = context.l10n;
    final String? email = account.email;
    final (String statusLabel, _, IconData statusIcon) = AccountStatusBadge.describe(
      account.status,
      l10n,
    );
    return <Widget>[
      if (account.status != AccountStatus.verified)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            AppSpacing.screenGutter,
            AppSpacing.s16,
            AppSpacing.screenGutter,
            0,
          ),
          child: AppCard(
            onTap: () => context.go(AuthRoutes.verifyAccount),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(l10n.profileVerifyBanner, style: context.text.bodyMedium)),
                const SizedBox(width: AppSpacing.s8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: context.colors.onSurfaceVariant,
                  size: AppIconSize.sm,
                ),
              ],
            ),
          ),
        ),
      Padding(
        padding: AppSpacing.screenPadding,
        child: AppCard(
          child: AppCopyValue(
            key: const Key('profile.parentId'),
            label: l10n.profileParentIdLabel,
            value: account.parentId,
            helperText: l10n.profileParentIdHelper,
          ),
        ),
      ),
      AppSectionHeader(l10n.profileAccountSection),
      // The status as the subtitle, not a trailing badge: the one-line
      // title keeps its room at 320 dp and at 200 percent text.
      AppListRow(
        title: l10n.profileStatus,
        subtitle: statusLabel,
        leadingIcon: statusIcon,
      ),
      AppListRow(
        title: l10n.profilePhone,
        subtitle: EgyptPhone.display(account.phone),
        leadingIcon: Icons.phone_iphone_rounded,
      ),
      AppListRow(
        title: l10n.emailLabel,
        subtitle: email == null ? l10n.profileEmailMissing : ltrIsolate(email),
        leadingIcon: Icons.mail_outline_rounded,
      ),
      AppSectionHeader(l10n.profileFamilySection),
      AppListRow(
        key: const Key('profile.children'),
        title: l10n.childrenTitle,
        subtitle: l10n.profileChildrenHelper,
        leadingIcon: Icons.child_care_outlined,
        onTap: () => context.go(ProfileRoutes.children),
      ),
      AppListRow(
        key: const Key('profile.driving'),
        title: l10n.drivingTitle,
        subtitle: l10n.profileDrivingHelper,
        leadingIcon: Icons.directions_car_outlined,
        onTap: () => context.go(ProfileRoutes.driving),
      ),
    ];
  }
}

class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(padding: AppSpacing.screenPadding, child: SkeletonCard()),
        SkeletonListRow(),
        SkeletonListRow(),
        SkeletonListRow(),
      ],
    ),
  );
}
