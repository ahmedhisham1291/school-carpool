import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Words for schedule codes, in the app's language. Short, so badges,
/// chips and titles stay on one line at 320 dp.

/// "To school 07:30" or "Home 14:30".
String runTitle(AppLocalizations l10n, ScheduleRun run) =>
    run.direction == RunDirection.toSchool ? l10n.scheduleToSchool(run.time) : l10n.scheduleToHome(run.time);

/// "Sun 15 Nov".
String dayTitle(BuildContext context, DateTime date) =>
    context.l10n.scheduleDayTitle(dayShort(context.l10n, ScheduleDates.weekdayOf(date)), MaterialLocalizations.of(context).formatShortMonthDay(date));

/// The badge of a run (one line).
(String, AppBadgeTone) runBadge(AppLocalizations l10n, ScheduleRun run) => switch (run.status) {
  RunStatus.planned => (l10n.runPlanned, AppBadgeTone.warning),
  RunStatus.confirmed => (l10n.runConfirmed, AppBadgeTone.success),
  RunStatus.open when run.swapId != null => (l10n.runSwapAsked, AppBadgeTone.warning),
  RunStatus.open => (l10n.runNeedsDriver, AppBadgeTone.error),
  RunStatus.missed => (l10n.runOwnTrip, AppBadgeTone.error),
  RunStatus.cancelled => (l10n.runNoSchool, AppBadgeTone.neutral),
  RunStatus.completed => (l10n.runDone, AppBadgeTone.neutral),
};

String reasonLabel(AppLocalizations l10n, ExceptionReason r) => switch (r) {
  ExceptionReason.holiday => l10n.exReasonHoliday,
  ExceptionReason.exams => l10n.exReasonExams,
  ExceptionReason.early => l10n.exReasonEarly,
  ExceptionReason.ramadan => l10n.exReasonRamadan,
  ExceptionReason.other => l10n.exReasonOther,
};

String kindLabel(AppLocalizations l10n, ExceptionKind k) => switch (k) {
  ExceptionKind.noSchool => l10n.exceptionKindNoSchool,
  ExceptionKind.times => l10n.exceptionKindTimes,
};

/// "15 Nov" or "8 Feb to 9 Mar".
String rangeText(BuildContext context, DateTime from, DateTime to) {
  final MaterialLocalizations m = MaterialLocalizations.of(context);
  return ScheduleDates.key(from) == ScheduleDates.key(to)
      ? m.formatShortMonthDay(from)
      : context.l10n.exceptionDateRange(m.formatShortMonthDay(from), m.formatShortMonthDay(to));
}

/// "Sat 21:00": when the driver must confirm (Cairo time on the phone).
String deadlineText(BuildContext context, DateTime deadline) {
  final DateTime local = deadline.toLocal();
  final String time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return context.l10n.scheduleDayTitle(dayShort(context.l10n, ScheduleDates.weekdayOf(local)), time);
}
