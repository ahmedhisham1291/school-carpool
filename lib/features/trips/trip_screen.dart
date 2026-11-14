import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/schedule/schedule_labels.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trips/trip_widgets.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

final _tripProvider = StreamProvider.autoDispose.family<Trip?, (String, String)>(
  (Ref ref, (String, String) key) => ref.watch(tripRepositoryProvider).watchTrip(key.$1, key.$2),
);

final _etaProvider = StreamProvider.autoDispose.family<TripEta?, (String, String)>(
  (Ref ref, (String, String) key) => ref.watch(tripRepositoryProvider).watchEta(key.$1, key.$2),
);

/// Today's driver cards of a carpool (photo links last 15 minutes).
final _cardsProvider = FutureProvider.autoDispose.family<List<DriverCard>, String>(
  (Ref ref, String carpoolId) => ref.watch(tripRepositoryProvider).todayDriverCards(carpoolId),
);

/// The live run for parents (F15, F16, F33, F34): the car on the map while
/// the run is tracked, the arrival time at their stop (Routes, updated about
/// once a minute), today's driver card, every child's state, the driver's
/// quick messages and, in the afternoon, "Child is home" to confirm the
/// handover. Only the driver and the parents of the children on this run
/// can read it (firestore.rules); anyone else sees "Not started".
///
/// States: loading (skeleton), not started or not yours (empty), error and
/// offline (retry), location stopped (warning), run finished (map hidden).
class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({required this.carpoolId, required this.runId, super.key});

  final String carpoolId;
  final String runId;

  static String path(String carpoolId, String runId) => '/carpools/$carpoolId/trip/$runId';

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  final MapCameraController _camera = MapCameraController(center: Geo.cairo, zoom: AppMapTokens.streetZoom);
  String? _confirming;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  Future<void> _confirm(TripStop stop) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.tripConfirmHomeTitle(stop.firstName),
      body: l10n.tripConfirmHomeBody,
      confirmLabel: l10n.tripConfirmHome,
    );
    if (!sure || !mounted) {
      return;
    }
    setState(() => _confirming = stop.childId);
    try {
      await ref.read(tripRepositoryProvider).confirmHandover(carpoolId: widget.carpoolId, runId: widget.runId, childId: stop.childId);
      showAppSnackBarOn(messenger, l10n.tripConfirmedHome);
    } on TripFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _confirming = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String, String) key = (widget.carpoolId, widget.runId);
    ref.listen<AsyncValue<Trip?>>(_tripProvider(key), (AsyncValue<Trip?>? previous, AsyncValue<Trip?> next) {
      final GeoPin? p = next.value?.last;
      if (p != null && p != previous?.value?.last) {
        _camera.moveTo(p);
      }
    });
    final AsyncValue<Trip?> trip = ref.watch(_tripProvider(key));
    final Widget body;
    if (trip.hasError) {
      final Object error = trip.error!;
      body = TripFailure.from(error).isOffline
          ? OfflineStateView(onRetry: () => ref.invalidate(_tripProvider(key)))
          : ErrorStateView(onRetry: () => ref.invalidate(_tripProvider(key)));
    } else if (!trip.hasValue) {
      body = const _TripSkeleton();
    } else if (trip.value == null) {
      body = EmptyStateView(
        key: const Key('trip.notStarted'),
        icon: Icons.directions_car_outlined,
        title: l10n.tripNotStartedTitle,
        body: l10n.tripNotStartedBody,
      );
    } else {
      body = _content(context, trip.value!);
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.tripTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, Trip trip) {
    final AppLocalizations l10n = context.l10n;
    final SessionState session = ref.watch(sessionProvider);
    final String uid = session is SessionSignedIn ? session.uid : '';
    final DateTime now = ref.watch(tripClockProvider)();
    final LocationHealth health = locationHealth(trip, now);
    final TripEta? eta = ref.watch(_etaProvider((trip.id, uid))).value;
    final List<DriverCard> cards = ref.watch(_cardsProvider(widget.carpoolId)).value ?? const <DriverCard>[];
    final DriverCard? card = cards.where((DriverCard c) => c.runId == trip.runId).firstOrNull;
    final List<TripStop> mine = myStops(trip, uid);
    final GeoPin? car = trip.last;
    final TripStop? toConfirm = mine.where((TripStop s) => canConfirmHandover(trip, s, uid)).firstOrNull;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);

    return ListView(
      key: const Key('trip.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        if (trip.tracking && car != null)
          SizedBox(
            height: AppSpacing.s64 * 4,
            child: AppMapView(
              config: MapViewConfig(
                camera: _camera,
                semanticLabel: l10n.tripMapLabel,
                markers: <MapMarker>[MapMarker(id: 'car', at: car, kind: MapMarkerKind.car, label: l10n.tripCarPinLabel(trip.driverFirstName))],
              ),
            ),
          ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  TripLocationBadge(health: health),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: OneLineText(trip.direction == RunDirection.toSchool ? l10n.scheduleDirToSchool : l10n.scheduleDirToHome, style: context.text.titleSmall),
                  ),
                ],
              ),
              if (health == LocationHealth.stale) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(key: const Key('trip.stale'), message: l10n.tripStaleNote, tone: AppStateTone.warning, icon: Icons.location_disabled_rounded),
              ],
              if (!trip.tracking) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(key: const Key('trip.finished'), message: l10n.tripFinishedNote, icon: Icons.location_off_outlined),
              ],
              // Prompt 11 (F17): after a finished trip, rate the driver or the parents.
              if (trip.status == TripStatus.ended) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppButton(
                  key: const Key('trip.rate'),
                  label: l10n.tripRateAction,
                  icon: Icons.star_outline_rounded,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: () => context.go(ProfileRoutes.ratings),
                ),
              ],
              for (final TripStop s in mine) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                _EtaLine(stop: s, eta: eta?.stops[s.childId], now: now, tracking: trip.tracking, direction: trip.direction),
              ],
              const SizedBox(height: AppSpacing.s24),
              DriverCardView(
                firstName: trip.driverFirstName,
                car: trip.car,
                photoUrl: card?.photoUrl,
                subtitle: card == null ? null : (card.direction == RunDirection.toSchool ? l10n.scheduleToSchool(card.time) : l10n.scheduleToHome(card.time)),
              ),
              if (trip.driverUid == uid) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppButton(
                  key: const Key('trip.openDriver'),
                  label: l10n.tripOpenDriver,
                  icon: Icons.directions_car_outlined,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: () => context.go('${TripScreen.path(widget.carpoolId, widget.runId)}/drive'),
                ),
              ],
              if (toConfirm != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppButton(
                  key: Key('trip.confirmHome.${toConfirm.childId}'),
                  label: l10n.tripConfirmHome,
                  icon: Icons.home_rounded,
                  expand: true,
                  loading: _confirming == toConfirm.childId,
                  onPressed: _confirming != null ? null : () => unawaited(_confirm(toConfirm)),
                ),
              ],
            ],
          ),
        ),
        AppSectionHeader(l10n.tripChildrenSection),
        for (final TripStop s in trip.riding)
          AppListRow(
            key: Key('trip.child.${s.childId}'),
            title: s.firstName,
            leadingIcon: Icons.child_care_outlined,
            showChevron: false,
            trailing: AppStatusBadge(label: stopStateLabel(l10n, s.state, trip.direction), tone: stopStateTone(s.state)),
          ),
        if (trip.messages.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.tripMessagesSection),
          for (final (QuickKind k, DateTime at) in trip.messages.reversed.take(5))
            AppListRow(
              title: quickLabel(l10n, k),
              subtitle: deadlineText(context, at),
              leadingIcon: quickIcon(k),
              showChevron: false,
            ),
        ],
        if (trip.messages.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s16),
            child: Text(l10n.tripNoMessages, style: quiet),
          ),
      ],
    );
  }
}

