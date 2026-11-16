import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/onboarding/onboarding_layout.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Step 4: terms of use, privacy policy, code of conduct and the separate
/// consent to storage abroad (each must be accepted; Law 151 of 2020),
/// plus optional WhatsApp alerts. The server saves one consent
/// record per accepted document.
///
/// States: empty (nothing ticked: the button is off and a line says why),
/// loading (button spinner), error and offline (a message under the list).
class TermsScreen extends ConsumerStatefulWidget {
  const TermsScreen({super.key});

  @override
  ConsumerState<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends ConsumerState<TermsScreen> {
  bool _terms = false;
  bool _privacy = false;
  bool _conduct = false;
  bool _transfer = false;
  bool _whatsapp = false;
  bool _saving = false;
  AuthFailure? _failure;

  bool get _ready => _terms && _privacy && _conduct && _transfer;

  Future<void> _accept() async {
    if (!_ready || _saving) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      await repository.acceptConsents(whatsapp: _whatsapp);
      // The account record changes and the router opens the next screen.
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _saving = false;
        });
      }
    }
  }

  void _read(String title, String text) {
    final AppLocalizations l10n = context.l10n;
    unawaited(
      showAppSheet<void>(
        context: context,
        title: title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Testers only: the store build never shows a "draft" note
            // (App Review guideline 2.1, no placeholder text).
            if (!ref.read(flavorConfigProvider).isProd) ...<Widget>[
              AppInlineMessage(key: const Key('terms.draftNotice'), message: l10n.termsDraftNotice),
              const SizedBox(height: AppSpacing.s16),
            ],
            Text(text),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AuthFailure? failure = _failure;
    final bool enabled = !_saving;

    return OnboardingLayout(
      step: 4,
      title: l10n.termsTitle,
      body: l10n.termsBody,
      primary: AppButton(
        key: const Key('terms.accept'),
        label: l10n.termsAcceptButton,
        expand: true,
        loading: _saving,
        onPressed: _ready ? () => unawaited(_accept()) : null,
      ),
      children: <Widget>[
        AppCheckRow(
          key: const Key('terms.terms'),
          label: l10n.termsAcceptTerms,
          value: _terms,
          onChanged: enabled ? (bool v) => setState(() => _terms = v) : null,
          actionLabel: l10n.termsRead,
          onAction: () => _read(l10n.termsDocTerms, l10n.termsTermsText),
        ),
        AppCheckRow(
          key: const Key('terms.privacy'),
          label: l10n.termsAcceptPrivacy,
          value: _privacy,
          onChanged: enabled ? (bool v) => setState(() => _privacy = v) : null,
          actionLabel: l10n.termsRead,
          onAction: () => _read(l10n.termsDocPrivacy, l10n.termsPrivacyText),
        ),
        AppCheckRow(
          key: const Key('terms.conduct'),
          label: l10n.termsAcceptConduct,
          value: _conduct,
          onChanged: enabled ? (bool v) => setState(() => _conduct = v) : null,
          actionLabel: l10n.termsRead,
          onAction: () => _read(l10n.termsDocConduct, l10n.termsConductText),
        ),
        AppCheckRow(
          key: const Key('terms.transfer'),
          label: l10n.termsAcceptTransfer,
          helperText: l10n.termsTransferHelper,
          value: _transfer,
          onChanged: enabled ? (bool v) => setState(() => _transfer = v) : null,
          actionLabel: l10n.termsRead,
          onAction: () => _read(l10n.termsDocTransfer, l10n.termsTransferText),
        ),
        const Divider(height: AppSpacing.s32),
        AppCheckRow(
          key: const Key('terms.whatsapp'),
          label: l10n.termsWhatsApp,
          helperText: l10n.termsWhatsAppHelper,
          value: _whatsapp,
          onChanged: enabled ? (bool v) => setState(() => _whatsapp = v) : null,
        ),
        if (!_ready) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(message: l10n.termsRequiredHint),
        ],
        if (failure != null) FailureMessage(message: failure.message(l10n), offline: failure.isOffline),
      ],
    );
  }
}
