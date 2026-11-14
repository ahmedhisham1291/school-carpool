import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/schedule/schedule_labels.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trips/trip_widgets.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// The run of one carpool (carpoolId, runId).
final _runProvider = StreamProvider.autoDispose.family<ScheduleRun?, (String, String)>(
  (Ref ref, (String, String) key) => ref.watch(tripRepositoryProvider).watchRun(key.$1, key.$2),
);

/// The trip of one run (carpoolId, runId); null before the start.
final _tripProvider = StreamProvider.autoDispose.family<Trip?, (String, String)>(
  (Ref ref, (String, String) key) => ref.watch(tripRepositoryProvider).watchTrip(key.$1, key.$2),
);

enum _Phase { loading, permission, selfie, ready, running, done, paused, offline, failed }

/// A tap that could not be sent (no connection): sent again with the same
/// request ID, so the server applies it once (spec section 11).
class _Pending {
  const _Pending({required this.requestId, this.childId, this.action, this.quick});

  final String requestId;
  final String? childId;
  final StopAction? action;
  final QuickKind? quick;
}

/// The driver's run (F15, F16, F20, F35, F38, F41). Driver rule (DESIGN):
/// large buttons, few words, no typing.
///
/// Before the run, in order: an explanation of live location and the
/// "Always" permission (the run cannot start without it), a quick live
/// selfie when the server asks for one (F38), then Start run. During the
/// run: one card per child with large buttons (Arrived, Picked up,
/// Dropped), the three quick buttons and the emergency button. Tracking
/// stops by itself at the last drop-off.
///
/// States: loading (skeleton), offline and error (retry), paused driving
/// (after a failed selfie check), taps waiting for a connection (sent again
/// with the same request ID), done.
class DriverTripScreen extends ConsumerStatefulWidget {
  const DriverTripScreen({required this.carpoolId, required this.runId, super.key});

  final String carpoolId;
  final String runId;

  @override
  ConsumerState<DriverTripScreen> createState() => _DriverTripScreenState();
}

class _DriverTripScreenState extends ConsumerState<DriverTripScreen> {
  _Phase _phase = _Phase.loading;
  TrackerPermission _permission = TrackerPermission.notAsked;
  bool _asked = false;
  bool _busy = false;
  String? _error;
  final Map<String, StopAction> _sending = <String, StopAction>{};
  final List<_Pending> _queue = <_Pending>[];
  QuickKind? _quickBusy;
  Timer? _retry;
  bool _stopped = false;

