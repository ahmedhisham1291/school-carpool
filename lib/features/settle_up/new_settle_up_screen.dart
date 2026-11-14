import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/settle_up/settle_up_labels.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_repository.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Parents of my carpools (or of one carpool). No automatic retry: the
/// list shows its own Retry.
final _contactsProvider = FutureProvider.autoDispose.family<List<SettleContact>, String?>(
  retry: noSettleRetry,
  (Ref ref, String? carpoolId) => ref.watch(settleUpRepositoryProvider).contacts(carpoolId: carpoolId),
);

/// New settle-up record (F45). Three short steps with a progress bar:
/// 1. Who and what: "Ask for a payment" (I am paid) or "I already paid"
///    (I paid), then a parent from my carpools.
/// 2. How much and why: the amount in EGP (checked as the parent types
///    against the server's maximum), a reason and an optional short note.
/// 3. Review, with the line "The app does not move money", then Send.
///
/// Asking for a payment needs my InstaPay address first (the payer copies
/// it); the screen says so and opens the address screen.
///
/// One request ID per review: a double tap or a retry after a lost answer
/// sends the same ID, and the server creates one record.
///
/// States: parents loading (skeleton rows), none (a short note), error and
/// offline (inline with Retry); every server answer is one sentence that
/// says what to do.
class NewSettleUpScreen extends ConsumerStatefulWidget {
  const NewSettleUpScreen({super.key, this.carpoolId});

  final String? carpoolId;

  @override
  ConsumerState<NewSettleUpScreen> createState() => _NewSettleUpScreenState();
}

class _NewSettleUpScreenState extends ConsumerState<NewSettleUpScreen> {
  static const int _steps = 3;

  int _step = 0;
  bool _paid = false;
  SettleContact? _contact;
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  SettleReason _reason = SettleReason.contribution;
  bool _amountTouched = false;
  bool _busy = false;
  String? _error;

  /// The request ID of the record on review; kept for retries.
  String? _requestId;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _go(int step) {
    setState(() {
      _step = step;
      _error = null;
      // Changed before sending: a new record, a new ID.
      if (step < 2) {
        _requestId = null;
      }
    });
  }

  void _back() {
    if (_step > 0) {
      _go(_step - 1);
    } else {
      context.go(SettleUpRoutes.home);
    }
  }

  int get _maxAmount => ref.read(settleProfileProvider).value?.maxAmount ?? SettleProfile.defaultMaxAmount;

  /// Why the typed amount cannot be used, or null.
  String? _amountError(AppLocalizations l10n) {
    final String text = _amount.text.trim();
    if (text.isEmpty) {
      return null;
    }
    final int? amount = Money.parse(text);
    if (amount == null || amount < SettleProfile.minAmount) {
      return l10n.settleAmountInvalid;
    }
    if (amount > _maxAmount) {
      return l10n.settleAmountTooHigh(Money.format(l10n, _maxAmount));
    }
    return null;
  }

