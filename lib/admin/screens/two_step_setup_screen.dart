import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// "ABCD EFGH ..." so the setup key is easier to type.
String groupedSetupKey(String key) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < key.length; i++) {
    if (i > 0 && i % 4 == 0) {
      out.write(' ');
    }
    out.write(key[i]);
  }
  return out.toString();
}

/// First sign-in of a new admin: add the panel to an authenticator app
/// (Google Authenticator, Microsoft Authenticator, ...) with the setup key,
/// type the 6-digit code it shows, then sign in again with both steps.
///
/// States: loading the key (skeleton), key shown, sending (button spinner),
/// error with what to do (wrong code, session over, offline: retry).
class TwoStepSetupScreen extends ConsumerStatefulWidget {
  const TwoStepSetupScreen({super.key});

  @override
  ConsumerState<TwoStepSetupScreen> createState() => _TwoStepSetupScreenState();
}

class _TwoStepSetupScreenState extends ConsumerState<TwoStepSetupScreen> {
  final TextEditingController _code = TextEditingController();
  TotpSetup? _setup;
  AdminFailure? _failure;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
    unawaited(_start());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _failure = null;
      _setup = null;
    });
    try {
      final TotpSetup setup = await ref.read(adminAuthRepositoryProvider).startTotpSetup();
      if (mounted) {
        setState(() => _setup = setup);
      }
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    }
  }

  Future<void> _finish() async {
    if (_busy || _code.text.length != 6) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      // Signs out on success; the router then shows sign-in for both steps.
      await ref.read(adminAuthRepositoryProvider).finishTotpSetup(_code.text);
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _code.clear();
        });
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
    final TotpSetup? setup = _setup;
    final AdminFailure? failure = _failure;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: OneLine(l10n.adminSetupTitle, style: context.text.headlineSmall),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    Text(
                      l10n.adminSetupBody,
                      style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.s24),
                    if (setup == null && failure == null)
                      const Skeleton(child: SkeletonCard())
                    else if (setup != null) ...<Widget>[
                      AppCopyValue(label: l10n.adminSetupKey, value: setup.secretKey),
                      const SizedBox(height: AppSpacing.s8),
                      Text(
                        ltrIsolate(groupedSetupKey(setup.secretKey)),
                        style: context.text.titleMedium,
                        textDirection: TextDirection.ltr,
                      ),
                      const SizedBox(height: AppSpacing.s24),
                      AppCodeField(
                        key: const Key('admin.setup.code'),
                        label: l10n.adminCodeLabel,
                        helperText: l10n.adminSetupCodeHelper,
                        controller: _code,
                        onCompleted: (_) => unawaited(_finish()),
                      ),
                    ],
                    if (failure != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.s16),
                      AppInlineMessage(
                        message: failure.message(l10n),
                        tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.s24),
                    if (setup == null && failure != null)
                      AppButton(label: l10n.actionRetry, expand: true, onPressed: () => unawaited(_start()))
                    else
                      AppButton(
                        key: const Key('admin.setup.submit'),
                        label: l10n.adminSetupDone,
                        loading: _busy,
                        expand: true,
                        onPressed: setup != null && _code.text.length == 6 ? () => unawaited(_finish()) : null,
                      ),
                    const SizedBox(height: AppSpacing.s8),
                    AppButton(
                      label: l10n.profileSignOut,
                      variant: AppButtonVariant.tertiary,
                      onPressed: () => unawaited(ref.read(adminAuthRepositoryProvider).signOut()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
