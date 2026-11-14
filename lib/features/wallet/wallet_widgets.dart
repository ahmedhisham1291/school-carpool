import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/wallet_labels.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Wallet pieces (Prompt 11B), in the gallery under "Wallet".

/// The balance from the partner and what can still be sent today.
class BalanceCard extends StatelessWidget {
  const BalanceCard({required this.info, super.key});

  final WalletInfo info;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return AppCard(
      key: const Key('wallet.balance'),
      child: Semantics(
        container: true,
        label: l10n.walletBalanceLabel(Money.format(l10n, info.balance ?? 0)),
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OneLineText(l10n.walletBalance, style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.s4),
            AppAmount(Money.format(l10n, info.balance ?? 0), size: AppAmountSize.large),
            const SizedBox(height: AppSpacing.s8),
            Text(l10n.walletLeftToday(Money.format(l10n, info.leftToday)), style: quiet),
          ],
        ),
      ),
    );
  }
}

/// One history line: who or what, when, the note, the amount and the status.
class TransferRow extends StatelessWidget {
  const TransferRow({required this.transfer, super.key, this.onTap});

  final WalletTransfer transfer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final WalletTransfer t = transfer;
    final String when = transferTime(l10n, t.createdAt);
    final String subtitle = t.note.isEmpty ? when : l10n.walletRowSubtitle(when, t.note);
    return AppListRow(
      key: Key('wallet.row.${t.id}'),
      title: transferTitle(l10n, t),
      subtitle: subtitle,
      leadingIcon: transferIcon(t),
      showChevron: false,
      onTap: onTap,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          AppAmount(
            transferAmount(l10n, t),
            incoming: !t.outgoing && t.status == TransferStatus.done,
            muted: t.status == TransferStatus.failed,
          ),
          if (t.status != TransferStatus.done) ...<Widget>[
            const SizedBox(height: AppSpacing.s4),
            AppStatusBadge(label: statusLabel(l10n, t.status), tone: statusTone(t.status)),
          ],
        ],
      ),
    );
  }
}

/// Who gets the money: the letter avatar (no profile photos yet), the first
/// name and the Verified badge (F44), shown before the amount.
class ReceiverCard extends StatelessWidget {
  const ReceiverCard({required this.name, required this.verified, super.key, this.subtitle});

  final String name;
  final bool verified;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final String? sub = subtitle;
    return AppCard(
      key: const Key('wallet.receiver'),
      child: Row(
        children: <Widget>[
          AppInitialAvatar(name: name, size: AppSpacing.s64),
          const SizedBox(width: AppSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLineText(name, style: context.text.titleMedium),
                if (sub != null) Text(sub, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.s8),
                if (verified)
                  const VerifiedBadge()
                else
                  AppStatusBadge(label: context.l10n.walletNotVerified, tone: AppBadgeTone.warning, icon: Icons.help_outline_rounded),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The result of a money action: done, pending (we are checking) or failed
/// (no money left the wallet), with what to do next.
class MoneyOutcomeView extends StatelessWidget {
  const MoneyOutcomeView({required this.transfer, required this.onDone, super.key, this.onCheckAgain, this.checking = false});

  final WalletTransfer transfer;
  final VoidCallback onDone;
  final VoidCallback? onCheckAgain;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final WalletTransfer t = transfer;
    final (IconData icon, Color color, String title, String body) = switch (t.status) {
      TransferStatus.done => (
        Icons.check_circle_outline_rounded,
        context.appColors.success,
        switch (t.kind) {
          TransferKind.transfer => l10n.walletDoneSent,
          TransferKind.topup => l10n.walletDoneAdded,
          TransferKind.withdraw => l10n.walletDoneWithdrawn,
        },
        t.kind == TransferKind.transfer ? l10n.walletDoneSentBody(t.otherName) : l10n.walletDoneBody,
      ),
      TransferStatus.pending => (Icons.hourglass_top_rounded, context.appColors.warning, l10n.walletPendingTitle, l10n.walletPendingBody),
      TransferStatus.failed => (Icons.error_outline_rounded, context.colors.error, l10n.walletFailedTitle, failReasonText(l10n, t.reason)),
    };
    return ListView(
      key: Key('wallet.outcome.${t.status.name}'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        const SizedBox(height: AppSpacing.s32),
        ExcludeSemantics(child: Icon(icon, size: AppIconSize.xl, color: color)),
        const SizedBox(height: AppSpacing.s16),
        Semantics(header: true, child: OneLineText(title, style: context.text.titleMedium, textAlign: TextAlign.center, scaleDown: true)),
        const SizedBox(height: AppSpacing.s8),
        AppAmount(Money.format(l10n, t.amount), size: AppAmountSize.large, muted: t.status == TransferStatus.failed),
        const SizedBox(height: AppSpacing.s8),
        Text(body, textAlign: TextAlign.center, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s32),
        if (t.status == TransferStatus.pending && onCheckAgain != null) ...<Widget>[
          AppButton(
            key: const Key('wallet.checkAgain'),
            label: l10n.walletCheckAgain,
            icon: Icons.refresh_rounded,
            variant: AppButtonVariant.secondary,
            expand: true,
            loading: checking,
            onPressed: onCheckAgain,
          ),
          const SizedBox(height: AppSpacing.s8),
        ],
        AppButton(key: const Key('wallet.done'), label: l10n.walletBackToWallet, expand: true, onPressed: onDone),
      ],
    );
  }
}

/// Loading shape of the wallet screen.
class WalletSkeleton extends StatelessWidget {
  const WalletSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Skeleton(
    key: Key('wallet.loading'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(padding: AppSpacing.screenPadding, child: SkeletonCard()),
        Padding(
          padding: EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: SkeletonBox(height: AppSpacing.buttonHeight, borderRadius: AppRadii.control),
        ),
        SizedBox(height: AppSpacing.s16),
        SkeletonListRow(),
        SkeletonListRow(),
        SkeletonListRow(),
      ],
    ),
  );
}
