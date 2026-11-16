import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Owner decision 16 Nov 2026 (App Review: no dead ends before the ID
/// check): a parent who is not verified yet may look around. This card on
/// Home, Carpools and Chats says what opens after the check and leads to
/// the verification screen (which explains why: child safety, and has
/// "Later").
///
/// Hidden for verified and suspended accounts and while the account loads.
/// Nothing loads here, so there is no loading, error or offline state.
class VerifyPromptCard extends ConsumerWidget {
  const VerifyPromptCard({this.from, super.key});

  /// The tab the card sits on, so "Later" on the verification screen
  /// comes back here.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AccountStatus? status = accountOf(ref.watch(sessionProvider))?.status;
    final bool show =
        status == AccountStatus.unverified || status == AccountStatus.pending || status == AccountStatus.rejected;
    if (!show) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    final bool pending = status == AccountStatus.pending;
    final String? back = from;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s16, AppSpacing.s16, 0),
      child: AppCard(
        key: const Key('verifyPrompt.card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(Icons.verified_user_outlined, color: context.colors.primary, size: AppIconSize.md),
                ),
                const SizedBox(width: AppSpacing.s16),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: OneLineText(
                      pending ? l10n.verifyCardPendingTitle : l10n.verifyCardTitle,
                      style: context.text.titleMedium,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s8),
            Text(
              pending ? l10n.verifyCardPendingBody : l10n.verifyCardBody,
              style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              key: const Key('verifyPrompt.open'),
              label: pending ? l10n.verifyCardPendingAction : l10n.verifyCardAction,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () =>
                  context.go(back == null ? AuthRoutes.verifyAccount : AuthRoutes.verifyFor(back)),
            ),
          ],
        ),
      ),
    );
  }
}
