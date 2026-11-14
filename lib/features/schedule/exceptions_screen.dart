import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/schedule/schedule_labels.dart';
import 'package:school_carpool/features/schedule/schedule_logic.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/features/schedule/schedule_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _exceptionsProvider = StreamProvider.autoDispose.family<List<ScheduleException>, String>(
  (Ref ref, String id) => ref.watch(scheduleRepositoryProvider).watchExceptions(id),
);

final _membershipProvider = StreamProvider.autoDispose.family<Membership?, String>((Ref ref, String id) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<Membership?>.value(null);
  }
  return ref.watch(carpoolRepositoryProvider).watchMyMembership(id, session.uid);
});

final _carpoolProvider = StreamProvider.autoDispose.family<Carpool?, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchCarpool(id),
);

/// Days off and time changes (F30): holidays, exam days, early dismissal
/// and Ramadan times. Every member sees the list; the group admin adds and
/// removes them (the one primary action: Add). Runs and reminders follow
/// them on the server.
///
/// States: loading (skeleton), empty (with Add for the admin), error and
/// offline (retry); removing asks first.
class ExceptionsScreen extends ConsumerStatefulWidget {
  const ExceptionsScreen({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  ConsumerState<ExceptionsScreen> createState() => _ExceptionsScreenState();
}

class _ExceptionsScreenState extends ConsumerState<ExceptionsScreen> {
  String? _busy;

  String get _id => widget.carpoolId;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ScheduleException>> list = ref.watch(_exceptionsProvider(_id));
    final AsyncValue<Membership?> membership = ref.watch(_membershipProvider(_id));
    final AsyncValue<Carpool?> carpool = ref.watch(_carpoolProvider(_id));
    void reload() {
      ref
        ..invalidate(_exceptionsProvider(_id))
        ..invalidate(_membershipProvider(_id))
        ..invalidate(_carpoolProvider(_id));
    }

    final Object? error = list.error ?? membership.error ?? carpool.error;
    final Widget body;
    if (error != null) {
      body = carpoolErrorView(error, reload);
    } else if (!list.hasValue || !membership.hasValue || !carpool.hasValue) {
      body = const ScheduleSkeleton();
    } else {
      final Membership? m = membership.value;
      final bool admin = m != null && m.status == MembershipStatus.approved && m.isAdmin;
      body = _content(context, list.value!, admin, carpool.value);
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.scheduleExceptions)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, List<ScheduleException> list, bool admin, Carpool? carpool) {
    final AppLocalizations l10n = context.l10n;
    if (list.isEmpty) {
      return EmptyStateView(
        key: const Key('exceptions.empty'),
        icon: Icons.event_busy_outlined,
        title: l10n.exceptionsEmptyTitle,
        body: admin ? l10n.exceptionsEmptyBody : l10n.exceptionsEmptyMember,
        actionLabel: admin ? l10n.exceptionsAdd : null,
        onAction: admin ? () => unawaited(_add(carpool)) : null,
      );
    }
    return ListView(
      key: const Key('exceptions.list'),
      padding: const EdgeInsetsDirectional.only(top: AppSpacing.s8, bottom: AppSpacing.s32),
      children: <Widget>[
        for (final ScheduleException e in list)
          AppListRow(
            key: Key('exception.${e.id}'),
            title: reasonLabel(l10n, e.reason),
            subtitle: <String>[
              rangeText(context, e.from, e.to),
              if (e.kind == ExceptionKind.times) timesText(l10n, e.morning, e.afternoon) else kindLabel(l10n, e.kind),
            ].join(l10n.dotSeparator),
            leadingIcon: e.kind == ExceptionKind.noSchool ? Icons.event_busy_outlined : Icons.schedule_outlined,
            showChevron: false,
            trailing: admin
                ? IconButton(
                    key: Key('exception.delete.${e.id}'),
                    tooltip: l10n.exceptionDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _busy != null ? null : () => unawaited(_delete(e)),
                  )
                : null,
          ),
        if (admin) ...<Widget>[
          const SizedBox(height: AppSpacing.s24),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: AppButton(
              key: const Key('exceptions.add'),
              label: l10n.exceptionsAdd,
              icon: Icons.add_rounded,
              expand: true,
              onPressed: _busy != null ? null : () => unawaited(_add(carpool)),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _add(Carpool? carpool) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final DateTime today = ScheduleDates.day(ref.read(scheduleClockProvider)());
    await showAppSheet<void>(
      context: context,
      title: context.l10n.exceptionsAdd,
      body: ExceptionSheet(
        carpoolId: _id,
        hasMorning: carpool?.morning != null,
        hasAfternoon: carpool?.afternoon != null,
        today: today,
        messenger: messenger,
      ),
    );
  }

  Future<void> _delete(ScheduleException e) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.exceptionDeleteTitle,
      body: l10n.exceptionDeleteBody,
      confirmLabel: l10n.exceptionDelete,
      destructive: true,
    );
    if (!sure || !mounted) {
      return;
    }
    setState(() => _busy = e.id);
    try {
      await ref.read(scheduleRepositoryProvider).deleteException(_id, e.id);
      showAppSnackBarOn(messenger, l10n.exceptionDeleted);
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = null);
      }
    }
  }
}

/// Add a day off or a time change in two short steps (F30): 1 what (no
/// school or new times) and why; 2 when (one day or a range up to 60
/// days) and, for new times, the arrival and departure times. Each field
/// is checked as the admin picks, with a message that says how to fix it.
class ExceptionSheet extends ConsumerStatefulWidget {
  const ExceptionSheet({
    required this.carpoolId,
    required this.hasMorning,
    required this.hasAfternoon,
    required this.today,
    required this.messenger,
    super.key,
  });

