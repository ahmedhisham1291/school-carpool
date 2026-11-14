import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/app_settings.dart';

enum PhoneChangeStep { number, code, selfie, done }

/// Change phone number (spec section 3: re-verify when the phone number
/// changes). Three short steps with a progress bar: the new number (a
/// WhatsApp code goes to it), the code, and a live selfie matched to the
/// photo taken at verification. Only then the number changes. The selfie
/// is deleted on the server right after the check.
///
/// States: each step shows its own spinner while sending and says how to
/// fix an error under the field; offline shows the short offline message.
/// A code that was used up (face not matched, number taken) sends the
/// parent back to step one for a new code.
class PhoneChangeScreen extends ConsumerStatefulWidget {
  const PhoneChangeScreen({super.key});

  @override
  ConsumerState<PhoneChangeScreen> createState() => _PhoneChangeScreenState();
}

class _PhoneChangeScreenState extends ConsumerState<PhoneChangeScreen> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  PhoneChangeStep _step = PhoneChangeStep.number;
  String? _e164;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _phone.addListener(_changed);
    _code.addListener(_changed);
  }

  @override
  void dispose() {
    _phone
      ..removeListener(_changed)
      ..dispose();
    _code
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _fail(TrustFailure f, AppLocalizations l10n) {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = f.message(l10n);
      final AuthFailureKind? code = f.auth?.kind;
      if (f.kind == TrustFailureKind.code && code == AuthFailureKind.wrongCode) {
        _step = PhoneChangeStep.code;
      } else if (f.kind == TrustFailureKind.code ||
          f.kind == TrustFailureKind.selfieMismatch ||
          f.kind == TrustFailureKind.phoneTaken ||
          f.kind == TrustFailureKind.checkUnavailable) {
        // The code is used up (or expired): start again with a new one.
        _step = PhoneChangeStep.number;
        _code.clear();
      }
    });
  }

  Future<void> _sendCode() async {
    final AppLocalizations l10n = context.l10n;
    final String? phone = EgyptPhone.toE164(_phone.text);
    if (phone == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(trustRepositoryProvider).requestPhoneChange(phoneE164: phone, language: ref.read(localeProvider).languageCode);
      if (mounted) {
        setState(() {
          _e164 = phone;
          _step = PhoneChangeStep.code;
        });
      }
    } on TrustFailure catch (f) {
      _fail(f, l10n);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _selfie() async {
    final AppLocalizations l10n = context.l10n;
    final String? phone = _e164;
    final SessionState session = ref.read(sessionProvider);
    if (phone == null || session is! SessionSignedIn) {
      return;
    }
    final CaptureResult? shot = await ref.read(captureLauncherProvider)(context, const CaptureRequest(CaptureKind.selfie));
    if (shot == null || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(trustRepositoryProvider).confirmPhoneChange(uid: session.uid, phoneE164: phone, code: _code.text, selfie: shot.image);
      if (mounted) {
        setState(() => _step = PhoneChangeStep.done);
      }
    } on TrustFailure catch (f) {
      _fail(f, l10n);
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
    final Widget content = switch (_step) {
      PhoneChangeStep.number => _numberStep(context),
      PhoneChangeStep.code => _codeStep(context),
      PhoneChangeStep.selfie => _selfieStep(context),
      PhoneChangeStep.done => EmptyStateView(
        key: const Key('phone.done'),
        icon: Icons.check_circle_outline_rounded,
        title: l10n.phoneChangeDoneTitle,
        body: l10n.phoneChangeDoneBody(EgyptPhone.display(_e164 ?? '')),
        actionLabel: l10n.phoneChangeBack,
        onAction: () => context.go(AppTab.profile.path),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.phoneChangeTitle)),
      body: SafeArea(
        top: false,
        child: _step == PhoneChangeStep.done
            ? content
            : ListView(
                key: const Key('phone.list'),
                padding: AppSpacing.screenPadding,
                children: <Widget>[
                  AppStepProgress(current: _step.index + 1, total: 3),
                  const SizedBox(height: AppSpacing.s24),
                  content,
                  if (error != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.s16),
                    AppInlineMessage(key: const Key('phone.error'), message: error, tone: AppStateTone.error),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _numberStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String digits = DigitsInputFormatter.normalize(_phone.text);
    final bool valid = EgyptPhone.isValid(digits);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.phoneChangeIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('phone.new'),
          controller: _phone,
          label: l10n.phoneChangeNewLabel,
          helperText: l10n.phoneHelper,
          errorText: digits.length >= 11 && !valid ? l10n.phoneErrorInvalid : null,
          prefixIcon: Icons.phone_iphone_rounded,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          inputFormatters: const <TextInputFormatter>[DigitsInputFormatter(maxDigits: 14)],
          enabled: !_busy,
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('phone.sendCode'),
          label: l10n.phoneChangeSendCode,
          icon: Icons.send_rounded,
          expand: true,
          loading: _busy,
          onPressed: valid && !_busy ? () => unawaited(_sendCode()) : null,
        ),
      ],
    );
  }

  Widget _codeStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(l10n.phoneChangeCodeIntro(EgyptPhone.display(_e164 ?? '')), style: context.text.bodyMedium),
        const SizedBox(height: AppSpacing.s16),
        AppCodeField(
          key: const Key('phone.code'),
          label: l10n.phoneChangeCodeLabel,
          controller: _code,
          helperText: l10n.codeHelper,
          enabled: !_busy,
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('phone.next'),
          label: l10n.phoneChangeNext,
          expand: true,
          onPressed: RegExp(r'^\d{6}$').hasMatch(_code.text) ? () => setState(() {
            _error = null;
            _step = PhoneChangeStep.selfie;
          }) : null,
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          key: const Key('phone.otherNumber'),
          label: l10n.phoneChangeOtherNumber,
          variant: AppButtonVariant.tertiary,
          expand: true,
          onPressed: _busy ? null : () => setState(() {
            _error = null;
            _code.clear();
            _step = PhoneChangeStep.number;
          }),
        ),
      ],
    );
  }

  Widget _selfieStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Icon(Icons.face_retouching_natural_outlined, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
        const SizedBox(height: AppSpacing.s16),
        Text(l10n.phoneChangeSelfieIntro, style: context.text.bodyMedium),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('phone.selfie'),
          label: l10n.phoneChangeSelfieAction,
          icon: Icons.photo_camera_front_outlined,
          expand: true,
          loading: _busy,
          onPressed: _busy ? null : () => unawaited(_selfie()),
        ),
      ],
    );
  }
}
