import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/wallet_labels.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/features/wallet/wallet_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _transferProvider = FutureProvider.autoDispose.family<WalletTransfer, String>(
  retry: noWalletRetry,
  (Ref ref, String id) => ref.watch(walletRepositoryProvider).transfer(id),
);

/// One transfer from the history: amount, status, who, when, the note and,
/// when it failed, why (no money left the wallet). Pending: Check again.
/// "Report a problem" sends it to the admins (the app cannot reverse a
/// transfer; the partner's dispute process handles money disputes).
///
/// States: loading (skeleton), not found (empty), error and offline (retry).
class TransferScreen extends ConsumerWidget {
  const TransferScreen({required this.transferId, super.key});

  final String transferId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<WalletTransfer> t = ref.watch(_transferProvider(transferId));
    void reload() => ref.invalidate(_transferProvider(transferId));
    final Widget body = switch (t) {
      AsyncData<WalletTransfer>(:final WalletTransfer value) => _content(context, ref, value, reload),
      AsyncError<WalletTransfer>(:final Object error) => switch (WalletFailure.from(error)) {
        WalletFailure(isOffline: true) => OfflineStateView(onRetry: reload),
        WalletFailure(kind: WalletFailureKind.notFound) => EmptyStateView(
          key: const Key('transfer.notFound'),
          icon: Icons.search_off_rounded,
          title: l10n.walletTransferNotFound,
          body: l10n.walletErrorNotFound,
        ),
        final WalletFailure f => ErrorStateView(body: f.message(l10n), onRetry: reload),
      },
      _ => const Skeleton(
        child: Column(children: <Widget>[Padding(padding: AppSpacing.screenPadding, child: SkeletonCard()), SkeletonListRow(), SkeletonListRow()]),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.walletTransferTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, WalletTransfer t, VoidCallback reload) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return ListView(
      key: const Key('transfer.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLineText(transferTitle(l10n, t), style: context.text.titleMedium),
                const SizedBox(height: AppSpacing.s8),
                AppAmount(
                  transferAmount(l10n, t),
                  size: AppAmountSize.large,
                  incoming: !t.outgoing && t.status == TransferStatus.done,
                  muted: t.status == TransferStatus.failed,
                ),
                const SizedBox(height: AppSpacing.s8),
                AppStatusBadge(key: const Key('transfer.status'), label: statusLabel(l10n, t.status), tone: statusTone(t.status)),
                if (t.status == TransferStatus.failed) ...<Widget>[
                  const SizedBox(height: AppSpacing.s8),
                  Text(failReasonText(l10n, t.reason), style: quiet),
                ],
                if (t.status == TransferStatus.pending) ...<Widget>[
                  const SizedBox(height: AppSpacing.s8),
                  Text(l10n.walletPendingBody, style: quiet),
                ],
              ],
            ),
          ),
        ),
        AppListRow(title: l10n.walletWhen, subtitle: transferTime(l10n, t.createdAt), leadingIcon: Icons.schedule_rounded, showChevron: false),
        if (t.note.isNotEmpty)
          AppListRow(title: l10n.walletNoteLabel, subtitle: t.note, leadingIcon: Icons.notes_rounded, showChevron: false),
        AppListRow(title: l10n.walletFeeRow, subtitle: l10n.walletNoFee, leadingIcon: Icons.money_off_outlined, showChevron: false),
        const SizedBox(height: AppSpacing.s16),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (t.status == TransferStatus.pending) ...<Widget>[
                AppButton(key: const Key('transfer.check'), label: l10n.walletCheckAgain, icon: Icons.refresh_rounded, expand: true, onPressed: reload),
                const SizedBox(height: AppSpacing.s8),
              ],
              AppButton(
                key: const Key('transfer.report'),
                label: l10n.walletReportAction,
                icon: Icons.flag_outlined,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => unawaited(showReportSheet(context, ref, t)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Report a transfer problem: a reason, an optional note, Send report.
Future<void> showReportSheet(BuildContext context, WidgetRef ref, WalletTransfer t) async {
  final AppLocalizations l10n = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool? frozen = await showAppSheet<bool>(
    context: context,
    title: l10n.walletReportTitle,
    body: _ReportForm(transfer: t, repository: ref.read(walletRepositoryProvider)),
  );
  if (frozen == null) {
    return;
  }
  showAppSnackBarOn(messenger, frozen ? l10n.walletReportedFrozen : l10n.walletReported);
  if (frozen) {
    ref.invalidate(walletInfoProvider);
  }
}

class _ReportForm extends StatefulWidget {
  const _ReportForm({required this.transfer, required this.repository});

  final WalletTransfer transfer;
  final WalletRepository repository;

  @override
  State<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<_ReportForm> {
  WalletReportReason? _reason;
  final TextEditingController _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// "Someone else sent it" only fits a transfer the parent sent.
  List<WalletReportReason> get _reasons => <WalletReportReason>[
    for (final WalletReportReason r in WalletReportReason.values)
      if (r != WalletReportReason.unauthorized || widget.transfer.outgoing) r,
  ];

  Future<void> _send() async {
    final WalletReportReason? reason = _reason;
    if (reason == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bool frozen = await widget.repository.report(transferId: widget.transfer.id, reason: reason, note: _note.text.trim());
      navigator.pop(frozen);
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
    final String? error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.walletReportBody),
        const SizedBox(height: AppSpacing.s16),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final WalletReportReason r in _reasons)
              AppChip(
                key: Key('report.${r.name}'),
                label: reportReasonLabel(l10n, r),
                selected: _reason == r,
                onSelected: _busy ? null : (_) => setState(() => _reason = r),
              ),
          ],
        ),
        if (_reason == WalletReportReason.unauthorized) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('report.freezeNote'), message: l10n.walletReportFreezeNote, tone: AppStateTone.warning),
        ],
        const SizedBox(height: AppSpacing.s16),
        AppTextField(key: const Key('report.note'), controller: _note, label: l10n.walletReportNote, maxLength: 300),
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('report.send'),
          label: l10n.walletReportSend,
          expand: true,
          loading: _busy,
          onPressed: _reason == null ? null : () => unawaited(_send()),
        ),
      ],
    );
  }
}
