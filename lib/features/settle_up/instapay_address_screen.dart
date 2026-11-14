import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// My InstaPay address (F45): one field (`name@instapay`), checked as the
/// parent types, with where to find it and who will see it. Save is the one
/// primary action; Remove asks first.
///
/// The address is private: it is shown only to me and to a parent who has
/// an open request from me. The app never asks for bank or card details.
///
/// States: loading (skeleton), error and offline (retry), saving (the
/// button is busy), a server refusal (one sentence under the field).
class InstaPayAddressScreen extends ConsumerStatefulWidget {
  const InstaPayAddressScreen({super.key});

  @override
  ConsumerState<InstaPayAddressScreen> createState() => _InstaPayAddressScreenState();
}

class _InstaPayAddressScreenState extends ConsumerState<InstaPayAddressScreen> {
  final TextEditingController _field = TextEditingController();
  bool _filled = false;
  bool _touched = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? address = InstaPayAddress.normalize(_field.text);
    if (address == null) {
      setState(() => _touched = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settleUpRepositoryProvider).saveAddress(address);
      // The step only: never the address.
      ref.read(analyticsProvider).track(AnalyticsEvent.settleUpAddress, <String, Object?>{'step': 'saved'});
      ref.invalidate(settleProfileProvider);
      showAppSnackBarOn(messenger, l10n.settleAddressSaved);
      if (mounted) {
        context.go(SettleUpRoutes.home);
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

  Future<void> _remove() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.settleAddressRemoveTitle,
      body: l10n.settleAddressRemoveBody,
      confirmLabel: l10n.settleAddressRemove,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settleUpRepositoryProvider).removeAddress();
      ref.read(analyticsProvider).track(AnalyticsEvent.settleUpAddress, <String, Object?>{'step': 'removed'});
      ref.invalidate(settleProfileProvider);
      showAppSnackBarOn(messenger, l10n.settleAddressRemoved);
      if (mounted) {
        context.go(SettleUpRoutes.home);
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
    final AsyncValue<SettleProfile> profile = ref.watch(settleProfileProvider);
    void retry() => ref.invalidate(settleProfileProvider);
    final Widget body = switch (profile) {
      AsyncData<SettleProfile>(:final SettleProfile value) => _form(context, value),
      AsyncError<SettleProfile>(:final Object error) =>
        SettleFailure.from(error).isOffline
            ? OfflineStateView(onRetry: retry)
            : ErrorStateView(key: const Key('ipa.error'), body: SettleFailure.from(error).message(l10n), onRetry: retry),
      _ => const Skeleton(
        child: Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[SkeletonCard(), SizedBox(height: AppSpacing.s16), SkeletonBox(height: AppSpacing.s48)],
          ),
        ),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.settleAddressTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _form(BuildContext context, SettleProfile profile) {
    final AppLocalizations l10n = context.l10n;
    final String? saved = profile.address;
    if (!_filled) {
      // Once, when the saved address arrives.
      _filled = true;
      _field.text = saved ?? '';
    }
    final String typed = _field.text.trim();
    final bool valid = InstaPayAddress.isValid(typed);
    final String? fieldError = _error ?? (_touched && typed.isNotEmpty && !valid ? l10n.settleAddressInvalid : null);
    final bool changed = InstaPayAddress.normalize(typed) != saved;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return ListView(
      key: const Key('ipa.form'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Text(l10n.settleAddressIntro, style: quiet),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('ipa.field'),
          controller: _field,
          label: l10n.settleAddressLabel,
          hintText: l10n.settleAddressHint,
          helperText: l10n.settleAddressHelper,
          errorText: fieldError,
          prefixIcon: Icons.alternate_email_rounded,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          textDirection: TextDirection.ltr,
          maxLength: 60,
          enabled: !_busy,
          onChanged: (_) => setState(() {
            _touched = true;
            _error = null;
          }),
          onFieldSubmitted: (_) => unawaited(_save()),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppInlineMessage(key: const Key('ipa.private'), message: l10n.settleAddressPrivate, icon: Icons.lock_outline_rounded),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('ipa.save'),
          label: l10n.actionSave,
          icon: Icons.check_rounded,
          expand: true,
          loading: _busy,
          onPressed: valid && changed ? () => unawaited(_save()) : null,
        ),
        if (saved != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('ipa.remove'),
            label: l10n.settleAddressRemove,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: _busy ? null : () => unawaited(_remove()),
          ),
        ],
      ],
    );
  }
}