  (String, String) get _key => (widget.carpoolId, widget.runId);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // Tracking goes on when the driver leaves this screen (phone locked,
    // another app); it stops at the last drop-off.
    _retry?.cancel();
    super.dispose();
  }

  void _set(_Phase phase, {String? error}) {
    if (mounted) {
      setState(() {
        _phase = phase;
        _error = error;
      });
    }
  }

  Future<void> _load() async {
    _set(_Phase.loading);
    final LocationTracker tracker = ref.read(locationTrackerProvider);
    final TripRepository repo = ref.read(tripRepositoryProvider);
    try {
      _permission = await tracker.permission();
      final TripPreparation prep = await repo.prepare(widget.carpoolId, widget.runId);
      if (prep.active && _permission == TrackerPermission.always) {
        // The app was restarted during the run: resume with a new token.
        await _begin(resume: true);
        return;
      }
      if (_permission != TrackerPermission.always) {
        _set(_Phase.permission);
      } else if (prep.selfieRequired) {
        _set(_Phase.selfie);
      } else {
        _set(_Phase.ready);
      }
    } on TripFailure catch (failure) {
      if (!mounted) {
        return;
      }
      if (failure.kind == TripFailureKind.drivingPaused) {
        _set(_Phase.paused);
      } else if (failure.isOffline) {
        _set(_Phase.offline);
      } else {
        _set(_Phase.failed, error: failure.message(context.l10n));
      }
    }
  }

  Future<void> _askPermission() async {
    final LocationTracker tracker = ref.read(locationTrackerProvider);
    if (_asked && _permission != TrackerPermission.notAsked) {
      await tracker.openSettings();
    }
    final TrackerPermission p = await tracker.requestAlways();
    _asked = true;
    _permission = p;
    if (p == TrackerPermission.always) {
      await _load();
    } else {
      _set(_Phase.permission);
    }
  }

  Future<void> _selfie() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final CaptureResult? shot = await ref.read(captureLauncherProvider)(context, const CaptureRequest(CaptureKind.selfie));
    if (shot == null || !mounted) {
      return;
    }
    final SessionState session = ref.read(sessionProvider);
    if (session is! SessionSignedIn) {
      return;
    }
    setState(() => _busy = true);
    try {
      final SelfieResult result = await ref
          .read(tripRepositoryProvider)
          .submitSelfie(uid: session.uid, carpoolId: widget.carpoolId, runId: widget.runId, jpeg: shot.image);
      switch (result) {
        case SelfieResult.passed || SelfieResult.error:
          showAppSnackBarOn(messenger, l10n.tripSelfieDone);
          _set(_Phase.ready);
        case SelfieResult.failed:
          _set(_Phase.paused);
      }
    } on TripFailure catch (failure) {
      _set(_Phase.selfie, error: failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _begin({bool resume = false}) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final TripRepository repo = ref.read(tripRepositoryProvider);
    final LocationTracker tracker = ref.read(locationTrackerProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final TripSession session = await repo.start(widget.carpoolId, widget.runId);
      try {
        await tracker.start(TrackerSession(tripId: session.tripId, uploadUrl: repo.uploadUrl(session.tripId), token: session.token));
      } on StateError {
        _set(_Phase.permission, error: l10n.tripErrorLocationOff);
        return;
      }
      _stopped = false;
      if (!resume) {
        showAppSnackBarOn(messenger, l10n.tripStarted);
      }
      _set(_Phase.running);
    } on TripFailure catch (failure) {
      if (failure.kind == TripFailureKind.selfieRequired) {
        _set(_Phase.selfie);
      } else if (failure.kind == TripFailureKind.drivingPaused) {
        _set(_Phase.paused);
      } else {
        _set(resume ? _Phase.failed : _Phase.ready, error: failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// The last drop-off: the server stopped tracking; stop the phone too.
  void _onTrip(Trip? trip) {
    if (trip == null || trip.tracking || _stopped || _phase != _Phase.running) {
      return;
    }
    _stopped = true;
    unawaited(ref.read(locationTrackerProvider).stop());
    _set(_Phase.done);
  }

  Future<void> _send(_Pending p) async {
    final TripRepository repo = ref.read(tripRepositoryProvider);
    final StopAction? action = p.action;
    final String? childId = p.childId;
    final QuickKind? quick = p.quick;
    if (action != null && childId != null) {
      await repo.act(carpoolId: widget.carpoolId, runId: widget.runId, childId: childId, action: action, requestId: p.requestId);
    } else if (quick != null) {
      await repo.quick(carpoolId: widget.carpoolId, runId: widget.runId, kind: quick, requestId: p.requestId);
    }
  }

  Future<void> _tap(_Pending p, String done) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? childId = p.childId;
    final StopAction? action = p.action;
    setState(() {
      if (childId != null && action != null) {
        _sending[childId] = action;
      }
      _quickBusy = p.quick;
      _error = null;
    });
    try {
      await _send(p);
      showAppSnackBarOn(messenger, done);
    } on TripFailure catch (failure) {
      if (failure.isOffline) {
        _queue.add(p);
        _retry ??= Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_flush()));
        showAppSnackBarOn(messenger, l10n.tripQueued);
      } else if (mounted) {
        setState(() => _error = failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending.remove(childId);
          _quickBusy = null;
        });
      }
    }
  }

  Future<void> _flush() async {
    while (_queue.isNotEmpty) {
      try {
        await _send(_queue.first);
      } on TripFailure catch (failure) {
        if (failure.isOffline) {
          return;
        }
      }
      if (!mounted) {
        return;
      }
      setState(() => _queue.removeAt(0));
    }
    _retry?.cancel();
    _retry = null;
  }

  Future<void> _emergency() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.tripEmergencyTitle,
      body: l10n.tripEmergencyBody,
      confirmLabel: l10n.tripEmergencySend,
      destructive: true,
    );
    if (!sure || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final bool contact = await ref.read(tripRepositoryProvider).emergency(carpoolId: widget.carpoolId, runId: widget.runId);
      showAppSnackBarOn(messenger, contact ? l10n.tripEmergencySentAll : l10n.tripEmergencySentGroup);
    } on TripFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    ref.listen<AsyncValue<Trip?>>(_tripProvider(_key), (AsyncValue<Trip?>? previous, AsyncValue<Trip?> next) => _onTrip(next.value));
    final ScheduleRun? run = ref.watch(_runProvider(_key)).value;
    final Widget body = switch (_phase) {
      _Phase.loading => const _DriveSkeleton(),
      _Phase.offline => OfflineStateView(onRetry: () => unawaited(_load())),
      _Phase.failed => ErrorStateView(body: _error, onRetry: () => unawaited(_load())),
      _Phase.paused => EmptyStateView(
        key: const Key('drive.paused'),
        icon: Icons.pause_circle_outline_rounded,
        title: l10n.tripPausedTitle,
        body: l10n.tripErrorPaused,
      ),
      _Phase.permission => _Step(
        key: const Key('drive.permission'),
        icon: Icons.my_location_rounded,
        heading: l10n.tripLocationHeading,
        body: switch (_permission) {
          TrackerPermission.serviceOff => l10n.tripLocationServiceOff,
          TrackerPermission.whileInUse || TrackerPermission.denied when _asked => l10n.tripLocationChooseAlways,
          _ => l10n.tripLocationBody,
        },
        error: _error,
        actionKey: const Key('drive.allowLocation'),
        actionLabel: _asked && _permission != TrackerPermission.always ? l10n.locationOpenSettings : l10n.tripLocationTurnOn,
        busy: _busy,
        onAction: () => unawaited(_askPermission()),
      ),
      _Phase.selfie => _Step(
        key: const Key('drive.selfie'),
        icon: Icons.face_retouching_natural_outlined,
        heading: l10n.tripSelfieHeading,
        body: l10n.tripSelfieBody,
        error: _error,
        actionKey: const Key('drive.takeSelfie'),
        actionLabel: l10n.tripSelfieTake,
        busy: _busy,
        onAction: () => unawaited(_selfie()),
      ),
      _Phase.ready => _Step(
        key: const Key('drive.ready'),
        icon: Icons.directions_car_outlined,
        heading: run == null ? l10n.tripReadyHeading : runTitle(l10n, run),
        body: run == null ? l10n.tripReadyBody : l10n.tripReadyChildren(run.riders.length),
        error: _error,
        actionKey: const Key('drive.start'),
        actionLabel: l10n.tripStart,
        busy: _busy,
        onAction: () => unawaited(_begin()),
      ),
      _Phase.running => _running(context),
      _Phase.done => EmptyStateView(
        key: const Key('drive.done'),
        icon: Icons.check_circle_outline_rounded,
        title: l10n.tripDoneTitle,
        body: l10n.tripDoneBody,
        actionLabel: l10n.tripDoneAction,
        onAction: () => context.canPop() ? context.pop() : context.go('/carpools/${widget.carpoolId}/schedule'),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.tripDriveTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _running(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<Trip?> async = ref.watch(_tripProvider(_key));
    final Trip? trip = async.value;
    if (trip == null) {
      return async.hasError ? OfflineStateView(onRetry: () => ref.invalidate(_tripProvider(_key))) : const _DriveSkeleton();
    }
    final DateTime now = ref.watch(tripClockProvider)();
    final List<TripStop> riding = trip.riding;
    final int current = currentStopIndex(trip);
    final int done = riding.where((TripStop s) => stopActions(s, trip.direction).isEmpty).length;
    return ListView(
      key: const Key('drive.list'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Row(
          children: <Widget>[
            TripLocationBadge(health: locationHealth(trip, now)),
            const SizedBox(width: AppSpacing.s8),
            Expanded(child: OneLineText(l10n.tripProgress(done, riding.length), style: context.text.titleSmall)),
          ],
        ),
        if (_queue.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(
            key: const Key('drive.queue'),
            message: l10n.tripQueuedCount(_queue.length),
            tone: AppStateTone.warning,
            icon: Icons.cloud_upload_outlined,
          ),
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('drive.error'), message: _error!, tone: AppStateTone.error),
        ],
        for (int i = 0; i < riding.length; i++) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          DriverStopCard(
            stop: riding[i],
            direction: trip.direction,
            current: i == current,
            busy: _sending[riding[i].childId],
            onAction: (StopAction a) => unawaited(
              _tap(
                _Pending(requestId: newRequestId(), childId: riding[i].childId, action: a),
                switch (a) {
                  StopAction.arrived => l10n.tripArrivedSent,
                  StopAction.pickedUp => l10n.tripPickedUpSent,
                  StopAction.dropped => l10n.tripDroppedSent,
                },
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s32),
        Semantics(header: true, child: OneLineText(l10n.tripQuickSection, style: context.text.titleSmall)),
        for (final QuickKind k in QuickKind.values) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: Key('drive.quick.${k.name}'),
            label: quickLabel(l10n, k),
            icon: quickIcon(k),
            size: AppButtonSize.large,
            variant: AppButtonVariant.secondary,
            expand: true,
            loading: _quickBusy == k,
            onPressed: _quickBusy != null ? null : () => unawaited(_tap(_Pending(requestId: newRequestId(), quick: k), l10n.tripQuickSent)),
          ),
        ],
        const SizedBox(height: AppSpacing.s32),
        AppButton(
          key: const Key('drive.emergency'),
          label: l10n.tripEmergency,
          icon: Icons.sos_rounded,
          size: AppButtonSize.large,
          variant: AppButtonVariant.danger,
          expand: true,
          loading: _busy,
          onPressed: _busy ? null : () => unawaited(_emergency()),
        ),
        const SizedBox(height: AppSpacing.s16),
      ],
    );
  }
}

/// One step before the run: icon, heading, one or two sentences and the
/// one large button.
class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.heading,
    required this.body,
    required this.actionKey,
    required this.actionLabel,
    required this.busy,
    required this.onAction,
    this.error,
    super.key,
  });

  final IconData icon;
  final String heading;
  final String body;
  final Key actionKey;
  final String actionLabel;
  final bool busy;
  final VoidCallback onAction;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: AppSpacing.s32),
                Icon(icon, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
                const SizedBox(height: AppSpacing.s24),
                Semantics(header: true, child: Text(heading, style: context.text.headlineSmall)),
                const SizedBox(height: AppSpacing.s8),
                Text(body, style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant)),
                if (error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.s16),
                  AppInlineMessage(key: const Key('drive.stepError'), message: error!, tone: AppStateTone.error),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: AppButton(key: actionKey, label: actionLabel, size: AppButtonSize.large, expand: true, loading: busy, onPressed: busy ? null : onAction),
        ),
      ],
    );
  }
}

class _DriveSkeleton extends StatelessWidget {
  const _DriveSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s24, width: AppSpacing.s64 * 2),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
        ],
      ),
    ),
  );
}
