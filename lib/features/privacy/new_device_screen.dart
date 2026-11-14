import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// New phone check (spec section 7: "treat a login from a new phone as
/// risky ... ask for a fresh selfie before chats and child data open";
/// Prompt 12 adds the wallet). Layout: an icon, one sentence on why, and
/// the one primary action "Take a selfie" (the verification camera, no
/// gallery). A match opens everything again (the session refreshes on its
/// own); a mismatch says so and asks to contact us.
///
/// States: idle, busy (button spinner), error with how to fix it, done.
class NewDeviceScreen extends ConsumerStatefulWidget {
  const NewDeviceScreen({super.key});

  @override
  ConsumerState<NewDeviceScreen> createState() => _NewDeviceScreenState();
}

class _NewDeviceScreenState extends ConsumerState<NewDeviceScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _selfie() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final SessionState session = ref.read(sessionProvider);
    if (session is! SessionSignedIn) {
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
      await ref.read(privacyRepositoryProvider).confirmNewDevice(uid: session.uid, selfie: shot.image);
      showAppSnackBarOn(messenger, l10n.newDeviceDone);
      if (mounted) {
        context.go(AppTab.profile.path);
      }
    } on PrivacyFailure catch (f) {
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
    final String? error = _error;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.newDeviceTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            Icon(Icons.phonelink_lock_outlined, size: AppIconSize.xl, color: context.colors.primary),
            const SizedBox(height: AppSpacing.s16),
            Text(l10n.newDeviceBody, style: context.text.bodyLarge),
            const SizedBox(height: AppSpacing.s8),
            Text(l10n.newDeviceNotYou, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
            if (error != null) ...<Widget>[
              const SizedBox(height: AppSpacing.s16),
              AppInlineMessage(key: const Key('newDevice.error'), message: error, tone: AppStateTone.error),
            ],
            const SizedBox(height: AppSpacing.s24),
            AppButton(
              key: const Key('newDevice.selfie'),
              label: l10n.newDeviceAction,
              icon: Icons.photo_camera_front_outlined,
              expand: true,
              loading: _busy,
              onPressed: _busy ? null : () => unawaited(_selfie()),
            ),
          ],
        ),
      ),
    );
  }
}
