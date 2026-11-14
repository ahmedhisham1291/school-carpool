import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/features/wallet/wallet_repository.dart';
import 'package:school_carpool/features/wallet/wallet_widgets.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Parents of my carpools (or of one carpool). No automatic retry: the
/// list shows its own Retry.
final _contactsProvider = FutureProvider.autoDispose.family<List<WalletContact>, String?>(
  retry: noWalletRetry,
  (Ref ref, String? carpoolId) => ref.watch(walletRepositoryProvider).contacts(carpoolId: carpoolId),
);

/// Send money (F43, spec section 6 "Wallet"). Five short steps with a
/// progress bar:
/// 1. Who: a parent from my carpools, or a typed parent ID (Find).
/// 2. Confirm: the receiver's letter avatar, first name and Verified badge.
/// 3. Amount: checked as the parent types against the server's limits.
/// 4. Note (optional).
/// 5. Review, then Send: a fresh Face ID, fingerprint or passcode check,
///    then the result (sent, pending or failed).
///
/// One request ID per review: a double tap or a retry after a lost answer
/// sends the same ID, and the server sends once. Paying a contribution
/// ([carpoolId] and [amount]) starts with that carpool's organizer and the
/// agreed amount filled in; the parent still confirms everything.
///
/// States: contacts loading (skeleton rows), none (a short note), error and
/// offline (inline with Retry); every server answer is one sentence that
/// says what to do.
class SendMoneyScreen extends ConsumerStatefulWidget {
  const SendMoneyScreen({super.key, this.carpoolId, this.amount});

  final String? carpoolId;

  /// Pre-filled amount in piastres (contribution).
  final int? amount;

  @override
  ConsumerState<SendMoneyScreen> createState() => _SendMoneyScreenState();
}

class _SendMoneyScreenState extends ConsumerState<SendMoneyScreen> {
  static const int _steps = 5;

  int _step = 0;
  Receiver? _receiver;
  bool _autoPicked = false;
  final TextEditingController _parentId = TextEditingController();
  late final TextEditingController _amount = TextEditingController(text: widget.amount == null ? '' : Money.typed(widget.amount!));
  final TextEditingController _note = TextEditingController();
  bool _amountTouched = false;
  String? _lookupError;
  String? _error;
  bool _busy = false;
  bool _checking = false;

  /// The request ID of the transfer on review; kept for retries.
  String? _requestId;

  /// A send went out and no definite answer came back (a lost answer): the
  /// request may exist on the server. Receiver, amount and note are locked
  /// and only the same request ID can be sent again, so a retry can never
  /// become a second transfer. Back leaves to the wallet (its history shows
  /// the transfer once it is settled).
  bool _locked = false;
  MoneyResult? _result;

