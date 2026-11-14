import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/admin_wallet.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// No automatic retry (Riverpod 3): the pages show their own Retry.
Duration? _noRetry(int retryCount, Object error) => null;

final _alertsProvider = FutureProvider.autoDispose<List<WalletAlert>>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminWalletApiProvider).alerts(),
);

final _logProvider = FutureProvider.autoDispose<PagedResult<AdminTransfer>>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminWalletApiProvider).transfers(),
);

final _walletProvider = FutureProvider.autoDispose.family<AdminWallet, String>(
  retry: _noRetry,
  (Ref ref, String uid) => ref.watch(adminWalletApiProvider).wallet(uid),
);

String _kindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'new-receivers' => l10n.adminWalletAlertNewReceivers,
  'many-transfers' => l10n.adminWalletAlertMany,
  'report' => l10n.adminWalletAlertReport,
  _ => kind,
};

String _transferLine(AppLocalizations l10n, AdminTransfer t) => switch (t.kind) {
  'topup' => l10n.adminWalletTopUp(t.toFirstName),
  'withdraw' => l10n.adminWalletWithdraw(t.fromFirstName),
  _ => l10n.adminWalletFromTo(t.fromFirstName, t.toFirstName),
};

(String, AppBadgeTone) _status(AppLocalizations l10n, String status) => switch (status) {
  'done' => (l10n.walletStatusDone, AppBadgeTone.success),
  'failed' => (l10n.walletStatusFailed, AppBadgeTone.error),
  _ => (l10n.walletStatusPending, AppBadgeTone.warning),
};

String freezeReasonLabel(AppLocalizations l10n, FreezeReason r) => switch (r) {
  FreezeReason.fraudSuspected => l10n.adminFreezeFraud,
  FreezeReason.parentAsked => l10n.adminFreezeParentAsked,
  FreezeReason.stolenPhone => l10n.adminFreezeStolenPhone,
  FreezeReason.dispute => l10n.adminFreezeDispute,
  FreezeReason.partnerRequest => l10n.adminFreezePartner,
  FreezeReason.other => l10n.adminFreezeOther,
};

String _outcomeLabel(AppLocalizations l10n, AlertOutcome o) => switch (o) {
  AlertOutcome.noIssue => l10n.adminWalletOutcomeNoIssue,
  AlertOutcome.frozen => l10n.adminWalletOutcomeFrozen,
  AlertOutcome.sentToPartner => l10n.adminWalletOutcomePartner,
  AlertOutcome.parentContacted => l10n.adminWalletOutcomeContacted,
};

/// Wallet (F43, F14): open alerts first (unusual patterns such as many
/// transfers to new receivers in a short time, and transfer problem
/// reports), then the read-only transfer log, newest first. A row opens the
/// parent's wallet. There is no button that moves money anywhere here.
///
/// States: loading (skeleton), empty (no alerts / no transfers), error and
/// offline (retry).
class AdminWalletsScreen extends ConsumerWidget {
  const AdminWalletsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void refresh() => ref
      ..invalidate(_alertsProvider)
      ..invalidate(_logProvider);
    return AdminPage(
      title: l10n.adminWalletTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: AdminAsyncView<List<WalletAlert>>(
        value: ref.watch(_alertsProvider),
        onRetry: refresh,
        builder: (List<WalletAlert> alerts) => ListView(
          key: const Key('adminWallet.list'),
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            AppSectionHeader(l10n.adminWalletAlerts),
            if (alerts.isEmpty)
              AppInlineMessage(key: const Key('adminWallet.noAlerts'), message: l10n.adminWalletNoAlerts)
            else
              for (final WalletAlert a in alerts) _AlertRow(alert: a, onDone: refresh),
            AppSectionHeader(l10n.adminWalletLog),
            ...switch (ref.watch(_logProvider)) {
              AsyncData<PagedResult<AdminTransfer>>(:final PagedResult<AdminTransfer> value) when value.items.isEmpty => <Widget>[
                AppInlineMessage(message: l10n.adminWalletNoTransfers),
              ],
              AsyncData<PagedResult<AdminTransfer>>(:final PagedResult<AdminTransfer> value) => <Widget>[
                for (final AdminTransfer t in value.items) _TransferRow(transfer: t),
              ],
              AsyncError<PagedResult<AdminTransfer>>(:final Object error) => <Widget>[
                AppInlineMessage(message: AdminFailure.from(error).message(l10n), tone: AppStateTone.error),
              ],
              _ => const <Widget>[SkeletonListRow(), SkeletonListRow()],
            },
          ],
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({required this.transfer});

  final AdminTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AdminTransfer t = transfer;
    final (String label, AppBadgeTone tone) = _status(l10n, t.status);
    final String? owner = t.fromUid ?? t.toUid;
    return AppListRow(
      key: Key('adminWallet.transfer.${t.id}'),
      inset: false,
      title: _transferLine(l10n, t),
      subtitle: '${Money.format(l10n, t.amount)} · ${adminDateTime(context, t.createdAt)}',
      leadingIcon: Icons.swap_horiz_rounded,
      trailing: AppStatusBadge(label: label, tone: tone),
      onTap: owner == null ? null : () => context.go(AdminRoutes.wallet(owner)),
    );
  }
}

class _AlertRow extends ConsumerWidget {
  const _AlertRow({required this.alert, required this.onDone});

