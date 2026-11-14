import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/settle_up/settle_up_labels.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_repository.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';

/// The payee's InstaPay address for one open record I have to pay. Asked
/// from the server each time the screen opens (never stored on the phone).
final _payeeAddressProvider = FutureProvider.autoDispose.family<String?, String>(
  retry: noSettleRetry,
  (Ref ref, String id) => ref.watch(settleUpRepositoryProvider).addressFor(id),
);

/// One settle-up record (F45). Layout, top to bottom: the amount, who pays
/// whom, the state and what happens next; the reason and the note; for the
/// payer of an open record the payee's InstaPay address with a Copy button
/// and the three steps (copy, pay in InstaPay, come back and tap "I
/// paid"), then the line "The app does not move money" (on a payment I
/// recorded myself, or a reported record, a note to ask the parent for the
/// address instead: the app shows an address only on a request its owner
/// made); the actions for my
/// side and the record's state (one primary); Report once it bounced
/// enough times; and the history.
///
/// The app opens no payment app and builds no payment link: InstaPay
/// publishes no link or URL scheme that an app may build with a payee and
/// an amount, so the parent copies the address (docs/progress/improve-a.md).
///
/// States: loading (skeleton), not found or not mine (empty), error and
/// offline (retry); a refused action is one sentence above the buttons.
class SettleUpDetailScreen extends ConsumerStatefulWidget {
  const SettleUpDetailScreen({required this.id, super.key});

  final String id;

  @override
  ConsumerState<SettleUpDetailScreen> createState() => _SettleUpDetailScreenState();
}

class _SettleUpDetailScreenState extends ConsumerState<SettleUpDetailScreen> {
  bool _busy = false;
  String? _error;

  /// Words for analytics: lowercase, never an amount or a name.
  static String _step(SettleAction a) => switch (a) {
    SettleAction.paid => 'paid',
    SettleAction.received => 'received',
    SettleAction.notReceived => 'not-received',
    SettleAction.cancel => 'cancel',
    SettleAction.decline => 'decline',
  };

  Future<void> _run(Future<void> Function(SettleUpRepository repo) body, String done) async {
    if (_busy) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body(ref.read(settleUpRepositoryProvider));
      showAppSnackBarOn(messenger, done);
    } on SettleFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _act(SettleAction action) async {
    final AppLocalizations l10n = context.l10n;
    // Every step except "I paid" ends something: ask first.
    // Title, body, confirm label, destructive.
    final (String, String, String, bool)? ask = switch (action) {
      SettleAction.paid => null,
      SettleAction.received => (l10n.settleConfirmReceivedTitle, l10n.settleConfirmReceivedBody, l10n.settleReceivedAction, false),
      SettleAction.notReceived => (l10n.settleConfirmNotReceivedTitle, l10n.settleConfirmNotReceivedBody, l10n.settleNotReceivedAction, false),
      SettleAction.cancel => (l10n.settleConfirmCancelTitle, l10n.settleConfirmCancelBody, l10n.settleCancelAction, true),
      SettleAction.decline => (l10n.settleConfirmDeclineTitle, l10n.settleConfirmDeclineBody, l10n.settleDeclineAction, true),
    };
    if (ask != null) {
      final bool ok = await showConfirmDialog(context: context, title: ask.$1, body: ask.$2, confirmLabel: ask.$3, destructive: ask.$4);
      if (!ok || !mounted) {
        return;
      }
    }
    final String done = switch (action) {
      SettleAction.paid => l10n.settleDonePaid,
      SettleAction.received => l10n.settleDoneReceived,
      SettleAction.notReceived => l10n.settleDoneNotReceived,
      SettleAction.cancel => l10n.settleDoneCancelled,
      SettleAction.decline => l10n.settleDoneDeclined,
    };
    await _run((SettleUpRepository repo) async {
      await repo.act(widget.id, action);
      ref.read(analyticsProvider).track(AnalyticsEvent.settleUpAction, <String, Object?>{'step': _step(action)});
    }, done);
  }

