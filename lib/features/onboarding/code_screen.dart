import 'dart:async';

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

/// Step 2: the 6-digit WhatsApp code.
///
/// States: empty (no number yet: a way back to step 1), entering, loading
/// (checking, then the router moves on once signed in), error (wrong,
/// expired, locked, with what to do) and offline. A new code can be asked
/// for after the cooldown, shown as a countdown.
class CodeScreen extends ConsumerStatefulWidget {
  const CodeScreen({super.key});

  @override
  ConsumerState<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends ConsumerState<CodeScreen> {
  static const int _codeLength = 6;

  final TextEditingController _controller = TextEditingController();
  Timer? _ticker;
  bool _verifying = false;
  bool _resending = false;
  AuthFailure? _failure;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  Future<void> _verify() async {
    final String? phone = ref.read(signupFlowProvider).phoneE164;
    final String code = _controller.text;
    if (phone == null || code.length != _codeLength || _verifying) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    final String language = ref.read(localeProvider).languageCode;
    setState(() {
      _verifying = true;
      _failure = null;
    });
    try {
      await repository.verifyCode(phoneE164: phone, code: code, language: language);
      // Signed in: the router's redirect opens the next step.
    } on AuthFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _failure = failure;
        _verifying = false;
      });
      if (failure.kind != AuthFailureKind.offline) {
        _controller.clear();
      }
    }
  }

  Future<void> _resend() async {
    final String? phone = ref.read(signupFlowProvider).phoneE164;
    if (phone == null || _resending) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    final SignupFlowController flow = ref.read(signupFlowProvider.notifier);
    final String language = ref.read(localeProvider).languageCode;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String sent = context.l10n.codeSent;
    setState(() {
      _resending = true;
      _failure = null;
    });
    try {
      final CodeRequest request = await repository.requestCode(phoneE164: phone, language: language);
      flow.codeSent(phone, request.resendAfter);
      _controller.clear();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(sent)));
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _resending = false);
      }
    }
  }

  void _changeNumber() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AuthRoutes.phone);
    }
  }

  static String _clock(Duration remaining) {
    final int seconds = remaining.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final SignupFlowState flow = ref.watch(signupFlowProvider);
    final String? phone = flow.phoneE164;

    if (phone == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyStateView(
          icon: Icons.phone_iphone_rounded,
          title: l10n.phoneTitle,
          body: l10n.phoneBody,
          actionLabel: l10n.codeChangeNumber,
          onAction: () => context.go(AuthRoutes.phone),
        ),
      );
    }

    final AuthFailure? failure = _failure;
    final DateTime? availableAt = flow.resendAvailableAt;
    final Duration remaining = availableAt == null
        ? Duration.zero
        : availableAt.difference(DateTime.now());
    final bool canResend = remaining <= Duration.zero && !_verifying;

    return OnboardingLayout(
      step: 2,
      title: l10n.codeTitle,
      body: l10n.codeBody(EgyptPhone.display(phone)),
      primary: AppButton(
        key: const Key('code.verify'),
        label: l10n.codeVerify,
        expand: true,
        loading: _verifying,
        onPressed: _controller.text.length == _codeLength ? () => unawaited(_verify()) : null,
      ),
      secondary: <Widget>[
        const SizedBox(height: AppSpacing.s8),
        if (canResend)
          AppButton(
            key: const Key('code.resend'),
            label: l10n.codeResend,
            variant: AppButtonVariant.tertiary,
            loading: _resending,
            onPressed: () => unawaited(_resend()),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpacing.minTouchTarget),
            child: Center(
              child: Text(
                l10n.codeResendIn(_clock(remaining)),
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          ),
        AppButton(
          key: const Key('code.changeNumber'),
          label: l10n.codeChangeNumber,
          variant: AppButtonVariant.tertiary,
          onPressed: _verifying ? null : _changeNumber,
        ),
      ],
      children: <Widget>[
        AppCodeField(
          key: const Key('code.field'),
          label: l10n.codeLabel,
          controller: _controller,
          length: _codeLength,
          helperText: l10n.codeHelper,
          enabled: !_verifying,
          autofocus: true,
          onCompleted: (_) => unawaited(_verify()),
        ),
        if (failure != null) FailureMessage(message: failure.message(l10n), offline: failure.isOffline),
      ],
    );
  }
}