  final WalletAlert alert;
  final VoidCallback onDone;

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AlertOutcome? outcome = await showAppSheet<AlertOutcome>(
      context: context,
      title: l10n.adminWalletResolve,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final AlertOutcome o in AlertOutcome.values)
            Builder(
              builder: (BuildContext sheet) => AppListRow(
                key: Key('adminWallet.outcome.${o.name}'),
                inset: false,
                title: _outcomeLabel(l10n, o),
                onTap: () => Navigator.of(sheet).pop(o),
              ),
            ),
        ],
      ),
    );
    if (outcome == null) {
      return;
    }
    try {
      await ref.read(adminWalletApiProvider).resolveAlert(alert.id, outcome);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      onDone();
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final WalletAlert a = alert;
    return AppListRow(
      key: Key('adminWallet.alert.${a.id}'),
      inset: false,
      title: _kindLabel(l10n, a.kind),
      subtitle: <String>[
        if (a.kind != 'report') l10n.adminWalletAlertCount(a.count),
        if (a.reason != null) a.reason!,
        adminDateTime(context, a.createdAt),
      ].join(' · '),
      leadingIcon: a.kind == 'report' ? Icons.flag_outlined : Icons.warning_amber_rounded,
      trailing: AppButton(
        key: Key('adminWallet.resolve.${a.id}'),
        label: l10n.adminWalletResolve,
        variant: AppButtonVariant.tertiary,
        onPressed: () => unawaited(_resolve(context, ref)),
      ),
      onTap: () => context.go(AdminRoutes.wallet(a.uid)),
    );
  }
}

/// One parent's wallet: status, the partner's balance (or our copy, marked,
/// when the partner does not answer), the partner's last transactions next
/// to our records, open alerts, and Freeze / Unfreeze with a reason
/// (asks first; in the audit log). No money can be moved from here.
///
/// States: loading (skeleton), no wallet (empty), error and offline (retry).
class AdminWalletScreen extends ConsumerStatefulWidget {
  const AdminWalletScreen({required this.uid, super.key});

  final String uid;

  @override
  ConsumerState<AdminWalletScreen> createState() => _AdminWalletScreenState();
}

class _AdminWalletScreenState extends ConsumerState<AdminWalletScreen> {
  bool _busy = false;

  void _reload() => ref.invalidate(_walletProvider(widget.uid));

