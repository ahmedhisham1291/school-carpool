import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/onboarding/onboarding_layout.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Step 1: the mobile number (spec section 3, step 1).
///
/// States: empty (the field), checking as the parent types, loading (the
/// button spins while the code is sent), error and offline (a message under
/// the field that says what to do).
class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key});

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  AuthFailure? _failure;

  @override
  void initState() {
    super.initState();
    final String? previous = ref.read(signupFlowProvider).phoneE164;
    if (previous != null) {
      _controller.text = '0${previous.substring(3)}';
    }
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  String? _validate(String? value) {
    final String digits = DigitsInputFormatter.normalize(value ?? '');
    if (digits.length >= 11 && !EgyptPhone.isValid(digits)) {
      return context.l10n.phoneErrorInvalid;
    }
    return null;
  }

  Future<void> _send() async {
    final String? phone = EgyptPhone.toE164(_controller.text);
    if (phone == null || _sending) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    final SignupFlowController flow = ref.read(signupFlowProvider.notifier);
    final String language = ref.read(localeProvider).languageCode;
    setState(() {
      _sending = true;
      _failure = null;
    });
    try {
      final CodeRequest request = await repository.requestCode(phoneE164: phone, language: language);
      flow.codeSent(phone, request.resendAfter);
      if (!mounted) {
        return;
      }
      unawaited(context.push<void>(AuthRoutes.code));
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AuthFailure? failure = _failure;
    final bool valid = EgyptPhone.isValid(_controller.text);

    return OnboardingLayout(
      step: 1,
      title: l10n.phoneTitle,
      body: l10n.phoneBody,
      primary: AppButton(
        key: const Key('phone.send'),
        label: l10n.phoneSendCode,
        expand: true,
        loading: _sending,
        onPressed: valid ? () => unawaited(_send()) : null,
      ),
      children: <Widget>[
        AppTextField(
          key: const Key('phone.field'),
          controller: _controller,
          label: l10n.phoneLabel,
          helperText: l10n.phoneHelper,
          prefixIcon: Icons.phone_iphone_rounded,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          textDirection: TextDirection.ltr,
          autofillHints: const <String>[AutofillHints.telephoneNumber],
          inputFormatters: const <TextInputFormatter>[DigitsInputFormatter(maxDigits: 14)],
          validator: _validate,
          autofocus: true,
          enabled: !_sending,
          onFieldSubmitted: (_) => unawaited(_send()),
        ),
        const SizedBox(height: AppSpacing.s16),
        Text(
          l10n.phoneWhatsAppNote,
          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        if (failure != null) FailureMessage(message: failure.message(l10n), offline: failure.isOffline),
      ],
    );
  }
}
