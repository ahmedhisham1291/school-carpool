import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Delete account (spec section 7, Prompt 12). Two short steps with a
/// progress indicator:
/// 1. What happens: deleted now (record, children, car, home, carpools,
///    ratings, family links, phones); kept 1 year, admins only with a
///    logged reason (photos, run summaries and routes, consents, chat);
///    kept after that (the ID number's keyed code on the ban list if
///    banned, open reports, transfer records as the law requires).
/// 2. Confirm: tick "I understand", then the one primary action (red),
///    a confirmation dialog and a fresh Face ID, fingerprint or passcode
///    check. The wallet must be empty first: the answer says so and links
///    to the wallet.
///
/// States: idle, busy (button spinner), refused (a banner with the reason
/// and how to fix it), offline (one-line message, try again).
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  int _step = 1;
  bool _understood = false;
  bool _busy = false;
  PrivacyFailure? _failure;

  Future<void> _delete() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.deleteAccountConfirmTitle,
      body: l10n.deleteAccountConfirmBody,
      confirmLabel: l10n.deleteAccountAction,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    // A fresh check that the phone's owner asks (a phone without a lock
    // has only the dialog above).
    final DeviceAuthResult check = await ref.read(deviceAuthProvider).confirm(l10n.deleteAccountReason);
    if (check == DeviceAuthResult.cancelled || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(privacyRepositoryProvider).deleteAccount();
      ref.read(analyticsProvider).track(AnalyticsEvent.accountDeleted);
      // The server deleted the session; clean up this phone.
      ref.read(signupFlowProvider.notifier).reset();
      try {
        await ref.read(notificationCenterProvider).unregister();
      } on Object {
        // The push tokens were deleted with the account.
      }
      await ref.read(pendingInviteProvider.notifier).save(null);
      try {
        await ref.read(authRepositoryProvider).signOut();
      } on Object {
        // The Auth user is gone already.
      }
      showAppSnackBarOn(messenger, l10n.deleteAccountDone);
    } on PrivacyFailure catch (f) {
      if (mounted) {
        setState(() => _failure = f);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final PrivacyFailure? failure = _failure;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.deleteAccountTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('delete.list'),
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            AppStepProgress(current: _step, total: 2),
            const SizedBox(height: AppSpacing.s24),
            if (_step == 1) ...<Widget>[
              _Group(icon: Icons.delete_outline_rounded, title: l10n.deleteNowTitle, body: l10n.deleteNowBody),
              _Group(icon: Icons.lock_clock_outlined, title: l10n.deleteYearTitle, body: l10n.deleteYearBody),
              _Group(icon: Icons.gavel_outlined, title: l10n.deleteKeptTitle, body: l10n.deleteKeptBody),
              // Owner decision 16 Nov 2026: photos and routes go with the
              // account; only an open report holds them, 30 days at most.
              _Group(icon: Icons.shield_outlined, title: l10n.deleteHoldTitle, body: l10n.deleteHoldBody),
              const SizedBox(height: AppSpacing.s8),
              Text(l10n.deleteExportHint, style: quiet),
              const SizedBox(height: AppSpacing.s24),
              AppButton(
                key: const Key('delete.next'),
                label: l10n.deleteNext,
                expand: true,
                onPressed: () => setState(() => _step = 2),
              ),
            ] else ...<Widget>[
              Text(l10n.deleteWalletNote, style: context.text.bodyLarge),
              const SizedBox(height: AppSpacing.s16),
              if (failure != null) ...<Widget>[
                if (failure.kind == PrivacyFailureKind.walletNotEmpty || failure.kind == PrivacyFailureKind.walletPending)
                  AppAlertBanner(
                    key: const Key('delete.walletBanner'),
                    title: l10n.deleteRefusedTitle,
                    body: failure.message(l10n),
                    actionLabel: l10n.deleteOpenWallet,
                    onAction: () => context.go(ProfileRoutes.wallet),
                  )
                else
                  AppInlineMessage(key: const Key('delete.error'), message: failure.message(l10n), tone: AppStateTone.error),
                const SizedBox(height: AppSpacing.s16),
              ],
              AppCheckRow(
                key: const Key('delete.understood'),
                label: l10n.deleteUnderstood,
                value: _understood,
                onChanged: _busy ? null : (bool v) => setState(() => _understood = v),
              ),
              const SizedBox(height: AppSpacing.s24),
              AppButton(
                key: const Key('delete.confirm'),
                label: l10n.deleteAccountAction,
                icon: Icons.delete_forever_outlined,
                variant: AppButtonVariant.danger,
                expand: true,
                loading: _busy,
                onPressed: _understood && !_busy ? () => unawaited(_delete()) : null,
              ),
              const SizedBox(height: AppSpacing.s8),
              AppButton(
                key: const Key('delete.back'),
                label: l10n.deleteBack,
                variant: AppButtonVariant.tertiary,
                expand: true,
                onPressed: _busy ? null : () => setState(() => _step = 1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s16),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: context.colors.primary, size: AppIconSize.md),
            const SizedBox(width: AppSpacing.s16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  OneLineText(title, style: context.text.titleMedium),
                  const SizedBox(height: AppSpacing.s4),
                  Text(body, style: context.text.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
