import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/schedule/schedule_labels.dart';
import 'package:school_carpool/features/schedule/schedule_logic.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// The runs of one week of one carpool: (carpoolId, week start key).
final _weekProvider = StreamProvider.autoDispose.family<List<ScheduleRun>, (String, String)>((Ref ref, (String, String) key) {
  final DateTime weekStart = ScheduleDates.parse(key.$2) ?? DateTime(2000);
  return ref.watch(scheduleRepositoryProvider).watchWeek(key.$1, weekStart);
});

/// Approved members of a carpool (their children, cars and driving days).
final _membersProvider = StreamProvider.autoDispose.family<List<CarpoolMember>, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchMembers(id),
);

/// The signed-in parent's membership of a carpool (is it the admin?).
final _membershipProvider = StreamProvider.autoDispose.family<Membership?, String>((Ref ref, String id) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<Membership?>.value(null);
  }
  return ref.watch(carpoolRepositoryProvider).watchMyMembership(id, session.uid);
});

/// The carpool summary (days and times).
final _carpoolProvider = StreamProvider.autoDispose.family<Carpool?, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchCarpool(id),
);

/// The signed-in parent's uid ('' when signed out).
String signedInUid(WidgetRef ref) {
  final SessionState session = ref.watch(sessionProvider);
  return session is SessionSignedIn ? session.uid : '';
}

