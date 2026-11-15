import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
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
/// States: loading the key (skeleton), key shown with "New key", sending
/// (button spinner), error with what to do (wrong code, session over,
/// offline, unknown with Firebase's short code: retry, or sign out and in).
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
  bool _starting = false;

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

  /// Asks for a setup key: at first, on "Try again" and on "New key". The
  /// button shows a spinner meanwhile, so a second failure is still visible
  /// as an answer to the tap.
  Future<void> _start() async {
    if (_starting) {
      return;
    }
    _code.clear();
    setState(() {
      _starting = true;
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
    } finally {
      if (mounted) {
        setState(() => _starting = false);
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
                      child: OneLineText(l10n.adminSetupTitle, style: context.text.headlineSmall, scaleDown: true),
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
                      const SizedBox(height: AppSpacing.s8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppButton(
                          key: const Key('admin.setup.newKey'),
                          label: l10n.adminSetupNewKey,
                          icon: Icons.refresh,
                          variant: AppButtonVariant.tertiary,
                          onPressed: _busy ? null : () => unawaited(_start()),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s16),
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
                      if (setup == null) ...<Widget>[
                        const SizedBox(height: AppSpacing.s8),
                        Text(
                          l10n.adminSetupStuck,
                          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                        ),
                      ],
                    ],
                    const SizedBox(height: AppSpacing.s24),
                    if (setup == null && (failure != null || _starting))
                      AppButton(
                        key: const Key('admin.setup.retry'),
                        label: l10n.actionRetry,
                        loading: _starting,
                        expand: true,
                        onPressed: () => unawaited(_start()),
                      )
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
