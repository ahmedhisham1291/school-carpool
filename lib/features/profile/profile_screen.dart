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
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/maps/map_settings_section.dart';
import 'package:school_carpool/features/onboarding/account_status_badge.dart';
import 'package:school_carpool/features/onboarding/sign_out.dart';
import 'package:school_carpool/features/settings/settings_section.dart';
import 'package:school_carpool/features/trust/trust_profile_section.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Profile tab (spec section 10): parent ID with a copy button (F44), the
/// account's status, phone and email, children and driving (Prompt 3),
/// settings, About (with the OpenStreetMap credit, Prompt 4B), the wallet
/// (Prompt 11B), ratings, family links, the yearly check and the phone
/// change (Prompt 11) and sign out.
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
    // Pilot feature switches: rows of a switched-off feature are not shown.
    final FeatureSwitches features = ref.watch(featureSwitchesProvider);
    void retry() => ref.invalidate(sessionStreamProvider);

    final List<Widget> top = switch (session) {
      SessionSignedIn(account: final Account account) => _accountSection(context, account, features),
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
          const MapSettingsSection(),
          if (session is SessionSignedIn)
            AppListRow(
              key: const Key('profile.notifications'),
              title: l10n.notifSettingsTitle,
              subtitle: l10n.profileNotificationsHelper,
              leadingIcon: Icons.notifications_active_outlined,
              onTap: () => context.go(ProfileRoutes.notifications),
            ),
          // Prompt 12: see, correct, download and delete your data; consents; phones.
          if (session is SessionSignedIn)
            AppListRow(
              key: const Key('profile.privacy'),
              title: l10n.privacyTitle,
              subtitle: l10n.profilePrivacyHelper,
              leadingIcon: Icons.privacy_tip_outlined,
              onTap: () => context.go(PrivacyRoutes.privacy),
            ),
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

  List<Widget> _accountSection(BuildContext context, Account account, FeatureSwitches features) {
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
      // Prompt 12: signed in on a new phone; a fresh selfie opens chats,
      // the wallet and child data again.
      if (account.newDeviceCheck)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
          child: AppAlertBanner(
            key: const Key('profile.newDevice'),
            icon: Icons.phonelink_lock_outlined,
            title: l10n.newDeviceTitle,
            body: l10n.newDeviceBanner,
            actionLabel: l10n.newDeviceAction,
            onAction: () => context.go(PrivacyRoutes.newDevice),
          ),
        ),
      // Prompt 11: the yearly check of children, grades and schools.
      if (account.status == AccountStatus.verified && features.yearlyChecks) const YearCheckBanner(),
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
      // Prompt 11: a new number is checked again (WhatsApp code and a live selfie).
      AppListRow(
        key: const Key('profile.phone'),
        title: l10n.profilePhone,
        subtitle: EgyptPhone.display(account.phone),
        leadingIcon: Icons.phone_iphone_rounded,
        onTap: account.status == AccountStatus.verified ? () => context.go(ProfileRoutes.phone) : null,
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
        key: const Key('profile.homeLocation'),
        title: l10n.homeLocationTitle,
        subtitle: l10n.profileHomeHelper,
        leadingIcon: Icons.home_work_outlined,
        onTap: () => context.go(ProfileRoutes.homeLocation),
      ),
      AppListRow(
        key: const Key('profile.drivingSchools'),
        title: l10n.drivingSchoolsTitle,
        subtitle: l10n.profileDrivingSchoolsHelper,
        leadingIcon: Icons.alt_route_rounded,
        onTap: () => context.go(ProfileRoutes.drivingSchools),
      ),
      AppListRow(
        key: const Key('profile.driving'),
        title: l10n.drivingTitle,
        subtitle: l10n.profileDrivingHelper,
        leadingIcon: Icons.directions_car_outlined,
        onTap: () => context.go(ProfileRoutes.driving),
      ),
      // Prompt 10: who may receive each child (F29) and the emergency contact (F20).
      AppListRow(
        key: const Key('profile.handover'),
        title: l10n.handoverTitle,
        subtitle: l10n.profileHandoverHelper,
        leadingIcon: Icons.family_restroom_outlined,
        onTap: () => context.go(ProfileRoutes.handover),
      ),
      AppListRow(
        key: const Key('profile.emergencyContact'),
        title: l10n.emergencyContactTitle,
        subtitle: l10n.profileEmergencyHelper,
        leadingIcon: Icons.contact_emergency_outlined,
        onTap: () => context.go(ProfileRoutes.emergencyContact),
      ),
      // Prompt 11 (F17): ratings and vouching, family links.
      if (account.status == AccountStatus.verified) const TrustProfileRows(),
      // Settle up by InstaPay (F45), the pilot's payment feature: records of
      // payments between parents; the app moves no money. Verified parents.
      if (features.settleUp && account.status == AccountStatus.verified)
        AppListRow(
          key: const Key('profile.settleUp'),
          title: l10n.settleTitle,
          subtitle: l10n.profileSettleHelper,
          leadingIcon: Icons.payments_outlined,
          onTap: () => context.go(SettleUpRoutes.home),
        ),
      // Prompt 11B (F43): verified parents; the screen explains otherwise.
      // Hidden while the wallet is switched off (pilot).
      if (features.wallet)
        AppListRow(
          key: const Key('profile.wallet'),
          title: l10n.walletTitle,
          subtitle: l10n.profileWalletHelper,
          leadingIcon: Icons.account_balance_wallet_outlined,
          onTap: () => context.go(ProfileRoutes.wallet),
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