  final String carpoolId;
  final bool hasMorning;
  final bool hasAfternoon;
  final DateTime today;
  final ScaffoldMessengerState messenger;

  @override
  ConsumerState<ExceptionSheet> createState() => _ExceptionSheetState();
}

class _ExceptionSheetState extends ConsumerState<ExceptionSheet> {
  int _step = 0;
  ExceptionKind _kind = ExceptionKind.noSchool;
  ExceptionReason _reason = ExceptionReason.holiday;
  late DateTime _from = widget.today;
  late DateTime _to = widget.today;
  String? _morning;
  String? _afternoon;
  bool _saving = false;
  String? _error;

  ExceptionDraft get _draft => ExceptionDraft(kind: _kind, reason: _reason, from: _from, to: _to, morning: _morning, afternoon: _afternoon);

  Future<void> _save() async {
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(scheduleRepositoryProvider).saveException(widget.carpoolId, _draft);
      showAppSnackBarOn(widget.messenger, l10n.exceptionSaved);
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

  List<(String?, String)> _timeOptions(AppLocalizations l10n) => <(String?, String)>[
    (null, l10n.exceptionUsual),
    for (final String t in RunTime.choices()) (t, t),
  ];

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ExceptionProblem? problem = checkException(_draft);
    final String? rangeError = problem == ExceptionProblem.range ? l10n.exceptionErrorRange : null;
    final String? timesError = problem == ExceptionProblem.times ? l10n.exceptionErrorTimes : null;
    final DateTime first = ScheduleDates.addDays(widget.today, -1);
    final DateTime last = ScheduleDates.addDays(widget.today, 365);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppStepProgress(current: _step + 1, total: 2),
        const SizedBox(height: AppSpacing.s16),
        if (_step == 0) ...<Widget>[
          OneLineText(l10n.exceptionKindLabel, style: context.text.titleSmall),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              for (final ExceptionKind k in ExceptionKind.values)
                AppChip(
                  key: Key('ex.kind.${k.name}'),
                  label: kindLabel(l10n, k),
                  selected: _kind == k,
                  onSelected: (bool _) => setState(() {
                    _kind = k;
                    if (k == ExceptionKind.times && _reason == ExceptionReason.holiday) {
                      _reason = ExceptionReason.ramadan;
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s16),
          OneLineText(l10n.exceptionReasonLabel, style: context.text.titleSmall),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              for (final ExceptionReason r in ExceptionReason.values)
                AppChip(
                  key: Key('ex.reason.${r.name}'),
                  label: reasonLabel(l10n, r),
                  selected: _reason == r,
                  onSelected: (bool _) => setState(() => _reason = r),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s24),
          AppButton(key: const Key('ex.next'), label: l10n.actionNext, expand: true, onPressed: () => setState(() => _step = 1)),
        ] else ...<Widget>[
          AppDateField(
            key: const Key('ex.from'),
            label: l10n.exceptionFrom,
            value: _from,
            firstDate: first,
            lastDate: last,
            onChanged: (DateTime d) => setState(() {
              _from = d;
              if (_to.isBefore(d)) {
                _to = d;
              }
            }),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppDateField(
            key: const Key('ex.to'),
            label: l10n.exceptionTo,
            value: _to,
            firstDate: first,
            lastDate: last,
            errorText: rangeError,
            onChanged: (DateTime d) => setState(() => _to = d),
          ),
          if (_kind == ExceptionKind.times) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            if (widget.hasMorning)
              AppSelectField<String?>(
                key: const Key('ex.morning'),
                label: l10n.exceptionMorning,
                options: _timeOptions(l10n),
                value: _morning,
                onChanged: (String? t) => setState(() => _morning = t),
              ),
            if (widget.hasMorning && widget.hasAfternoon) const SizedBox(height: AppSpacing.s16),
            if (widget.hasAfternoon)
              AppSelectField<String?>(
                key: const Key('ex.afternoon'),
                label: l10n.exceptionAfternoon,
                options: _timeOptions(l10n),
                value: _afternoon,
                onChanged: (String? t) => setState(() => _afternoon = t),
              ),
            if (timesError != null) ...<Widget>[
              const SizedBox(height: AppSpacing.s8),
              AppInlineMessage(key: const Key('ex.timesError'), message: timesError, tone: AppStateTone.error),
            ],
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppInlineMessage(key: const Key('ex.error'), message: _error!, tone: AppStateTone.error),
          ],
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            key: const Key('ex.save'),
            label: l10n.actionSave,
            expand: true,
            loading: _saving,
            onPressed: _saving || problem != null ? null : () => unawaited(_save()),
          ),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('ex.back'),
            label: l10n.actionBack,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: _saving ? null : () => setState(() => _step = 0),
          ),
        ],
      ],
    );
  }
}
