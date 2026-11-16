import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/consent_signature.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/onboarding/onboarding_layout.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Step 4: terms of use, privacy policy, code of conduct and the separate
/// consent to storage abroad (each must be accepted; Law 151 of 2020),
/// plus optional WhatsApp alerts. The server saves one consent
/// record per accepted document.
///
/// R3 (written consent): storage abroad is sensitive, so under the boxes
/// the parent types the full name (checked as typed: first and family
/// name), and "Agree and continue" asks for Face ID or the passcode before
/// anything is sent. Cancelling sends nothing.
///
/// States: empty (nothing ticked: the button is off and a line says why),
/// loading (button spinner), error and offline (a message under the list).
///
/// Also shown once to an existing parent who accepted older versions
/// (RegistrationStage.termsUpdate): no step progress, a line saying what
/// changed, and "Privacy" so export and deletion stay reachable without
/// accepting.
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
  final TextEditingController _name = TextEditingController();

  bool get _nameOk => nameLooksFull(_name.text);
  bool get _ready => _terms && _privacy && _conduct && _transfer && _nameOk;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (!_ready || _saving) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _failure = null;
    });
    // R3: a fresh Face ID / passcode check signs the storage-abroad consent.
    final SignOutcome outcome = await signConsent(
      ref,
      fullName: _name.text,
      reason: l10n.signAuthReason,
      language: Localizations.localeOf(context).languageCode == 'en' ? 'en' : 'ar',
    );
    if (outcome is! Signed) {
      if (mounted) {
        setState(() => _saving = false);
      }
      showAppSnackBarOn(messenger, l10n.signCancelled);
      return;
    }
    try {
      await repository.acceptConsents(whatsapp: _whatsapp, signature: outcome.signature);
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
    final bool update = accountOf(ref.watch(sessionProvider))?.stage == RegistrationStage.termsUpdate;

    return OnboardingLayout(
      step: update ? null : 4,
      title: l10n.termsTitle,
      body: update ? l10n.termsUpdatedBody : l10n.termsBody,
      secondary: <Widget>[
        if (update) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('terms.privacy.open'),
            label: l10n.termsUpdatedPrivacy,
            variant: AppButtonVariant.tertiary,
            onPressed: _saving ? null : () => context.go(PrivacyRoutes.privacy),
          ),
        ],
      ],
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
        const SizedBox(height: AppSpacing.s16),
        Semantics(header: true, child: OneLineText(l10n.signTitle, style: context.text.titleSmall)),
        const SizedBox(height: AppSpacing.s8),
        AppTextField(
          key: const Key('terms.signName'),
          controller: _name,
          label: l10n.signNameLabel,
          helperText: l10n.signNameHelper,
          errorText: _name.text.trim().isEmpty || _nameOk ? null : l10n.signNameError,
          textInputAction: TextInputAction.done,
          autofillHints: const <String>[AutofillHints.name],
          enabled: enabled,
          onChanged: (_) => setState(() {}),
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
          AppInlineMessage(message: _terms && _privacy && _conduct && _transfer ? l10n.signHint : l10n.termsRequiredHint),
        ],
        if (failure != null) FailureMessage(message: failure.message(l10n), offline: failure.isOffline),
      ],
    );
  }
}
