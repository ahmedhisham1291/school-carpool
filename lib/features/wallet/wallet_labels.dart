import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Wallet wording in one place (one line at 320 dp for titles and badges).

String transferTitle(AppLocalizations l10n, WalletTransfer t) => switch (t.kind) {
  TransferKind.topup => l10n.walletKindTopUp,
  TransferKind.withdraw => l10n.walletKindWithdraw,
  TransferKind.transfer => t.outgoing ? l10n.walletTo(t.otherName) : l10n.walletFrom(t.otherName),
};

IconData transferIcon(WalletTransfer t) => switch (t.kind) {
  TransferKind.topup => Icons.add_card_outlined,
  TransferKind.withdraw => Icons.account_balance_outlined,
  TransferKind.transfer => t.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
};

/// "+ EGP 100" for money in, "EGP 100" for money out.
String transferAmount(AppLocalizations l10n, WalletTransfer t) {
  final String amount = Money.format(l10n, t.amount);
  return t.outgoing || t.status == TransferStatus.failed ? amount : l10n.walletIncoming(amount);
}

String statusLabel(AppLocalizations l10n, TransferStatus s) => switch (s) {
  TransferStatus.pending => l10n.walletStatusPending,
  TransferStatus.done => l10n.walletStatusDone,
  TransferStatus.failed => l10n.walletStatusFailed,
};

AppBadgeTone statusTone(TransferStatus s) => switch (s) {
  TransferStatus.pending => AppBadgeTone.warning,
  TransferStatus.done => AppBadgeTone.success,
  TransferStatus.failed => AppBadgeTone.error,
};

/// Why it failed, and that no money left the wallet.
String failReasonText(AppLocalizations l10n, TransferFailReason? r) => switch (r) {
  TransferFailReason.insufficientFunds => l10n.walletFailFunds,
  TransferFailReason.senderFrozen => l10n.walletFailSenderFrozen,
  TransferFailReason.receiverFrozen => l10n.walletFailReceiverFrozen,
  TransferFailReason.notReceived => l10n.walletFailNotReceived,
  TransferFailReason.declined || TransferFailReason.partnerError || null => l10n.walletFailPartner,
};

String reportReasonLabel(AppLocalizations l10n, WalletReportReason r) => switch (r) {
  WalletReportReason.notReceived => l10n.walletReportNotReceived,
  WalletReportReason.wrongAmount => l10n.walletReportWrongAmount,
  WalletReportReason.wrongPerson => l10n.walletReportWrongPerson,
  WalletReportReason.unauthorized => l10n.walletReportUnauthorized,
  WalletReportReason.other => l10n.walletReportOther,
};

/// "Mon 16/11 10:30" in the phone's time.
String transferTime(AppLocalizations l10n, DateTime utc) {
  final DateTime t = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return l10n.walletTime('${t.day}/${t.month}', '${two(t.hour)}:${two(t.minute)}');
}

/// The Verified badge (F44): shown only for verified parents.
class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      AppStatusBadge(label: context.l10n.walletVerified, tone: AppBadgeTone.success, icon: Icons.verified_rounded);
}
