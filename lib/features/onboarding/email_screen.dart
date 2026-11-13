import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/onboarding/onboarding_layout.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// A light check of the address shape; Firebase Auth has the last word.
final RegExp kEmailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

/// Step 3: email with a confirmation link (spec section 3, step 2).
///
/// Two parts: enter the address (checked as typed), then "check your inbox"
/// with "I have confirmed", resend and change. The app also checks again
/// when the parent comes back from the mail app. Loading is the button
/// spinner; errors and offline show under the content.
class EmailScreen extends ConsumerStatefulWidget {
  const EmailScreen({super.key});

  @override
  ConsumerState<EmailScreen> createState() => _EmailScreenState();
}

class _EmailScreenState extends ConsumerState<EmailScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();

  /// The address the link was sent to; null while entering it.
  String? _sentTo;
  bool _busy = false;
  AuthFailure? _failure;
  bool _notYet = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sentTo != null && !_busy) {
      unawaited(_check(silent: true));
    }
  }

  bool get _valid => kEmailPattern.hasMatch(_controller.text.trim());

  String? _validate(String? value) {
    final String text = (value ?? '').trim();
    if (text.isEmpty || kEmailPattern.hasMatch(text)) {
      return null;
    }
    return context.l10n.emailErrorInvalid;
  }

  Future<void> _sendLink({bool again = false}) async {
    final String email = again ? (_sentTo ?? '') : _controller.text.trim();
    if (!kEmailPattern.hasMatch(email) || _busy) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String sentMessage = context.l10n.emailLinkSent;
    setState(() {
      _busy = true;
      _failure = null;
      _notYet = false;
    });
    try {
      await repository.sendEmailLink(email);
      if (!mounted) {
        return;
      }
      setState(() => _sentTo = email);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(sentMessage)));
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Asks the server whether the link was opened. When it was, the account
  /// record changes and the router opens the terms step.
  Future<void> _check({bool silent = false}) async {
    if (_busy) {
      return;
    }
    final AuthRepository repository = ref.read(authRepositoryProvider);
    setState(() {
      _busy = true;
      _failure = null;
      _notYet = false;
    });
    try {
      final bool confirmed = await repository.confirmEmail();
      if (mounted && !confirmed && !silent) {
        setState(() => _notYet = true);
      }
    } on AuthFailure catch (failure) {
      if (mounted && !silent) {
        setState(() => _failure = failure);
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
    final AuthFailure? failure = _failure;
    final String? sentTo = _sentTo;
    final List<Widget> messages = <Widget>[
      if (_notYet)
        Padding(
          padding: const EdgeInsetsDirectional.only(top: AppSpacing.s16),
          child: AppInlineMessage(message: l10n.emailNotYet, icon: Icons.schedule_rounded),
        ),
      if (failure != null) FailureMessage(message: failure.message(l10n), offline: failure.isOffline),
    ];

    if (sentTo == null) {
      return OnboardingLayout(
        step: 3,
        title: l10n.emailTitle,
        body: l10n.emailBody,
        primary: AppButton(
          key: const Key('email.send'),
          label: l10n.emailSendLink,
          expand: true,
          loading: _busy,
          onPressed: _valid ? () => unawaited(_sendLink()) : null,
        ),
        children: <Widget>[
          AppTextField(
            key: const Key('email.field'),
            controller: _controller,
            label: l10n.emailLabel,
            helperText: l10n.emailHelper,
            prefixIcon: Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            textDirection: TextDirection.ltr,
            autofillHints: const <String>[AutofillHints.email],
            validator: _validate,
            enabled: !_busy,
            onFieldSubmitted: (_) => unawaited(_sendLink()),
          ),
          ...messages,
        ],
      );
    }

    return OnboardingLayout(
      step: 3,
      title: l10n.emailCheckTitle,
      body: l10n.emailCheckBody(ltrIsolate(sentTo)),
      primary: AppButton(
        key: const Key('email.confirmed'),
        label: l10n.emailConfirmed,
        expand: true,
        loading: _busy,
        onPressed: () => unawaited(_check()),
      ),
      secondary: <Widget>[
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          key: const Key('email.resend'),
          label: l10n.emailResend,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy ? null : () => unawaited(_sendLink(again: true)),
        ),
        AppButton(
          key: const Key('email.change'),
          label: l10n.emailChange,
          variant: AppButtonVariant.tertiary,
          onPressed: _busy
              ? null
              : () => setState(() {
                  _sentTo = null;
                  _notYet = false;
                  _failure = null;
                }),
        ),
      ],
      children: <Widget>[
        AppInlineMessage(message: l10n.emailSpamHint, icon: Icons.mark_email_unread_outlined),
        ...messages,
      ],
    );
  }
}
