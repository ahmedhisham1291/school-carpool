import 'dart:async';

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
import 'package:url_launcher/url_launcher.dart';

/// Add money (test money with the fake partner; the real partner opens its
/// own payment page) and Withdraw (to the parent's account at the partner;
/// needs a fresh Face ID, fingerprint or passcode check).
///
/// Layout: one short sentence, the amount field (checked as the parent
/// types, with the limit in the helper), the summary and one primary
/// button; then the result (done, pending with Check again, or failed with
/// the reason). States: wallet loading (skeleton), error and offline
/// (retry), server answers inline.
class AddMoneyScreen extends StatelessWidget {
  const AddMoneyScreen({super.key});

  @override
  Widget build(BuildContext context) => const _MoneyForm(withdraw: false);
}

class WithdrawScreen extends StatelessWidget {
  const WithdrawScreen({super.key});

  @override
  Widget build(BuildContext context) => const _MoneyForm(withdraw: true);
}

class _MoneyForm extends ConsumerStatefulWidget {
  const _MoneyForm({required this.withdraw});

  final bool withdraw;

  @override
  ConsumerState<_MoneyForm> createState() => _MoneyFormState();
}

class _MoneyFormState extends ConsumerState<_MoneyForm> {
  final TextEditingController _amount = TextEditingController();
  bool _touched = false;
  bool _busy = false;
  bool _checking = false;
  String? _error;
  String? _requestId;
  int? _requestAmount;
  MoneyResult? _result;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String? _amountError(AppLocalizations l10n, WalletInfo info) {
    final int? a = Money.parse(_amount.text);
    if (a == null) {
      return l10n.walletAmountInvalid;
    }
    final int max = widget.withdraw ? info.limits.perTransferMax : info.limits.topUpMax;
    if (a < info.limits.minAmount) {
      return l10n.walletErrorTooSmall(Money.format(l10n, info.limits.minAmount));
    }
    if (a > max) {
      return l10n.walletErrorOverLimit(Money.format(l10n, max));
    }
    if (widget.withdraw) {
      if (a > info.leftToday) {
        return l10n.walletErrorOverDaily(Money.format(l10n, info.leftToday));
      }
      final int? balance = info.balance;
      if (balance != null && a > balance) {
        return l10n.walletAmountOverBalance;
      }
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final int? amount = Money.parse(_amount.text);
    if (amount == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.withdraw) {
        final DeviceAuthResult auth = await ref.read(deviceAuthProvider).confirm(l10n.walletAuthWithdraw(Money.format(l10n, amount)));
        if (auth != DeviceAuthResult.ok) {
          if (mounted) {
            setState(() => _error = auth == DeviceAuthResult.unavailable ? l10n.walletErrorNoPasscode : l10n.walletAuthCancelled);
          }
          return;
        }
      }
      // Same amount as the last try: the same request (a retry cannot run twice).
      if (_requestAmount != amount) {
        _requestId = ref.read(requestIdFactoryProvider)();
        _requestAmount = amount;
      }
      final String id = _requestId!;
      final WalletRepository repo = ref.read(walletRepositoryProvider);
      final MoneyResult result = widget.withdraw
          ? await repo.withdraw(requestId: id, amount: amount)
          : await repo.addMoney(requestId: id, amount: amount);
      final String? checkout = result.checkoutUrl;
      if (checkout != null) {
        final Uri? uri = Uri.tryParse(checkout);
        if (uri != null && uri.scheme == 'https') {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
      if (mounted) {
        setState(() => _result = result);
        ref
          ..invalidate(walletInfoProvider)
          ..invalidate(walletHistoryProvider);
      }
    } on WalletFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.outcomeUnknown ? l10n.walletSendUnknown : f.message(l10n));
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
      final WalletTransfer t = await ref.read(walletRepositoryProvider).transfer(current.transfer.id);
      if (mounted) {
        setState(() => _result = MoneyResult(transfer: t));
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String title = widget.withdraw ? l10n.walletWithdrawTitle : l10n.walletAddTitle;
    final MoneyResult? result = _result;
    final AsyncValue<WalletInfo> info = ref.watch(walletInfoProvider);
    final Widget body;
    if (result != null) {
      body = MoneyOutcomeView(
        transfer: result.transfer,
        checking: _checking,
        onCheckAgain: () => unawaited(_checkAgain()),
        onDone: () => context.go(ProfileRoutes.wallet),
      );
    } else {
      body = switch (info) {
        AsyncData<WalletInfo>(:final WalletInfo value) => _form(context, value),
        AsyncError<WalletInfo>(:final Object error) =>
          WalletFailure.from(error).isOffline
              ? OfflineStateView(onRetry: () => ref.invalidate(walletInfoProvider))
              : ErrorStateView(body: WalletFailure.from(error).message(l10n), onRetry: () => ref.invalidate(walletInfoProvider)),
        _ => const WalletSkeleton(),
      };
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(title)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _form(BuildContext context, WalletInfo info) {
    final AppLocalizations l10n = context.l10n;
    final String? fieldError = _touched ? _amountError(l10n, info) : null;
    final String? error = _error;
    final int max = widget.withdraw ? info.limits.perTransferMax : info.limits.topUpMax;
    final bool ready = Money.parse(_amount.text) != null && _amountError(l10n, info) == null;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return ListView(
      key: Key(widget.withdraw ? 'withdraw.form' : 'add.form'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Text(widget.withdraw ? l10n.walletWithdrawBody : l10n.walletAddBody, style: quiet),
        const SizedBox(height: AppSpacing.s16),
        if (widget.withdraw) ...<Widget>[
          BalanceCard(info: info),
          const SizedBox(height: AppSpacing.s16),
        ],
        AppTextField(
          key: const Key('money.amount'),
          controller: _amount,
          label: l10n.walletAmountLabel,
          helperText: l10n.walletAmountHelper(Money.format(l10n, max)),
          errorText: fieldError,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textDirection: TextDirection.ltr,
          prefixText: l10n.walletCurrencyShort,
          onChanged: (_) => setState(() => _touched = true),
        ),
        const SizedBox(height: AppSpacing.s8),
        Text(l10n.walletNoFee, style: quiet),
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('money.error'), message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('money.submit'),
          label: widget.withdraw ? l10n.walletWithdrawNow : l10n.walletAddNow,
          icon: widget.withdraw ? Icons.fingerprint_rounded : Icons.add_rounded,
          expand: true,
          loading: _busy,
          onPressed: ready && info.status == WalletStatus.active ? () => unawaited(_submit()) : null,
        ),
      ],
    );
  }
}
