import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/features/wallet/wallet_repository.dart';
import 'package:school_carpool/features/wallet/wallet_widgets.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Wallet (F43, spec section 10 "Profile > wallet"). Layout, top to bottom:
/// the balance card (from the partner, with what can still be sent today),
/// one primary action (Send money), Add money and Withdraw as outlined
/// buttons, then the history (date, other parent, amount, note, status).
///
/// Before the wallet is opened: what the wallet is (a licensed partner holds
/// the money, no fee) and the partner's terms to agree to, then Open wallet.
///
/// States: loading (skeleton), wallet not switched on yet (empty), not
/// verified (empty with "Verify account"), frozen (a note; sending and
/// withdrawing off), error and offline (retry). Pull to refresh.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<WalletInfo> info = ref.watch(walletInfoProvider);
    void reload() {
      ref
        ..invalidate(walletInfoProvider)
        ..invalidate(walletHistoryProvider);
    }

    final Widget body = switch (info) {
      AsyncData<WalletInfo>(:final WalletInfo value) when !value.available => EmptyStateView(
        key: const Key('wallet.off'),
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.walletOffTitle,
        body: l10n.walletOffBody,
      ),
      AsyncData<WalletInfo>(:final WalletInfo value) when !value.opened => _OpenWallet(info: value),
      AsyncData<WalletInfo>(:final WalletInfo value) => _WalletContent(info: value, onRefresh: reload),
      AsyncError<WalletInfo>(:final Object error) => _failureView(context, WalletFailure.from(error), reload),
      _ => const WalletSkeleton(),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.walletTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  static Widget _failureView(BuildContext context, WalletFailure f, VoidCallback retry) {
    final AppLocalizations l10n = context.l10n;
    return switch (f.kind) {
      WalletFailureKind.offline => OfflineStateView(onRetry: retry),
      WalletFailureKind.notVerified => EmptyStateView(
        key: const Key('wallet.notVerified'),
        icon: Icons.verified_user_outlined,
        title: l10n.walletVerifyTitle,
        body: l10n.walletErrorNotVerified,
        actionLabel: l10n.walletVerifyAction,
        onAction: () => context.go(AuthRoutes.verifyAccount),
      ),
      WalletFailureKind.suspended => EmptyStateView(
        key: const Key('wallet.suspended'),
        icon: Icons.block_outlined,
        title: l10n.walletSuspendedTitle,
        body: l10n.walletErrorSuspended,
      ),
      WalletFailureKind.walletOff => EmptyStateView(
        key: const Key('wallet.off'),
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.walletOffTitle,
        body: l10n.walletOffBody,
      ),
      _ => ErrorStateView(key: const Key('wallet.error'), body: f.message(l10n), onRetry: retry),
    };
  }
}

/// The partner's terms, then Open wallet (consent record on the server).
class _OpenWallet extends ConsumerStatefulWidget {
  const _OpenWallet({required this.info});

  final WalletInfo info;

  @override
  ConsumerState<_OpenWallet> createState() => _OpenWalletState();
}

class _OpenWalletState extends ConsumerState<_OpenWallet> {
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  Future<void> _open() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(walletRepositoryProvider).open(termsVersion: widget.info.termsVersion);
      showAppSnackBarOn(messenger, l10n.walletOpened);
      ref.invalidate(walletInfoProvider);
    } on WalletFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.message(l10n));
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
    final String? error = _error;
    return ListView(
      key: const Key('wallet.open'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Icon(Icons.account_balance_wallet_outlined, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
        const SizedBox(height: AppSpacing.s16),
        Text(l10n.walletOpenTitle, style: context.text.titleMedium),
        const SizedBox(height: AppSpacing.s8),
        Text(l10n.walletOpenBody, style: quiet),
        const SizedBox(height: AppSpacing.s16),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Point(icon: Icons.account_balance_outlined, text: l10n.walletOpenPartner),
              const SizedBox(height: AppSpacing.s16),
              _Point(icon: Icons.money_off_outlined, text: l10n.walletOpenNoFee),
              const SizedBox(height: AppSpacing.s16),
              _Point(icon: Icons.fingerprint_rounded, text: l10n.walletOpenLock),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppCheckRow(
          key: const Key('wallet.terms'),
          label: l10n.walletTermsAgree,
          helperText: l10n.walletTermsHelper,
          value: _agreed,
          onChanged: _busy ? null : (bool v) => setState(() => _agreed = v),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('wallet.openButton'),
          label: l10n.walletOpenAction,
          icon: Icons.lock_open_rounded,
          expand: true,
          loading: _busy,
          onPressed: _agreed ? () => unawaited(_open()) : null,
        ),
      ],
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      ExcludeSemantics(child: Icon(icon, size: AppIconSize.md, color: context.colors.onSurfaceVariant)),
      const SizedBox(width: AppSpacing.s16),
      Expanded(child: Text(text, style: context.text.bodyMedium)),
    ],
  );
}

