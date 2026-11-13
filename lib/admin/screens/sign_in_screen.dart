import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Admin sign-in with two steps (F14): email and password, then the
/// 6-digit code from the authenticator app. Parents cannot sign in here:
/// their accounts have no password and the blocking function refuses any
/// account without the admin claim.
///
/// States: form (button off until both fields are filled), sending (button
/// spinner), error with what to do (wrong password, wrong code, not an
/// admin, offline), and a note when the panel signed out on its own (idle,
/// session over).
class AdminSignInScreen extends ConsumerStatefulWidget {
  const AdminSignInScreen({super.key});

  @override
  ConsumerState<AdminSignInScreen> createState() => _AdminSignInScreenState();
}

class _AdminSignInScreenState extends ConsumerState<AdminSignInScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _needsCode = false;
  bool _busy = false;
  AdminFailure? _failure;

  @override
  void initState() {
    super.initState();
    _email.addListener(_changed);
    _password.addListener(_changed);
    _code.addListener(_changed);
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _emailValid => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim());

  bool get _canSubmit =>
      !_busy && (_needsCode ? _code.text.length == 6 : _emailValid && _password.text.isNotEmpty);

  Future<void> _submit() async {
    if (!_canSubmit) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    ref.read(adminSignOutReasonProvider.notifier).set(null);
    final AdminAuthRepository auth = ref.read(adminAuthRepositoryProvider);
    try {
      if (_needsCode) {
        await auth.verifyCode(_code.text);
      } else {
        final AdminSignInStep step = await auth.signIn(email: _email.text, password: _password.text);
        if (step is AdminSignInNeedsCode && mounted) {
          setState(() => _needsCode = true);
        }
      }
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          if (failure.kind == AdminFailureKind.wrongCode) {
            _code.clear();
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _back() => setState(() {
    _needsCode = false;
    _code.clear();
    _failure = null;
  });

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AdminSignOutReason? reason = ref.watch(adminSignOutReasonProvider);
    final AdminFailure? failure = _failure;
    final String? note = switch (reason) {
      AdminSignOutReason.idle => l10n.adminSignedOutIdle,
      AdminSignOutReason.expired => l10n.adminSignedOutExpired,
      AdminSignOutReason.notAllowed => l10n.adminErrNotAdmin,
      null => null,
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
              child: AppCard(
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      AppStepProgress(current: _needsCode ? 2 : 1, total: 2),
                      const SizedBox(height: AppSpacing.s24),
                      Semantics(
                        header: true,
                        child: OneLine(l10n.adminPanelTitle, style: context.text.headlineSmall),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                      Text(
                        _needsCode ? l10n.adminSignInCodeBody : l10n.adminSignInBody,
                        style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppSpacing.s24),
                      if (note != null && failure == null) ...<Widget>[
                        AppInlineMessage(message: note, icon: Icons.lock_clock_outlined),
                        const SizedBox(height: AppSpacing.s16),
                      ],
                      if (!_needsCode) ...<Widget>[
                        AppTextField(
                          key: const Key('admin.signIn.email'),
                          label: l10n.adminEmailLabel,
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const <String>[AutofillHints.email],
                          textDirection: TextDirection.ltr,
                          textInputAction: TextInputAction.next,
                          autofocus: true,
                          validator: (String? v) =>
                              (v ?? '').isEmpty || _emailValid ? null : l10n.adminEmailError,
                        ),
                        const SizedBox(height: AppSpacing.s16),
                        AppTextField(
                          key: const Key('admin.signIn.password'),
                          label: l10n.adminPasswordLabel,
                          controller: _password,
                          obscureText: true,
                          autofillHints: const <String>[AutofillHints.password],
                          textDirection: TextDirection.ltr,
                          onFieldSubmitted: (_) => unawaited(_submit()),
                        ),
                      ] else
                        AppCodeField(
                          key: const Key('admin.signIn.code'),
                          label: l10n.adminCodeLabel,
                          helperText: l10n.adminCodeHelper,
                          controller: _code,
                          autofocus: true,
                          onCompleted: (_) => unawaited(_submit()),
                        ),
                      if (failure != null) ...<Widget>[
                        const SizedBox(height: AppSpacing.s16),
                        AppInlineMessage(
                          message: failure.message(l10n),
                          tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.s24),
                      AppButton(
                        key: const Key('admin.signIn.submit'),
                        label: _needsCode ? l10n.adminVerifyCode : l10n.adminSignIn,
                        loading: _busy,
                        expand: true,
                        onPressed: _canSubmit ? () => unawaited(_submit()) : null,
                      ),
                      if (_needsCode) ...<Widget>[
                        const SizedBox(height: AppSpacing.s8),
                        AppButton(
                          label: l10n.adminBack,
                          variant: AppButtonVariant.tertiary,
                          onPressed: _busy ? null : _back,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
