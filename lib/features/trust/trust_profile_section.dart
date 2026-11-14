import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Profile's "School year" card (Prompt 11): shown while the yearly check
/// is open for this parent, as a warning once the deadline passed. Nothing
/// while loading or on an error (the rows below still work).
class YearCheckBanner extends ConsumerWidget {
  const YearCheckBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final YearCheck? check = ref.watch(trustOverviewProvider).value?.yearCheck;
    if (check == null || !check.open) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    final bool overdue = check.state == YearCheckState.overdue;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
      child: AppCard(
        key: const Key('profile.yearCheck'),
        onTap: () => context.go(ProfileRoutes.schoolYear),
        child: Row(
          children: <Widget>[
            ExcludeSemantics(
              child: Icon(
                overdue ? Icons.warning_amber_rounded : Icons.event_note_outlined,
                size: AppIconSize.md,
                color: overdue ? context.appColors.warning : context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.s16),
            Expanded(child: Text(overdue ? l10n.yearBannerOverdue : l10n.yearBanner, style: context.text.bodyMedium)),
            const SizedBox(width: AppSpacing.s8),
            Icon(Icons.chevron_right_rounded, color: context.colors.onSurfaceVariant, size: AppIconSize.sm),
          ],
        ),
      ),
    );
  }
}

/// Profile rows: rate parents (with how many are waiting) and family links
/// (with requests to answer). Verified parents only.
class TrustProfileRows extends ConsumerWidget {
  const TrustProfileRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final TrustOverview? o = ref.watch(trustOverviewProvider).value;
    final String ratingsSubtitle;
    if (o == null) {
      ratingsSubtitle = l10n.profileRatingsHelper;
    } else if (o.toRate > 0) {
      ratingsSubtitle = l10n.profileToRate(o.toRate);
    } else {
      ratingsSubtitle = summaryLine(l10n, o.summary);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppListRow(
          key: const Key('profile.ratings'),
          title: l10n.rateTitle,
          subtitle: ratingsSubtitle,
          leadingIcon: Icons.star_outline_rounded,
          onTap: () => context.go(ProfileRoutes.ratings),
        ),
        AppListRow(
          key: const Key('profile.family'),
          title: l10n.familyTitle,
          subtitle: o != null && o.requests > 0 ? l10n.profileLinkRequests(o.requests) : l10n.profileFamilyHelper,
          leadingIcon: Icons.link_rounded,
          onTap: () => context.go(ProfileRoutes.family),
        ),
      ],
    );
  }
}
