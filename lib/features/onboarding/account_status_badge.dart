import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// [AppStatusBadge] for a verification status (spec section 3).
class AccountStatusBadge extends StatelessWidget {
  const AccountStatusBadge({required this.status, super.key});

  final AccountStatus status;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String label, AppBadgeTone tone, IconData icon) = switch (status) {
      AccountStatus.unverified => (l10n.statusUnverified, AppBadgeTone.neutral, Icons.shield_outlined),
      AccountStatus.pending => (l10n.statusPending, AppBadgeTone.warning, Icons.hourglass_top_rounded),
      AccountStatus.verified => (l10n.statusVerified, AppBadgeTone.success, Icons.verified_rounded),
      AccountStatus.rejected => (l10n.statusRejected, AppBadgeTone.error, Icons.error_outline_rounded),
      AccountStatus.suspended => (l10n.statusSuspended, AppBadgeTone.error, Icons.block_rounded),
    };
    return AppStatusBadge(label: label, tone: tone, icon: icon);
  }
}
