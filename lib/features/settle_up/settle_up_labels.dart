import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';

/// Settle up wording in one place (titles, chips and badges stay on one
/// line at 320 dp in Arabic and English).

/// The short state for a badge.
String settleStatusLabel(AppLocalizations l10n, SettleStatus s) => switch (s) {
  SettleStatus.open => l10n.settleStatusOpen,
  SettleStatus.paid => l10n.settleStatusPaid,
  SettleStatus.closed => l10n.settleStatusClosed,
  SettleStatus.cancelled => l10n.settleStatusCancelled,
  SettleStatus.declined => l10n.settleStatusDeclined,
};

AppBadgeTone settleStatusTone(SettleStatus s) => switch (s) {
  SettleStatus.open || SettleStatus.paid => AppBadgeTone.warning,
  SettleStatus.closed => AppBadgeTone.success,
  SettleStatus.cancelled || SettleStatus.declined => AppBadgeTone.neutral,
};

/// What happens next, for my side of the record (a full sentence).
String settleNextStep(AppLocalizations l10n, SettleUp r, SettleRole mine) => switch ((r.status, mine)) {
  (SettleStatus.open, SettleRole.payer) => l10n.settleNextPay,
  (SettleStatus.open, SettleRole.payee) => l10n.settleNextWaitPay,
  (SettleStatus.paid, SettleRole.payee) => l10n.settleNextConfirm,
  (SettleStatus.paid, SettleRole.payer) => l10n.settleNextWaitConfirm,
  (SettleStatus.closed, _) => l10n.settleNextClosed,
  (SettleStatus.cancelled, _) => l10n.settleNextCancelled,
  (SettleStatus.declined, _) => l10n.settleNextDeclined,
};

String settleReasonLabel(AppLocalizations l10n, SettleReason r) => switch (r) {
  SettleReason.contribution => l10n.settleReasonContribution,
  SettleReason.fuel => l10n.settleReasonFuel,
  SettleReason.other => l10n.settleReasonOther,
};

/// "You pay EGP 150" / "Pays you EGP 150".
String settleDirection(AppLocalizations l10n, SettleUp r, SettleRole mine) {
  final String amount = Money.format(l10n, r.amount);
  return mine == SettleRole.payer ? l10n.settleYouPay(amount) : l10n.settlePaysYou(amount);
}

/// The other parent's first name; a deleted parent shows as their initial,
/// or as "Deleted account" when nothing is left.
String settleOtherName(AppLocalizations l10n, SettleUp r, SettleRole mine) {
  final String name = r.otherName(mine);
  return name.isEmpty ? l10n.settleDeletedParent : name;
}

IconData settleIcon(SettleRole mine) => mine == SettleRole.payer ? Icons.north_east_rounded : Icons.south_west_rounded;

/// One history entry, from my point of view.
String settleEventLabel(AppLocalizations l10n, SettleEvent e, SettleRole mine) {
  final bool me = e.by == mine;
  return switch (e.type) {
    SettleEventType.requested => me ? l10n.settleEventRequestedMe : l10n.settleEventRequestedThem,
    SettleEventType.recorded || SettleEventType.paid => me ? l10n.settleEventPaidMe : l10n.settleEventPaidThem,
    SettleEventType.received => me ? l10n.settleEventReceivedMe : l10n.settleEventReceivedThem,
    SettleEventType.notReceived => me ? l10n.settleEventNotReceivedMe : l10n.settleEventNotReceivedThem,
    SettleEventType.cancelled => l10n.settleEventCancelled,
    SettleEventType.declined => l10n.settleEventDeclined,
    SettleEventType.reported => l10n.settleEventReported,
    SettleEventType.accountClosed => l10n.settleEventAccountClosed,
  };
}

/// "16/11 10:30" in the phone's time.
String settleTime(AppLocalizations l10n, DateTime utc) {
  final DateTime t = utc.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return l10n.walletTime('${t.day}/${t.month}', '${two(t.hour)}:${two(t.minute)}');
}