/// Week plan (F7, F11, F27, F28): this week or next, day by day, with the
/// driver and status of every morning and afternoon run. A run opens a
/// sheet to confirm, ask for a swap, take an open run, or mark one's child
/// away. The group admin plans the week (the one primary action); every
/// member sets their driving days.
///
/// States: loading (skeleton), not planned (empty, with Plan for the
/// admin), error and offline (retry); actions show progress and feedback,
/// and ask before giving up or taking a run.
class ScheduleScreen extends ConsumerStatefulWidget {
  const ScheduleScreen({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen> {
  int _week = 0;
  bool _planning = false;

  String get _id => widget.carpoolId;

  DateTime _weekStart(DateTime now) => ScheduleDates.addDays(ScheduleDates.weekStart(now), 7 * _week);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final DateTime now = ref.watch(scheduleClockProvider)();
    final DateTime weekStart = _weekStart(now);
    final (String, String) key = (_id, ScheduleDates.key(weekStart));
    final AsyncValue<List<ScheduleRun>> runs = ref.watch(_weekProvider(key));
    final AsyncValue<List<CarpoolMember>> members = ref.watch(_membersProvider(_id));
    final AsyncValue<Membership?> membership = ref.watch(_membershipProvider(_id));
    final AsyncValue<Carpool?> carpool = ref.watch(_carpoolProvider(_id));
    void reload() {
      ref
        ..invalidate(_weekProvider(key))
        ..invalidate(_membersProvider(_id))
        ..invalidate(_membershipProvider(_id))
        ..invalidate(_carpoolProvider(_id));
    }

    final Object? error = runs.error ?? members.error ?? membership.error ?? carpool.error;
    final Widget body;
    if (error != null) {
      body = carpoolErrorView(error, reload);
    } else if (!runs.hasValue || !members.hasValue || !membership.hasValue || !carpool.hasValue) {
      body = const ScheduleSkeleton();
    } else {
      body = _content(context, now, weekStart, runs.value!, members.value!, membership.value, carpool.value);
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.scheduleWeekPlan)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, AppSpacing.s8),
              child: Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s8,
                children: <Widget>[
                  for (final (int week, String label) in <(int, String)>[(0, l10n.scheduleThisWeek), (1, l10n.scheduleNextWeek)])
                    AppChip(
                      key: Key('schedule.week.$week'),
                      label: label,
                      selected: _week == week,
                      onSelected: (bool _) => setState(() => _week = week),
                    ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    DateTime now,
    DateTime weekStart,
    List<ScheduleRun> runs,
    List<CarpoolMember> members,
    Membership? membership,
    Carpool? carpool,
  ) {
    final AppLocalizations l10n = context.l10n;
    final String uid = signedInUid(ref);
    final bool admin = membership?.status == MembershipStatus.approved && (membership?.isAdmin ?? false);
    final CarpoolMember? me = members.where((CarpoolMember m) => m.uid == uid).firstOrNull;
    final bool hasCar = me?.car != null;
    final int toConfirm = runsToConfirm(runs, uid, now);

    if (runs.isEmpty) {
      return EmptyStateView(
        key: const Key('schedule.empty'),
        icon: Icons.calendar_month_outlined,
        title: l10n.scheduleNotPlannedTitle,
        body: admin ? l10n.scheduleNotPlannedAdmin : l10n.scheduleNotPlannedMember,
        actionLabel: admin ? l10n.schedulePlan : l10n.scheduleMyDays,
        onAction: _planning ? null : () => unawaited(admin ? _plan(weekStart) : _days(carpool, me)),
      );
    }
    return ListView(
      key: const Key('schedule.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        if (toConfirm > 0)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
            child: AppInlineMessage(
              key: const Key('schedule.toConfirm'),
              message: l10n.scheduleToConfirm(toConfirm),
              tone: AppStateTone.warning,
              icon: Icons.notifications_active_outlined,
            ),
          ),
        for (final (DateTime day, List<ScheduleRun> dayRuns) in runsByDay(runs)) ...<Widget>[
          AppSectionHeader(dayTitle(context, day)),
          for (final ScheduleRun run in dayRuns) _RunRow(run: run, uid: uid, onTap: () => unawaited(_openRun(run, hasCar))),
        ],
        const SizedBox(height: AppSpacing.s24),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (admin) ...<Widget>[
                AppButton(
                  key: const Key('schedule.plan'),
                  label: l10n.schedulePlan,
                  icon: Icons.auto_awesome_outlined,
                  expand: true,
                  loading: _planning,
                  onPressed: _planning ? null : () => unawaited(_plan(weekStart)),
                ),
                const SizedBox(height: AppSpacing.s8),
              ],
              AppButton(
                key: const Key('schedule.myDays'),
                label: l10n.scheduleMyDays,
                icon: Icons.event_available_outlined,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => unawaited(_days(carpool, me)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _plan(DateTime weekStart) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _planning = true);
    try {
      final PlanResult result = await ref.read(scheduleRepositoryProvider).planWeek(_id, weekStart);
      showAppSnackBarOn(messenger, result.open == 0 ? l10n.schedulePlanned : l10n.schedulePlannedOpen(result.open));
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _planning = false);
      }
    }
  }

  Future<void> _openRun(ScheduleRun run, bool hasCar) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showAppSheet<void>(
      context: context,
      title: runTitle(context.l10n, run),
      body: RunSheet(carpoolId: _id, run: run, hasCar: hasCar, messenger: messenger),
    );
  }

  Future<void> _days(Carpool? carpool, CarpoolMember? me) async {
    if (carpool == null || me == null) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showAppSheet<void>(
      context: context,
      title: context.l10n.scheduleMyDays,
      body: DrivingDaysSheet(carpoolId: _id, carpoolDays: carpool.days, selected: me.drivingDays, messenger: messenger),
    );
  }
}

/// One run in the week plan: direction and time, driver and riders, status.
class _RunRow extends StatelessWidget {
  const _RunRow({required this.run, required this.uid, required this.onTap});

  final ScheduleRun run;
  final String uid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String label, AppBadgeTone tone) = runBadge(l10n, run);
    final String? driver = run.driverUid;
    final String who = driver == null ? l10n.scheduleNoDriver : (driver == uid ? l10n.scheduleYou : run.driverFirstName);
    final String direction = run.direction == RunDirection.toSchool ? l10n.scheduleDirToSchool : l10n.scheduleDirToHome;
    final String detail = run.status == RunStatus.cancelled ? l10n.runNoSchool : l10n.scheduleDriverLine(who, run.riders.length);
    // The time is the title and the status badge sits beside it; no icon
    // or chevron, so the title keeps its room at 320 dp and 200 percent.
    return AppListRow(
      key: Key('schedule.run.${run.id}'),
      title: run.time,
      subtitle: '$direction${l10n.dotSeparator}$detail',
      showChevron: false,
      trailing: AppStatusBadge(label: label, tone: tone),
      onTap: onTap,
    );
  }
}

