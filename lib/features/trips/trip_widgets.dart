import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Trip pieces (Prompt 10), in the gallery under "Trips". Driver pieces
/// follow the driver rule in DESIGN: large buttons, few words, no typing.

String stopStateLabel(AppLocalizations l10n, StopState s, RunDirection direction) => switch (s) {
  StopState.waiting => l10n.tripStopWaiting,
  StopState.arrived => l10n.tripStopArrived,
  StopState.onBoard => l10n.tripStopOnBoard,
  StopState.dropped => direction == RunDirection.toSchool ? l10n.tripStopAtSchool : l10n.tripStopDropped,
  StopState.received => l10n.tripStopReceived,
  StopState.absent => l10n.tripStopAbsent,
};

AppBadgeTone stopStateTone(StopState s) => switch (s) {
  StopState.waiting || StopState.absent => AppBadgeTone.neutral,
  StopState.arrived => AppBadgeTone.warning,
  StopState.onBoard || StopState.dropped || StopState.received => AppBadgeTone.success,
};

String stopActionLabel(AppLocalizations l10n, StopAction a, {required bool again, required RunDirection direction}) => switch (a) {
  StopAction.arrived => again ? l10n.tripActionArrivedAgain : l10n.tripActionArrived,
  StopAction.pickedUp => l10n.tripActionPickedUp,
  StopAction.dropped => direction == RunDirection.toSchool ? l10n.tripActionAtSchool : l10n.tripActionDropped,
};

IconData stopActionIcon(StopAction a) => switch (a) {
  StopAction.arrived => Icons.notifications_active_outlined,
  StopAction.pickedUp => Icons.login_rounded,
  StopAction.dropped => Icons.logout_rounded,
};

String quickLabel(AppLocalizations l10n, QuickKind k) => switch (k) {
  QuickKind.late => l10n.tripQuickLate,
  QuickKind.gate => l10n.tripQuickGate,
  QuickKind.allIn => l10n.tripQuickAllIn,
};

IconData quickIcon(QuickKind k) => switch (k) {
  QuickKind.late => Icons.schedule_rounded,
  QuickKind.gate => Icons.fence_outlined,
  QuickKind.allIn => Icons.groups_outlined,
};

String relationLabel(AppLocalizations l10n, Relation r) => switch (r) {
  Relation.mother => l10n.relationMother,
  Relation.father => l10n.relationFather,
  Relation.grandparent => l10n.relationGrandparent,
  Relation.sibling => l10n.relationSibling,
  Relation.relative => l10n.relationRelative,
  Relation.nanny => l10n.relationNanny,
  Relation.other => l10n.relationOther,
};

(String, AppBadgeTone, IconData) locationBadge(AppLocalizations l10n, LocationHealth h) => switch (h) {
  LocationHealth.waiting => (l10n.tripLocationWaiting, AppBadgeTone.warning, Icons.location_searching_rounded),
  LocationHealth.live => (l10n.tripLocationLive, AppBadgeTone.success, Icons.my_location_rounded),
  LocationHealth.stale => (l10n.tripLocationStale, AppBadgeTone.error, Icons.location_disabled_rounded),
  LocationHealth.off => (l10n.tripLocationOff, AppBadgeTone.neutral, Icons.location_off_outlined),
};

/// "Live", "Waiting", "Stopped" or "Off": color is never the only signal.
class TripLocationBadge extends StatelessWidget {
  const TripLocationBadge({required this.health, super.key});

  final LocationHealth health;

  @override
  Widget build(BuildContext context) {
    final (String label, AppBadgeTone tone, IconData icon) = locationBadge(context.l10n, health);
    return AppStatusBadge(key: const Key('trip.location'), label: label, tone: tone, icon: icon);
  }
}

/// F33: today's driver. Photo approved during verification (or initials),
/// first name, car model and color, and the plate (left to right).
class DriverCardView extends StatelessWidget {
  const DriverCardView({required this.firstName, this.car, this.photoUrl, this.subtitle, this.onTap, super.key});

  final String firstName;
  final TripCar? car;
  final String? photoUrl;

  /// For example "To school 07:30".
  final String? subtitle;

  /// Opens the live run (carpool screen).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final TripCar? c = car;
    final String initial = firstName.isEmpty ? '?' : firstName.characters.first;
    final String? url = photoUrl;
    final Widget fallback = ColoredBox(
      color: context.colors.secondaryContainer,
      child: Center(child: Text(initial, style: context.text.titleMedium)),
    );
    return AppCard(
      key: const Key('trip.driverCard'),
      onTap: onTap,
      semanticLabel: l10n.tripDriverCardLabel(firstName),
      child: Row(
        children: <Widget>[
          ClipOval(
            child: SizedBox.square(
              dimension: AppSpacing.s64,
              child: url == null
                  ? fallback
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      semanticLabel: l10n.tripDriverPhotoLabel,
                      errorBuilder: (BuildContext context, Object error, StackTrace? stack) => fallback,
                    ),
            ),
          ),
          const SizedBox(width: AppSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLineText(firstName, style: context.text.titleMedium),
                if (subtitle != null) OneLineText(subtitle!, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                if (c != null) ...<Widget>[
                  Text(l10n.tripCarLine(c.model, c.color), style: context.text.bodyMedium),
                  const SizedBox(height: AppSpacing.s4),
                  AppStatusBadge(key: const Key('trip.plate'), label: ltrIsolate(c.plate), icon: Icons.pin_outlined),
                ] else
                  Text(l10n.tripNoCarDetails, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One child on the driver screen: first name, state, the adults allowed
/// to receive the child (afternoon) and one or two large buttons. The
/// current stop is raised so the driver sees it at a glance.
class DriverStopCard extends StatelessWidget {
  const DriverStopCard({
    required this.stop,
    required this.direction,
    required this.onAction,
    this.current = false,
    this.busy,
    super.key,
  });

  final TripStop stop;
  final RunDirection direction;
  final ValueChanged<StopAction> onAction;
  final bool current;

  /// The action being sent for this stop, if any.
  final StopAction? busy;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<StopAction> actions = stopActions(stop, direction);
    final bool afternoon = direction == RunDirection.toHome;
    return AppCard(
      key: Key('drive.stop.${stop.childId}'),
      elevation: current ? AppElevation.medium : AppElevation.none,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: OneLineText(stop.firstName, style: context.text.headlineSmall)),
              const SizedBox(width: AppSpacing.s8),
              AppStatusBadge(label: stopStateLabel(l10n, stop.state, direction), tone: stopStateTone(stop.state)),
            ],
          ),
          if (afternoon && stop.state != StopState.absent) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            Text(
              stop.handover.isEmpty
                  ? l10n.tripHandoverParentsOnly
                  : l10n.tripHandoverList(<String>[for (final HandoverAdult a in stop.handover) '${a.name} (${relationLabel(l10n, a.relation)})'].join(l10n.tripListSeparator)),
              key: Key('drive.handover.${stop.childId}'),
              style: context.text.bodyLarge,
            ),
          ],
          for (int i = 0; i < actions.length; i++) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              key: Key('drive.${actions[i].name}.${stop.childId}'),
              label: stopActionLabel(l10n, actions[i], again: actions[i] == StopAction.arrived && stop.arrivedCount > 0, direction: direction),
              icon: stopActionIcon(actions[i]),
              size: AppButtonSize.large,
              variant: i == actions.length - 1 && current ? AppButtonVariant.primary : AppButtonVariant.secondary,
              expand: true,
              loading: busy == actions[i],
              onPressed: busy != null ? null : () => onAction(actions[i]),
            ),
          ],
        ],
      ),
    );
  }
}