class _WalletContent extends ConsumerWidget {
  const _WalletContent({required this.info, required this.onRefresh});

  final WalletInfo info;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final bool frozen = info.status == WalletStatus.frozen;
    final AsyncValue<WalletPage> history = ref.watch(walletHistoryProvider);
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);

    final List<Widget> rows = switch (history) {
      AsyncData<WalletPage>(:final WalletPage value) when value.transfers.isEmpty => <Widget>[
        Padding(
          key: const Key('wallet.historyEmpty'),
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: Text(l10n.walletHistoryEmpty, style: quiet),
        ),
      ],
      AsyncData<WalletPage>(:final WalletPage value) => <Widget>[
        for (final WalletTransfer t in value.transfers)
          TransferRow(transfer: t, onTap: () => context.go(WalletRoutes.transfer(t.id))),
      ],
      AsyncError<WalletPage>(:final Object error) => <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppInlineMessage(key: const Key('wallet.historyError'), message: WalletFailure.from(error).message(l10n), tone: AppStateTone.error),
              const SizedBox(height: AppSpacing.s8),
              AppButton(label: l10n.actionRetry, variant: AppButtonVariant.tertiary, onPressed: () => ref.invalidate(walletHistoryProvider)),
            ],
          ),
        ),
      ],
      _ => const <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()],
    };

    return RefreshIndicator(
      onRefresh: () async {
        onRefresh();
        try {
          await ref.read(walletInfoProvider.future);
        } on Object {
          // The screen shows the error with its own Retry.
        }
      },
      child: ListView(
        key: const Key('wallet.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          if (frozen)
            const Padding(
              padding: EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: _FrozenNote(),
            ),
          Padding(
            padding: AppSpacing.screenPadding,
            child: BalanceCard(info: info),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppButton(
                  key: const Key('wallet.send'),
                  label: l10n.walletSendAction,
                  icon: Icons.send_rounded,
                  expand: true,
                  onPressed: frozen ? null : () => context.go(WalletRoutes.send()),
                ),
                const SizedBox(height: AppSpacing.s8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: AppButton(
                        key: const Key('wallet.add'),
                        label: l10n.walletAddAction,
                        icon: Icons.add_rounded,
                        variant: AppButtonVariant.secondary,
                        expand: true,
                        onPressed: frozen ? null : () => context.go(WalletRoutes.add),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Expanded(
                      child: AppButton(
                        key: const Key('wallet.withdraw'),
                        label: l10n.walletWithdrawAction,
                        icon: Icons.south_rounded,
                        variant: AppButtonVariant.secondary,
                        expand: true,
                        onPressed: frozen ? null : () => context.go(WalletRoutes.withdraw),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          AppSectionHeader(l10n.walletHistory),
          ...rows,
        ],
      ),
    );
  }
}

class _FrozenNote extends StatelessWidget {
  const _FrozenNote();

  @override
  Widget build(BuildContext context) =>
      AppInlineMessage(key: const Key('wallet.frozen'), message: context.l10n.walletFrozenNote, tone: AppStateTone.warning, icon: Icons.lock_outline_rounded);
}
