import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trips/trip_widgets.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _todayProvider = FutureProvider.autoDispose.family<List<DriverCard>, String>(
  (Ref ref, String carpoolId) => ref.watch(tripRepositoryProvider).todayDriverCards(carpoolId),
);

/// F33 on the carpool screen (approved members): today's driver card for
/// each run with a confirmed driver; a card opens the live run. Also the
/// group's emergency alerts (F20). Shows nothing while loading or when
/// nobody drives today; a failure shows one quiet line.
class TodayDriversSection extends ConsumerWidget {
  const TodayDriversSection({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<DriverCard>> cards = ref.watch(_todayProvider(carpoolId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.tripTodaySection),
        if (cards.isLoading) const Skeleton(child: Padding(padding: EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter), child: SkeletonCard())),
        if (cards.hasError)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: AppInlineMessage(key: const Key('today.error'), message: TripFailure.from(cards.error!).message(l10n)),
          ),
        if (cards.hasValue && cards.value!.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Text(l10n.tripTodayNone, key: const Key('today.none'), style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          ),
        for (final DriverCard c in cards.value ?? const <DriverCard>[])
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s8),
            child: KeyedSubtree(
              key: Key('today.${c.runId}'),
              child: DriverCardView(
                firstName: c.driverFirstName,
                car: c.car,
                photoUrl: c.photoUrl,
                subtitle: c.direction == RunDirection.toSchool ? l10n.scheduleToSchool(c.time) : l10n.scheduleToHome(c.time),
                onTap: () => context.go('/carpools/$carpoolId/trip/${c.runId}'),
              ),
            ),
          ),
        AppListRow(
          key: const Key('detail.emergencies'),
          title: l10n.emergencyTitle,
          subtitle: l10n.emergencyRowHelper,
          leadingIcon: Icons.health_and_safety_outlined,
          onTap: () => context.go('/carpools/$carpoolId/emergency'),
        ),
      ],
    );
  }
}