  Future<void> _report() async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.settleReportTitle,
      body: l10n.settleReportBody,
      confirmLabel: l10n.settleReportAction,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run((SettleUpRepository repo) async {
      await repo.report(widget.id);
      ref.read(analyticsProvider).track(AnalyticsEvent.settleUpAction, <String, Object?>{'step': 'report'});
    }, l10n.settleReportDone);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String uid = ref.watch(settleUidProvider);
    final AsyncValue<List<SettleUp>> records = ref.watch(settleUpsProvider);
    void retry() => ref.invalidate(settleUpsProvider);
    final Widget body;
    switch (records) {
      case AsyncData<List<SettleUp>>(:final List<SettleUp> value):
        SettleUp? found;
        for (final SettleUp r in value) {
          if (r.id == widget.id && r.roleOf(uid) != null) {
            found = r;
          }
        }
        final SettleUp? record = found;
        body = record == null
            ? EmptyStateView(key: const Key('settleDetail.notFound'), icon: Icons.search_off_rounded, title: l10n.settleNotFoundTitle, body: l10n.settleErrorNotFound)
            : _content(context, record, record.roleOf(uid) ?? SettleRole.payee);
      case AsyncError<List<SettleUp>>(:final Object error):
        body = SettleFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(key: const Key('settleDetail.error'), onRetry: retry);
      default:
        body = const Skeleton(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(padding: AppSpacing.screenPadding, child: SkeletonCard()),
              SkeletonListRow(),
              SkeletonListRow(),
            ],
          ),
        );
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.settleDetailTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, SettleUp r, SettleRole mine) {
    final AppLocalizations l10n = context.l10n;
    final String name = settleOtherName(l10n, r, mine);
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final TextStyle? label = context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant);
    final List<SettleAction> actions = r.actionsFor(mine);
    final int reportAfter = ref.watch(settleProfileProvider).value?.reportAfter ?? 2;
    final String? error = _error;
    const EdgeInsetsDirectional gutter = EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter);
    final bool payNow = r.status == SettleStatus.open && mine == SettleRole.payer;
    // The address is shown only on a request the PAYEE made, and not once
    // it was reported (the server refuses anything else: a payment I
    // recorded myself never opens the other parent's address).
    final bool showAddress = payNow && r.createdBy == SettleRole.payee && r.reportedBy.isEmpty;

    return ListView(
      key: const Key('settleDetail.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: AppCard(
            key: const Key('settleDetail.summary'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(mine == SettleRole.payer ? l10n.settleDetailYouPay(name) : l10n.settleDetailPaysYou(name), style: context.text.bodyLarge),
                const SizedBox(height: AppSpacing.s4),
                AppAmount(Money.format(l10n, r.amount), size: AppAmountSize.large),
                const SizedBox(height: AppSpacing.s8),
                AppStatusBadge(
                  key: const Key('settleDetail.status'),
                  label: settleStatusLabel(l10n, r.status),
                  tone: settleStatusTone(r.status),
                  scaleDown: true,
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(settleNextStep(l10n, r, mine), key: const Key('settleDetail.next'), style: quiet),
                const SizedBox(height: AppSpacing.s16),
                OneLineText(l10n.settleReasonLabel, style: label),
                Text(settleReasonLabel(l10n, r.reason), style: context.text.bodyLarge),
                if (r.note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.s8),
                  OneLineText(l10n.walletNoteLabel, style: label),
                  Text(r.note, style: context.text.bodyLarge),
                ],
              ],
            ),
          ),
        ),
        if (payNow && !showAddress) ...<Widget>[
          Padding(
            padding: gutter,
            child: AppInlineMessage(
              key: const Key('settleDetail.askAddress'),
              message: l10n.settleAskAddress(name),
              icon: Icons.alternate_email_rounded,
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        if (showAddress) ...<Widget>[
          Padding(padding: gutter, child: _PayeeAddress(id: r.id, name: name)),
          const SizedBox(height: AppSpacing.s16),
          Padding(
            padding: gutter,
            child: Column(
              key: const Key('settleDetail.steps'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Semantics(header: true, child: Text(l10n.settleHowTitle, style: context.text.titleSmall)),
                const SizedBox(height: AppSpacing.s8),
                Text(l10n.settleHowStep1, style: context.text.bodyMedium),
                const SizedBox(height: AppSpacing.s4),
                Text(l10n.settleHowStep2, style: context.text.bodyMedium),
                const SizedBox(height: AppSpacing.s4),
                Text(l10n.settleHowStep3, style: context.text.bodyMedium),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        Padding(
          padding: gutter,
          child: AppInlineMessage(key: const Key('settleDetail.noMoney'), message: l10n.settleNoMoney),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
            child: AppInlineMessage(key: const Key('settleDetail.actionError'), message: error, tone: AppStateTone.error),
          ),
        if (actions.isNotEmpty || r.canReport(mine, reportAfter))
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s24, AppSpacing.screenGutter, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final SettleAction a in actions) ...<Widget>[
                  AppButton(
                    key: Key('settleDetail.${a.name}'),
                    label: _actionLabel(l10n, a),
                    icon: _primary(a) ? Icons.check_rounded : null,
                    variant: _primary(a) ? AppButtonVariant.primary : AppButtonVariant.secondary,
                    expand: true,
                    loading: _busy && _primary(a),
                    onPressed: _busy ? null : () => unawaited(_act(a)),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                ],
                if (r.canReport(mine, reportAfter))
                  AppButton(
                    key: const Key('settleDetail.report'),
                    label: l10n.settleReportAction,
                    icon: Icons.flag_outlined,
                    variant: AppButtonVariant.tertiary,
                    expand: true,
                    onPressed: _busy ? null : () => unawaited(_report()),
                  ),
              ],
            ),
          ),
        AppSectionHeader(l10n.settleHistorySection),
        for (final SettleEvent e in r.events)
          AppListRow(
            title: settleEventLabel(l10n, e, mine),
            subtitle: settleTime(l10n, e.at),
            leadingIcon: _eventIcon(e.type),
            showChevron: false,
          ),
      ],
    );
  }

  /// "I paid" and "Received" move the record forward: the one primary action.
  static bool _primary(SettleAction a) => a == SettleAction.paid || a == SettleAction.received;

  static String _actionLabel(AppLocalizations l10n, SettleAction a) => switch (a) {
    SettleAction.paid => l10n.settlePaidAction,
    SettleAction.received => l10n.settleReceivedAction,
    SettleAction.notReceived => l10n.settleNotReceivedAction,
    SettleAction.cancel => l10n.settleCancelAction,
    SettleAction.decline => l10n.settleDeclineAction,
  };

  static IconData _eventIcon(SettleEventType t) => switch (t) {
    SettleEventType.requested => Icons.request_quote_outlined,
    SettleEventType.recorded || SettleEventType.paid => Icons.payments_outlined,
    SettleEventType.received => Icons.check_circle_outline_rounded,
    SettleEventType.notReceived => Icons.report_gmailerrorred_outlined,
    SettleEventType.cancelled || SettleEventType.declined => Icons.cancel_outlined,
    SettleEventType.reported => Icons.flag_outlined,
    SettleEventType.accountClosed => Icons.person_off_outlined,
  };
}