  @override
  void dispose() {
    _parentId.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  WalletRepository get _repo => ref.read(walletRepositoryProvider);

  void _go(int step) {
    if (_locked) {
      return;
    }
    setState(() {
      _step = step;
      _error = null;
      // Changed before any send went out (or after a definite refusal,
      // which created nothing): a new transfer, a new ID.
      if (step < 4) {
        _requestId = null;
      }
    });
  }

  void _back() {
    if (_locked) {
      context.go(ProfileRoutes.wallet);
      return;
    }
    if (_step > 0) {
      _go(_step - 1);
    } else {
      context.go(ProfileRoutes.wallet);
    }
  }

  void _pick(Receiver r) {
    setState(() {
      _receiver = r;
      _lookupError = null;
    });
    _go(1);
  }

  Future<void> _find() async {
    final AppLocalizations l10n = context.l10n;
    final String id = ParentIds.normalize(_parentId.text);
    if (!ParentIds.isValid(id)) {
      setState(() => _lookupError = l10n.walletParentIdInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _lookupError = null;
    });
    try {
      final ReceiverPreview p = await _repo.lookup(id);
      if (mounted) {
        _pick(Receiver.byParentId(id, p));
      }
    } on WalletFailure catch (f) {
      if (mounted) {
        setState(() => _lookupError = f.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  WalletLimits get _limits => ref.read(walletInfoProvider).value?.limits ?? const WalletLimits();

  /// What is wrong with the typed amount, or null.
  String? _amountError(AppLocalizations l10n) {
    final int? a = Money.parse(_amount.text);
    final WalletInfo? info = ref.read(walletInfoProvider).value;
    if (a == null) {
      return l10n.walletAmountInvalid;
    }
    if (a < _limits.minAmount) {
      return l10n.walletErrorTooSmall(Money.format(l10n, _limits.minAmount));
    }
    if (a > _limits.perTransferMax) {
      return l10n.walletErrorOverLimit(Money.format(l10n, _limits.perTransferMax));
    }
    if (info != null && a > info.leftToday) {
      return l10n.walletErrorOverDaily(Money.format(l10n, info.leftToday));
    }
    final int? balance = info?.balance;
    if (balance != null && a > balance) {
      return l10n.walletAmountOverBalance;
    }
    return null;
  }

  Future<void> _send() async {
    if (_busy) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final Receiver? r = _receiver;
    final int? amount = Money.parse(_amount.text);
    if (r == null || amount == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // MONEY rules: a fresh check before every transfer, never cached.
      final DeviceAuthResult auth = await ref.read(deviceAuthProvider).confirm(l10n.walletAuthReason(Money.format(l10n, amount), r.firstName));
      if (auth != DeviceAuthResult.ok) {
        if (mounted) {
          setState(() => _error = auth == DeviceAuthResult.unavailable ? l10n.walletErrorNoPasscode : l10n.walletAuthCancelled);
        }
        return;
      }
      final String id = _requestId ??= ref.read(requestIdFactoryProvider)();
      final MoneyResult result = await _repo.send(
        SendRequest(requestId: id, receiver: r, amount: amount, note: _note.text.trim(), carpoolId: widget.carpoolId),
      );
      if (mounted) {
        setState(() => _result = result);
        ref
          ..invalidate(walletInfoProvider)
          ..invalidate(walletHistoryProvider);
      }
    } on WalletFailure catch (f) {
      if (mounted) {
        // An unknown outcome keeps the request ID and locks the transfer:
        // trying again cannot send twice.
        setState(() {
          if (f.outcomeUnknown) {
            _locked = true;
          }
          _error = f.outcomeUnknown ? l10n.walletSendUnknown : f.message(l10n);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _checkAgain() async {
    final MoneyResult? current = _result;
    if (current == null) {
      return;
    }
    setState(() => _checking = true);
    try {
      final WalletTransfer t = await _repo.transfer(current.transfer.id);
      if (mounted) {
        setState(() => _result = MoneyResult(transfer: t));
        ref.invalidate(walletHistoryProvider);
      }
    } on WalletFailure catch (f) {
      if (mounted) {
        showAppSnackBar(context, f.message(context.l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  void _autoPick(List<WalletContact> contacts) {
    if (_autoPicked || widget.carpoolId == null || _receiver != null || contacts.isEmpty) {
      return;
    }
    _autoPicked = true;
    final WalletContact pick = contacts.firstWhere((WalletContact c) => c.isAdmin, orElse: () => contacts.first);
    if (contacts.length == 1 || pick.isAdmin) {
      _receiver = Receiver.contact(pick);
      _step = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    ref.listen<AsyncValue<List<WalletContact>>>(_contactsProvider(widget.carpoolId), (_, AsyncValue<List<WalletContact>> next) {
      final List<WalletContact>? list = next.value;
      if (list != null && !_autoPicked) {
        setState(() => _autoPick(list));
      }
    });
    // Limits for the amount check.
    ref.watch(walletInfoProvider);
    final MoneyResult? result = _result;
    if (result != null) {
      return Scaffold(
        appBar: AppBar(title: AppBarTitle(l10n.walletSendTitle), automaticallyImplyLeading: false),
        body: SafeArea(
          top: false,
          child: MoneyOutcomeView(
            transfer: result.transfer,
            checking: _checking,
            onCheckAgain: () => unawaited(_checkAgain()),
            onDone: () => context.go(ProfileRoutes.wallet),
          ),
        ),
      );
    }
    final Widget content = switch (_step) {
      0 => _who(context),
      1 => _confirm(context),
      2 => _amountStep(context),
      3 => _noteStep(context),
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
          title: AppBarTitle(l10n.walletSendTitle),
          leading: IconButton(
            key: const Key('send.back'),
            tooltip: l10n.actionBack,
            icon: const BackButtonIcon(),
            onPressed: _back,
          ),
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            key: Key('send.step$_step'),
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
    final AsyncValue<List<WalletContact>> contacts = ref.watch(_contactsProvider(widget.carpoolId));
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final String? lookupError = _lookupError;
    final List<Widget> rows = switch (contacts) {
      AsyncData<List<WalletContact>>(:final List<WalletContact> value) when value.isEmpty => <Widget>[
        _padded(Text(l10n.walletContactsEmpty, key: const Key('send.contactsEmpty'), style: quiet)),
      ],
      AsyncData<List<WalletContact>>(:final List<WalletContact> value) => <Widget>[
        for (final WalletContact c in value)
          AppListRow(
            key: Key('send.contact.${c.carpoolId}.${c.uid}'),
            title: c.firstName,
            subtitle: c.isAdmin ? l10n.walletContactOrganizer(c.carpoolName(language)) : c.carpoolName(language),
            leadingIcon: Icons.person_outline_rounded,
            onTap: () => _pick(Receiver.contact(c)),
          ),
      ],
      AsyncError<List<WalletContact>>(:final Object error) => <Widget>[
        _padded(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppInlineMessage(message: WalletFailure.from(error).message(l10n), tone: AppStateTone.error),
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
        _padded(Text(l10n.walletWhoTitle, style: context.text.titleMedium)),
        AppSectionHeader(l10n.walletFromCarpools),
        ...rows,
        if (widget.carpoolId == null) ...<Widget>[
          AppSectionHeader(l10n.walletByParentId),
          _padded(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppTextField(
                  key: const Key('send.parentId'),
                  controller: _parentId,
                  label: l10n.walletParentIdLabel,
                  helperText: l10n.walletParentIdHelper,
                  errorText: lookupError,
                  maxLength: 9,
                  textDirection: TextDirection.ltr,
                  inputFormatters: <TextInputFormatter>[UpperCaseTextFormatter()],
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() => _lookupError = null),
                  onFieldSubmitted: (_) => unawaited(_find()),
                ),
                const SizedBox(height: AppSpacing.s8),
                AppButton(
                  key: const Key('send.find'),
                  label: l10n.walletFindParent,
                  icon: Icons.search_rounded,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  loading: _busy,
                  onPressed: ParentIds.isValid(_parentId.text) ? () => unawaited(_find()) : null,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _confirm(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Receiver r = _receiver!;
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.walletConfirmTitle, style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          ReceiverCard(name: r.firstName, verified: r.verified, subtitle: r.parentId == null ? null : l10n.walletParentIdShown(r.parentId!)),
          const SizedBox(height: AppSpacing.s16),
          if (!r.verified) ...<Widget>[
            AppInlineMessage(message: l10n.walletErrorReceiverCannot, tone: AppStateTone.warning),
            const SizedBox(height: AppSpacing.s16),
          ],
          AppButton(
            key: const Key('send.confirmReceiver'),
            label: l10n.walletConfirmYes,
            expand: true,
            onPressed: r.verified ? () => _go(2) : null,
          ),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('send.otherReceiver'),
            label: l10n.walletConfirmOther,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: () {
              setState(() => _receiver = null);
              _go(0);
            },
          ),
        ],
      ),
    );
  }

  Widget _amountStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String? error = _amountTouched ? _amountError(l10n) : null;
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.walletAmountTitle(_receiver?.firstName ?? ''), style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('send.amount'),
            controller: _amount,
            label: l10n.walletAmountLabel,
            helperText: l10n.walletAmountHelper(Money.format(l10n, _limits.perTransferMax)),
            errorText: error,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textDirection: TextDirection.ltr,
            prefixText: l10n.walletCurrencyShort,
            autofocus: widget.amount == null,
            onChanged: (_) => setState(() => _amountTouched = true),
          ),
          if (widget.amount != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppInlineMessage(key: const Key('send.contributionNote'), message: l10n.walletContributionNote),
          ],
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            key: const Key('send.amountNext'),
            label: l10n.actionNext,
            expand: true,
            onPressed: Money.parse(_amount.text) != null && _amountError(l10n) == null ? () => _go(3) : null,
          ),
        ],
      ),
    );
  }

  Widget _noteStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.walletNoteTitle, style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('send.note'),
            controller: _note,
            label: l10n.walletNoteLabel,
            helperText: l10n.walletNoteHelper,
            maxLength: 80,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _go(4),
          ),
          const SizedBox(height: AppSpacing.s24),
          AppButton(key: const Key('send.noteNext'), label: l10n.actionNext, expand: true, onPressed: () => _go(4)),
        ],
      ),
    );
  }

  Widget _review(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Receiver r = _receiver!;
    final int amount = Money.parse(_amount.text) ?? 0;
    final String note = _note.text.trim();
    final String? error = _error;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.walletReviewTitle, style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s16),
          ReceiverCard(name: r.firstName, verified: r.verified),
          const SizedBox(height: AppSpacing.s16),
          AppCard(
            key: const Key('send.summary'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLineText(l10n.walletAmountLabel, style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
                AppAmount(Money.format(l10n, amount), size: AppAmountSize.large),
                const SizedBox(height: AppSpacing.s8),
                Text(l10n.walletNoFee, style: quiet),
                if (note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.s16),
                  OneLineText(l10n.walletNoteLabel, style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant)),
                  Text(note, style: context.text.bodyLarge),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
          Text(l10n.walletReviewNoUndo, style: quiet),
          if (error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppInlineMessage(key: const Key('send.error'), message: error, tone: AppStateTone.error),
          ],
          if (_locked) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppInlineMessage(key: const Key('send.locked'), message: l10n.walletSendLocked, tone: AppStateTone.warning, icon: Icons.lock_outline_rounded),
          ],
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            key: const Key('send.send'),
            label: l10n.walletSendNow,
            icon: Icons.fingerprint_rounded,
            expand: true,
            loading: _busy,
            onPressed: () => unawaited(_send()),
          ),
        ],
      ),
    );
  }
}

/// Parent IDs are typed in capitals.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