/// "Adam · Arriving in 6 min" for one of the parent's children.
class _EtaLine extends StatelessWidget {
  const _EtaLine({required this.stop, required this.eta, required this.now, required this.tracking, required this.direction});

  final TripStop stop;
  final DateTime? eta;
  final DateTime now;
  final bool tracking;
  final RunDirection direction;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final int? minutes = tracking ? minutesUntil(eta, now) : null;
    final bool waiting = stop.state == StopState.waiting || stop.state == StopState.arrived;
    final String text = switch (stop.state) {
      StopState.arrived when direction == RunDirection.toSchool => l10n.tripEtaOutside,
      _ when minutes == null => stopStateLabel(l10n, stop.state, direction),
      _ when minutes == 0 => l10n.tripEtaNow,
      _ => waiting && direction == RunDirection.toSchool ? l10n.tripEtaPickup(minutes) : l10n.tripEtaArrive(minutes),
    };
    return AppCard(
      key: Key('trip.eta.${stop.childId}'),
      child: Row(
        children: <Widget>[
          Icon(Icons.schedule_rounded, color: context.colors.onSurfaceVariant),
          const SizedBox(width: AppSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLineText(stop.firstName, style: context.text.titleSmall),
                Text(text, style: context.text.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TripSkeleton extends StatelessWidget {
  const _TripSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s64 * 3),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
          SizedBox(height: AppSpacing.s16),
          SkeletonListRow(),
          SkeletonListRow(),
        ],
      ),
    ),
  );
}
