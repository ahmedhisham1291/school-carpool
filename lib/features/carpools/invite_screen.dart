import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// An invite link `/c/<code>` (F31; shown at `/carpools/invite/<code>`), opened by a universal link or from
/// the Carpools tab. The parent must be verified before anything is shown:
/// until then the code waits on the phone and this screen says to verify
/// first. A verified parent goes on to the carpool, where joining still
/// needs the admin's approval.
///
/// States: opening (progress), not verified (empty with Verify), invalid
/// or expired (empty with Carpools), error and offline (retry).
class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({required this.code, super.key});

  final String code;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  CarpoolFailure? _failure;
  bool _started = false;

  Future<void> _open() async {
    setState(() {
      _started = true;
      _failure = null;
    });
    final PendingInvite pending = ref.read(pendingInviteProvider.notifier);
    try {
      final String carpoolId = await ref.read(carpoolRepositoryProvider).openInvite(widget.code);
      await pending.save(null);
      if (mounted) {
        context.go(CarpoolRoutes.detail(carpoolId));
      }
    } on CarpoolFailure catch (failure) {
      if (failure.kind == CarpoolFailureKind.inviteInvalid) {
        await pending.save(null);
      }
      if (mounted) {
        setState(() => _failure = failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Account? account = accountOf(ref.watch(sessionProvider));
    final bool verified = account?.status == AccountStatus.verified;
    if (verified && !_started) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && !_started) {
          unawaited(_open());
        }
      });
    }
    if (!verified && ref.read(pendingInviteProvider) != widget.code) {
      // Kept until the parent is verified (shown on the Carpools tab).
      WidgetsBinding.instance.addPostFrameCallback((Duration _) => unawaited(ref.read(pendingInviteProvider.notifier).save(widget.code)));
    }

    final CarpoolFailure? failure = _failure;
    final Widget body = !verified
        ? EmptyStateView(
            key: const Key('invite.verifyFirst'),
            icon: Icons.verified_user_outlined,
            title: l10n.inviteVerifyTitle,
            body: l10n.inviteVerifyBody,
            actionLabel: l10n.inviteVerifyAction,
            onAction: () => context.go(AuthRoutes.verifyAccount),
          )
        : failure == null
        ? const Center(child: CircularProgressIndicator(key: Key('invite.opening')))
        : failure.isOffline
        ? OfflineStateView(onRetry: () => unawaited(_open()))
        : failure.kind == CarpoolFailureKind.inviteInvalid
        ? EmptyStateView(
            key: const Key('invite.invalid'),
            icon: Icons.link_off_rounded,
            title: l10n.inviteInvalidTitle,
            body: l10n.carpoolErrorInviteInvalid,
            actionLabel: l10n.tabCarpools,
            onAction: () => context.go(AppTab.carpools.path),
          )
        : ErrorStateView(body: failure.message(l10n), onRetry: () => unawaited(_open()));
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.inviteTitle)),
      body: SafeArea(child: body),
    );
  }
}