  Future<void> _setFrozen(bool frozen) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final (FreezeReason, String?)? choice = await showAppSheet<(FreezeReason, String?)>(
      context: context,
      title: frozen ? l10n.adminWalletFreeze : l10n.adminWalletUnfreeze,
      body: _FreezeForm(frozen: frozen),
    );
    if (choice == null || !mounted) {
      return;
    }
    final bool ok = await showConfirmDialog(
      context: context,
      title: frozen ? l10n.adminWalletFreezeTitle : l10n.adminWalletUnfreezeTitle,
      body: frozen ? l10n.adminWalletFreezeBody : l10n.adminWalletUnfreezeBody,
      confirmLabel: frozen ? l10n.adminWalletFreeze : l10n.adminWalletUnfreeze,
      destructive: frozen,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminWalletApiProvider).setFrozen(uid: widget.uid, frozen: frozen, reason: choice.$1, note: choice.$2);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      _reload();
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AdminPage(
      title: l10n.adminWalletOneTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: _reload)],
      body: AdminAsyncView<AdminWallet>(
        value: ref.watch(_walletProvider(widget.uid)),
        onRetry: _reload,
        isEmpty: (AdminWallet w) => w.status == 'none',
        empty: EmptyStateView(icon: Icons.account_balance_wallet_outlined, title: l10n.adminWalletNone, body: l10n.adminWalletNoneBody),
        builder: (AdminWallet w) {
          final int? balance = w.balance;
          final int? copy = w.balanceCopy;
          final FreezeReason? reason = w.frozenReason;
          return ListView(
            key: const Key('adminWallet.one'),
            padding: AppSpacing.screenPadding,
            children: <Widget>[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(child: OneLineText(l10n.adminWalletOneTitle, style: context.text.titleLarge)),
                        AppStatusBadge(
                          key: const Key('adminWallet.status'),
                          label: w.frozen ? l10n.adminWalletFrozen : l10n.adminWalletActive,
                          tone: w.frozen ? AppBadgeTone.error : AppBadgeTone.success,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AdminFact(
                      label: l10n.walletBalance,
                      value: balance != null
                          ? Money.format(l10n, balance)
                          : l10n.adminWalletCopy(copy == null ? '-' : Money.format(l10n, copy)),
                    ),
                    if (reason != null) AdminFact(label: l10n.adminReasonLabel, value: freezeReasonLabel(l10n, reason)),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s16),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: w.frozen
                    ? AppButton(
                        key: const Key('adminWallet.unfreeze'),
                        label: l10n.adminWalletUnfreeze,
                        loading: _busy,
                        onPressed: () => unawaited(_setFrozen(false)),
                      )
                    : AppButton(
                        key: const Key('adminWallet.freeze'),
                        label: l10n.adminWalletFreeze,
                        variant: AppButtonVariant.danger,
                        loading: _busy,
                        onPressed: () => unawaited(_setFrozen(true)),
                      ),
              ),
              if (w.alerts.isNotEmpty) ...<Widget>[
                AppSectionHeader(l10n.adminWalletAlerts),
                for (final WalletAlert a in w.alerts) _AlertRow(alert: a, onDone: _reload),
              ],
              AppSectionHeader(l10n.adminWalletLog),
              if (w.transfers.isEmpty) AppInlineMessage(message: l10n.adminWalletNoTransfers),
              for (final AdminTransfer t in w.transfers) _TransferRow(transfer: t),
              AppSectionHeader(l10n.adminWalletPartner),
              if (w.partnerTransactions.isEmpty) AppInlineMessage(message: l10n.adminWalletPartnerNone),
              for (final PartnerTransaction p in w.partnerTransactions)
                AppListRow(
                  inset: false,
                  title: Money.format(l10n, p.signedAmount),
                  subtitle: '${_status(l10n, p.status).$1} · ${adminDateTime(context, p.at)}',
                  leadingIcon: Icons.account_balance_outlined,
                  showChevron: false,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A reason (required) and an internal note (the parent never sees it).
class _FreezeForm extends StatefulWidget {
  const _FreezeForm({required this.frozen});

  final bool frozen;

  @override
  State<_FreezeForm> createState() => _FreezeFormState();
}

class _FreezeFormState extends State<_FreezeForm> {
  final TextEditingController _note = TextEditingController();
  FreezeReason? _reason;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final FreezeReason? reason = _reason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSelectField<FreezeReason>(
          key: const Key('freeze.reason'),
          label: l10n.adminReasonLabel,
          options: <(FreezeReason, String)>[
            for (final FreezeReason r in FreezeReason.values) (r, freezeReasonLabel(l10n, r)),
          ],
          value: reason,
          onChanged: (FreezeReason r) => setState(() => _reason = r),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(key: const Key('freeze.note'), label: l10n.adminNoteLabel, helperText: l10n.adminNoteInternal, controller: _note, maxLength: 300),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('freeze.submit'),
          label: widget.frozen ? l10n.adminWalletFreeze : l10n.adminWalletUnfreeze,
          variant: widget.frozen ? AppButtonVariant.danger : AppButtonVariant.primary,
          expand: true,
          onPressed: reason == null
              ? null
              : () => Navigator.of(context).pop<(FreezeReason, String?)>((reason, _note.text.trim().isEmpty ? null : _note.text.trim())),
        ),
      ],
    );
  }
}