/// The payee's InstaPay address with Copy. Loading: a skeleton line. No
/// address saved: a note to ask the parent. Error and offline: one
/// sentence with Retry. The address reads left to right in both languages.
class _PayeeAddress extends ConsumerWidget {
  const _PayeeAddress({required this.id, required this.name});

  final String id;
  final String name;

  Future<void> _copy(BuildContext context, String address) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String done = context.l10n.settleAddressCopied;
    await Clipboard.setData(ClipboardData(text: address));
    showAppSnackBarOn(messenger, done);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<String?> address = ref.watch(_payeeAddressProvider(id));
    return switch (address) {
      AsyncData<String?>(:final String? value) when value == null => AppInlineMessage(
        key: const Key('settleDetail.noAddress'),
        message: l10n.settleNoAddressYet(name),
        tone: AppStateTone.warning,
        icon: Icons.alternate_email_rounded,
      ),
      AsyncData<String?>(:final String? value) => AppCard(
        key: const Key('settleDetail.address'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OneLineText(l10n.settleAddressOf(name), style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.s4),
            SelectableText(
              value ?? '',
              key: const Key('settleDetail.addressValue'),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.start,
              style: context.text.titleMedium?.copyWith(color: context.colors.primary),
            ),
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              key: const Key('settleDetail.copy'),
              label: l10n.settleCopyAction,
              icon: Icons.copy_rounded,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () => unawaited(_copy(context, value ?? '')),
            ),
          ],
        ),
      ),
      AsyncError<String?>(:final Object error) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppInlineMessage(key: const Key('settleDetail.addressError'), message: SettleFailure.from(error).message(l10n), tone: AppStateTone.error),
          AppButton(label: l10n.actionRetry, variant: AppButtonVariant.tertiary, onPressed: () => ref.invalidate(_payeeAddressProvider(id))),
        ],
      ),
      _ => const Skeleton(child: SkeletonCard()),
    };
  }
}