  Future<void> _send() async {
    final SettleContact? contact = _contact;
    final int? amount = Money.parse(_amount.text);
    if (_busy || contact == null || amount == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String id = _requestId ??= ref.read(settleRequestIdProvider)();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final SettleUp record = await ref
          .read(settleUpRepositoryProvider)
          .create(
            SettleCreate(
              requestId: id,
              paid: _paid,
              otherUid: contact.uid,
              carpoolId: contact.carpoolId,
              amount: amount,
              reason: _reason,
              note: _note.text.trim(),
            ),
          );
      // The kind and the reason only: never an amount, a name or an address.
      ref
          .read(analyticsProvider)
          .track(AnalyticsEvent.settleUpCreated, <String, Object?>{'kind': _paid ? 'paid' : 'request', 'purpose': _reason.name});
      showAppSnackBarOn(messenger, _paid ? l10n.settleRecorded : l10n.settleSent);
      if (mounted) {
        context.go(record.id.isEmpty ? SettleUpRoutes.home : SettleUpRoutes.record(record.id));
      }
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    // The maximum amount and whether I have an address yet.
    ref.watch(settleProfileProvider);
    final Widget content = switch (_step) {
      0 => _who(context),
      1 => _amountStep(context),
      _ => _review(context),
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? r) {
        if (!didPop) {
          _back();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: AppBarTitle(l10n.settleNewTitle),
          leading: IconButton(
            key: const Key('settleNew.back'),
            tooltip: l10n.actionBack,
            icon: const BackButtonIcon(),
            onPressed: _back,
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            key: Key('settleNew.step$_step'),
            padding: const EdgeInsetsDirectional.only(top: AppSpacing.s16, bottom: AppSpacing.s32),
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                child: AppStepProgress(current: _step + 1, total: _steps),
              ),
              const SizedBox(height: AppSpacing.s16),
              content,
            ],
          ),
        ),
      ),
    );
  }

  Widget _padded(Widget child) =>
      Padding(padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter), child: child);

  Widget _who(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final AsyncValue<List<SettleContact>> contacts = ref.watch(_contactsProvider(widget.carpoolId));
    final AsyncValue<SettleProfile> profile = ref.watch(settleProfileProvider);
    // Asking for a payment needs my address (the payer copies it).
    final bool needsAddress = !_paid && profile.hasValue && profile.value?.address == null;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final List<Widget> rows = switch (contacts) {
      AsyncData<List<SettleContact>>(:final List<SettleContact> value) when value.isEmpty => <Widget>[
        _padded(Text(l10n.settleContactsEmpty, key: const Key('settleNew.contactsEmpty'), style: quiet)),
      ],
      AsyncData<List<SettleContact>>(:final List<SettleContact> value) => <Widget>[
        for (final SettleContact c in value)
          AppListRow(
            key: Key('settleNew.contact.${c.carpoolId}.${c.uid}'),
            title: c.firstName,
            subtitle: c.verified ? c.carpoolName(language) : l10n.settleContactNotVerified,
            leadingIcon: Icons.person_outline_rounded,
            onTap: c.verified && !needsAddress
                ? () {
                    setState(() => _contact = c);
                    _go(1);
                  }
                : null,
          ),
      ],
      AsyncError<List<SettleContact>>(:final Object error) => <Widget>[
        _padded(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppInlineMessage(key: const Key('settleNew.contactsError'), message: SettleFailure.from(error).message(l10n), tone: AppStateTone.error),
              AppButton(
                label: l10n.actionRetry,
                variant: AppButtonVariant.tertiary,
                onPressed: () => ref.invalidate(_contactsProvider(widget.carpoolId)),
              ),
            ],
          ),
        ),
      ],
      _ => const <Widget>[Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()]))],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _padded(Text(l10n.settleWhatTitle, style: context.text.titleMedium)),
        const SizedBox(height: AppSpacing.s8),
        _padded(
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              AppChip(
                key: const Key('settleNew.kindRequest'),
                label: l10n.settleKindRequest,
                selected: !_paid,
                onSelected: (_) => setState(() => _paid = false),
              ),
              AppChip(
                key: const Key('settleNew.kindPaid'),
                label: l10n.settleKindPaid,
                selected: _paid,
                onSelected: (_) => setState(() => _paid = true),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        _padded(Text(_paid ? l10n.settleKindPaidHelper : l10n.settleKindRequestHelper, style: quiet)),
        if (needsAddress) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          _padded(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppInlineMessage(key: const Key('settleNew.needsAddress'), message: l10n.settleErrorNoAddress, tone: AppStateTone.warning, icon: Icons.alternate_email_rounded),
                const SizedBox(height: AppSpacing.s8),
                AppButton(
                  key: const Key('settleNew.addAddress'),
                  label: l10n.settleAddressAdd,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: () => context.go(SettleUpRoutes.address),
                ),
              ],
            ),
          ),
        ],
        AppSectionHeader(l10n.settleWhoSection),
        ...rows,
      ],
    );
  }

  Widget _amountStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String? error = _amountTouched ? _amountError(l10n) : null;
    final String name = _contact?.firstName ?? '';
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(_paid ? l10n.settleAmountTitlePaid(name) : l10n.settleAmountTitleRequest(name), style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('settleNew.amount'),
            controller: _amount,
            label: l10n.walletAmountLabel,
            helperText: l10n.settleAmountHelper(Money.format(l10n, _maxAmount)),
            errorText: error,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textDirection: TextDirection.ltr,
            prefixText: l10n.walletCurrencyShort,
            autofocus: true,
            onChanged: (_) => setState(() => _amountTouched = true),
          ),
          const SizedBox(height: AppSpacing.s16),
          OneLineText(l10n.settleReasonLabel, style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              for (final SettleReason r in SettleReason.values)
                AppChip(
                  key: Key('settleNew.reason.${r.name}'),
                  label: settleReasonLabel(l10n, r),
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('settleNew.note'),
            controller: _note,
            label: l10n.walletNoteLabel,
            helperText: l10n.settleNoteHelper,
            maxLength: 80,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            key: const Key('settleNew.amountNext'),
            label: l10n.actionNext,
            expand: true,
            onPressed: Money.parse(_amount.text) != null && _amountError(l10n) == null ? () => _go(2) : null,
          ),
        ],
      ),
    );
  }

  Widget _review(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final int amount = Money.parse(_amount.text) ?? 0;
    final String note = _note.text.trim();
    final String name = _contact?.firstName ?? '';
    final String? error = _error;
    final TextStyle? label = context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant);
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.settleReviewTitle, style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          AppCard(
            key: const Key('settleNew.summary'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_paid ? l10n.settleReviewPaid(name) : l10n.settleReviewRequest(name), style: context.text.bodyLarge),
                const SizedBox(height: AppSpacing.s8),
                AppAmount(Money.format(l10n, amount), size: AppAmountSize.large),
                const SizedBox(height: AppSpacing.s8),
                OneLineText(l10n.settleReasonLabel, style: label),
                Text(settleReasonLabel(l10n, _reason), style: context.text.bodyLarge),
                if (note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.s8),
                  OneLineText(l10n.walletNoteLabel, style: label),
                  Text(note, style: context.text.bodyLarge),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('settleNew.noMoney'), message: l10n.settleNoMoney),
          if (error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppInlineMessage(key: const Key('settleNew.error'), message: error, tone: AppStateTone.error),
          ],
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            key: const Key('settleNew.send'),
            label: _paid ? l10n.settleRecordAction : l10n.settleSendAction,
            icon: Icons.send_rounded,
            expand: true,
            loading: _busy,
            onPressed: () => unawaited(_send()),
          ),
        ],
      ),
    );
  }
}
