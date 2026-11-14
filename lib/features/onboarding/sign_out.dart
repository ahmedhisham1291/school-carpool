import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Asks for confirmation, then signs out. The router then opens the
/// welcome screen. Shows a short snack bar if signing out fails.
Future<void> confirmAndSignOut(BuildContext context, WidgetRef ref) async {
  final AppLocalizations l10n = context.l10n;
  final AuthRepository repository = ref.read(authRepositoryProvider);
  final SignupFlowController flow = ref.read(signupFlowProvider.notifier);
  final PendingInvite pendingInvite = ref.read(pendingInviteProvider.notifier);
  final NotificationCenter notifications = ref.read(notificationCenterProvider);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final bool confirmed = await showConfirmDialog(
    context: context,
    title: l10n.profileSignOutConfirmTitle,
    body: l10n.profileSignOutConfirmBody,
    confirmLabel: l10n.profileSignOut,
  );
  if (!confirmed) {
    return;
  }
  try {
    flow.reset();
    // Prompt 8: this phone stops getting this parent's pushes and alarms
    // (best effort, a few seconds at most).
    await notifications.unregister();
    await repository.signOut();
    // An invite code kept for later belongs to this parent only.
    await pendingInvite.save(null);
  } on AuthFailure catch (failure) {
    if (messenger != null) {
      // Short and one line, but still says why: offline or something else.
      showAppSnackBarOn(messenger, failure.isOffline ? l10n.errorOfflineShort : l10n.signOutFailed);
    }
  }
}