/// One run (F11, F27, F28): who drives, by when to confirm, the pickup
/// list, the parent's own children (away today), and the one action that
/// fits: Confirm, Can't drive, Take it back or I'll drive it.
class RunSheet extends ConsumerStatefulWidget {
  const RunSheet({required this.carpoolId, required this.run, required this.hasCar, required this.messenger, super.key});

  final String carpoolId;
  final ScheduleRun run;
  final bool hasCar;
  final ScaffoldMessengerState messenger;

  @override
  ConsumerState<RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends ConsumerState<RunSheet> {
  String? _busy;
  String? _error;

  ScheduleRun get _run => widget.run;

  Future<void> _do(String key, Future<void> Function() action, String done, {String? confirmTitle, String? confirmBody, String? confirmLabel}) async {
    final AppLocalizations l10n = context.l10n;
    if (confirmTitle != null) {
      final bool sure = await showConfirmDialog(
        context: context,
        title: confirmTitle,
        body: confirmBody ?? '',
        confirmLabel: confirmLabel ?? l10n.actionConfirm,
      );
      if (!sure || !mounted) {
        return;
      }
    }
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _busy = key;
      _error = null;
    });
    try {
      await action();
      showAppSnackBarOn(widget.messenger, done);
      navigator.pop();
    } on CarpoolFailure catch (failure) {
      if (mounted) {
        setState(() => _error = failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ScheduleRepository repo = ref.read(scheduleRepositoryProvider);
    final String uid = signedInUid(ref);
    final DateTime now = ref.watch(scheduleClockProvider)();
    final RunAction action = runAction(_run, uid, now, hasCar: widget.hasCar);
    final (String badge, AppBadgeTone tone) = runBadge(l10n, _run);
    final String? driver = _run.driverUid;
    final DateTime? deadline = _run.confirmBy;
    final bool live = _run.isLive(now);
    final List<(Rider, bool)> mine = live ? myChildrenOn(_run, uid) : const <(Rider, bool)>[];
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final String id = widget.carpoolId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: OneLineText(dayTitle(context, _run.date), style: context.text.titleSmall)),
            AppStatusBadge(key: const Key('run.badge'), label: badge, tone: tone),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        Text(
          driver == null ? l10n.scheduleNoDriver : l10n.scheduleDriverIs(driver == uid ? l10n.scheduleYou : _run.driverFirstName),
          key: const Key('run.driver'),
          style: context.text.bodyLarge,
        ),
        if (live && deadline != null && (_run.status == RunStatus.planned || _run.status == RunStatus.open))
          Text(l10n.scheduleConfirmBy(deadlineText(context, deadline)), key: const Key('run.deadline'), style: quiet),
        if (_run.status == RunStatus.planned && _run.fallback) Text(l10n.scheduleFallbackNote, style: quiet),
        if (_run.status == RunStatus.missed) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('run.missed'), message: l10n.scheduleMissedNote, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s16),
        Semantics(header: true, child: OneLineText(l10n.schedulePickupList, style: context.text.titleSmall)),
        const SizedBox(height: AppSpacing.s8),
        if (_run.riders.isEmpty && _run.absent.isEmpty) Text(l10n.scheduleNoRiders, style: quiet),
        for (final Rider r in _run.riders) Text(r.firstName, key: Key('run.rider.${r.id}'), style: context.text.bodyLarge),
        for (final Rider r in _run.absent) Text(l10n.scheduleAbsentTag(r.firstName), key: Key('run.away.${r.id}'), style: quiet),
        if (mine.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          for (final (Rider child, bool away) in mine)
            AppSwitchRow(
              key: Key('run.absent.${child.id}'),
              title: l10n.scheduleAbsentChild(child.firstName),
              subtitle: l10n.scheduleAbsentHelper,
              value: away,
              onChanged: _busy != null
                  ? null
                  : (bool on) => unawaited(
                      _do(
                        'absent.${child.id}',
                        () => repo.setChildAbsent(carpoolId: id, date: _run.date, childId: child.id, absent: on),
                        on ? l10n.scheduleMarkedAbsent : l10n.scheduleMarkedBack,
                      ),
                    ),
            ),
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('run.error'), message: _error!, tone: AppStateTone.error),
        ],
        if (action != RunAction.none) const SizedBox(height: AppSpacing.s24),
        if (action == RunAction.confirm)
          AppButton(
            key: const Key('run.confirm'),
            label: l10n.scheduleConfirm,
            icon: Icons.check_circle_outline_rounded,
            size: AppButtonSize.large,
            expand: true,
            loading: _busy == 'confirm',
            onPressed: _busy != null ? null : () => unawaited(_do('confirm', () => repo.confirmRun(id, _run.id), l10n.scheduleConfirmedSnack)),
          ),
        if (action == RunAction.take)
          AppButton(
            key: const Key('run.take'),
            label: l10n.scheduleTake,
            icon: Icons.directions_car_outlined,
            size: AppButtonSize.large,
            expand: true,
            loading: _busy == 'take',
            onPressed: _busy != null
                ? null
                : () => unawaited(
                    _do(
                      'take',
                      () => repo.takeRun(id, _run.id),
                      l10n.scheduleTaken,
                      confirmTitle: l10n.scheduleTakeTitle,
                      confirmBody: l10n.scheduleTakeBody,
                      confirmLabel: l10n.scheduleTake,
                    ),
                  ),
          ),
        if (action == RunAction.takeBack)
          AppButton(
            key: const Key('run.takeBack'),
            label: l10n.scheduleTakeBack,
            size: AppButtonSize.large,
            expand: true,
            loading: _busy == 'takeBack',
            onPressed: _busy != null ? null : () => unawaited(_do('takeBack', () => repo.cancelSwap(id, _run.id), l10n.scheduleTakenBack)),
          ),
        if (action == RunAction.confirm || action == RunAction.cantDrive) ...<Widget>[
          if (action == RunAction.confirm) const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('run.cantDrive'),
            label: l10n.scheduleCantDrive,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.large,
            expand: true,
            loading: _busy == 'swap',
            onPressed: _busy != null
                ? null
                : () => unawaited(
                    _do(
                      'swap',
                      () => repo.requestSwap(id, _run.id),
                      l10n.scheduleSwapSent,
                      confirmTitle: l10n.scheduleSwapTitle,
                      confirmBody: l10n.scheduleSwapBody,
                      confirmLabel: l10n.scheduleSwapAsk,
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

/// F7: the member picks the weekdays they can drive (carpool days only).
/// The server refuses until every parent accepted them as a driver (F26);
/// the message says so.
class DrivingDaysSheet extends ConsumerStatefulWidget {
  const DrivingDaysSheet({required this.carpoolId, required this.carpoolDays, required this.selected, required this.messenger, super.key});

  final String carpoolId;
  final List<Weekday> carpoolDays;
  final List<Weekday> selected;
  final ScaffoldMessengerState messenger;

  @override
  ConsumerState<DrivingDaysSheet> createState() => _DrivingDaysSheetState();
}

class _DrivingDaysSheetState extends ConsumerState<DrivingDaysSheet> {
  late List<Weekday> _days = List<Weekday>.of(widget.selected);
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(scheduleRepositoryProvider).setDrivingDays(widget.carpoolId, _days);
      showAppSnackBarOn(widget.messenger, l10n.scheduleDaysSaved);
      navigator.pop();
    } on CarpoolFailure catch (failure) {
      if (mounted) {
        setState(() => _error = failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.scheduleMyDaysIntro),
        const SizedBox(height: AppSpacing.s16),
        DaysPicker(
          keyPrefix: 'days',
          only: widget.carpoolDays,
          selected: _days,
          onChanged: (List<Weekday> days) => setState(() => _days = days),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('days.error'), message: _error!, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(key: const Key('days.save'), label: l10n.actionSave, expand: true, loading: _saving, onPressed: _saving ? null : () => unawaited(_save())),
      ],
    );
  }
}

/// Skeleton of the week plan and the schedule lists.
class ScheduleSkeleton extends StatelessWidget {
  const ScheduleSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s24, width: AppSpacing.s64 * 2),
          SizedBox(height: AppSpacing.s16),
          SkeletonListRow(),
          SkeletonListRow(),
          SizedBox(height: AppSpacing.s16),
          SkeletonBox(height: AppSpacing.s24, width: AppSpacing.s64 * 2),
          SizedBox(height: AppSpacing.s16),
          SkeletonListRow(),
          SkeletonListRow(),
        ],
      ),
    ),
  );
}
