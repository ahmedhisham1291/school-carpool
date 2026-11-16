import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/onboarding/verify_prompt_card.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Carpools tab (spec section 10): my carpools (approved and requested),
/// then Find, Start and "Looking for one". An invite that arrived before
/// verification waits here with an "Open invite" card. Before the ID check
/// the tab is open (an empty list) with a card that explains the check.
///
/// States: loading (skeleton cards), empty (no carpools: "Find a carpool"),
/// error and offline (retry).
class CarpoolsScreen extends ConsumerWidget {
  const CarpoolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<Membership>> memberships = ref.watch(myMembershipsProvider);
    final String? pendingInvite = ref.watch(pendingInviteProvider);

    final Widget more = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.carpoolsMoreSection),
        AppListRow(
          key: const Key('carpools.find'),
          title: l10n.carpoolFind,
          subtitle: l10n.carpoolFindHelper,
          leadingIcon: Icons.search_rounded,
          onTap: () => context.go(CarpoolRoutes.search),
        ),
        AppListRow(
          key: const Key('carpools.create'),
          title: l10n.carpoolCreate,
          subtitle: l10n.carpoolCreateHelper,
          leadingIcon: Icons.add_road_rounded,
          onTap: () => context.go(CarpoolRoutes.create),
        ),
        AppListRow(
          key: const Key('carpools.looking'),
          title: l10n.lookingTitle,
          subtitle: l10n.lookingHelper,
          leadingIcon: Icons.campaign_outlined,
          onTap: () => context.go(CarpoolRoutes.looking),
        ),
      ],
    );

    final Widget body = switch (memberships) {
      AsyncError<List<Membership>>(:final Object error) => carpoolErrorView(error, () => ref.invalidate(myMembershipsProvider)),
      AsyncData<List<Membership>>(:final List<Membership> value) => ListView(
        key: const Key('carpools.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          // Owner decision 16 Nov 2026: Find, Start and Looking open the
          // verification screen (with Later) until the parent is verified.
          VerifyPromptCard(from: AppTab.carpools.path),
          if (pendingInvite != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: AppCard(
                key: const Key('carpools.pendingInvite'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    OneLineText(l10n.inviteWaitingTitle, style: context.text.titleSmall),
                    Text(l10n.inviteWaitingBody, style: context.text.bodyMedium),
                    const SizedBox(height: AppSpacing.s16),
                    AppButton(
                      key: const Key('carpools.openInvite'),
                      label: l10n.inviteOpen,
                      variant: AppButtonVariant.secondary,
                      expand: true,
                      onPressed: () => context.go(CarpoolRoutes.invite(pendingInvite)),
                    ),
                  ],
                ),
              ),
            ),
          ..._mine(context, value.where((Membership m) => m.isActive).toList()),
          more,
        ],
      ),
      _ => const CarpoolListSkeleton(),
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.tabCarpools)),
      body: SafeArea(top: false, child: body),
    );
  }

  List<Widget> _mine(BuildContext context, List<Membership> active) {
    final AppLocalizations l10n = context.l10n;
    if (active.isEmpty) {
      return <Widget>[
        EmptyStateView(
          key: const Key('carpools.empty'),
          icon: Icons.directions_car_outlined,
          title: l10n.carpoolsEmptyTitle,
          body: l10n.carpoolsEmptyBody,
          actionLabel: l10n.carpoolFind,
          onAction: () => context.go(CarpoolRoutes.search),
        ),
      ];
    }
    return <Widget>[
      AppSectionHeader(l10n.carpoolsMineSection),
      for (final Membership m in active)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s16),
          child: _MyCarpool(membership: m),
        ),
    ];
  }
}

final _carpoolProvider = StreamProvider.autoDispose.family<Carpool?, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchCarpool(id),
);

/// One of my carpools: the card, from the carpool's public summary.
class _MyCarpool extends ConsumerWidget {
  const _MyCarpool({required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<Carpool?> carpool = ref.watch(_carpoolProvider(membership.carpoolId));
    final Carpool? c = carpool.value;
    if (c == null) {
      return carpool.isLoading ? const Skeleton(child: SkeletonCard()) : const SizedBox.shrink();
    }
    final Widget? badge = switch (membership) {
      Membership(status: MembershipStatus.requested) => AppStatusBadge(label: l10n.carpoolRequested, tone: AppBadgeTone.warning),
      Membership(isAdmin: true) => AppStatusBadge(label: l10n.carpoolAdmin),
      _ => null,
    };
    return CarpoolCard(
      key: Key('carpools.mine.${c.id}'),
      carpool: c,
      badge: badge,
      onTap: () => context.go(CarpoolRoutes.detail(c.id)),
    );
  }
}
