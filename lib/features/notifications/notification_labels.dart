import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Words for notifications, in the app's language. The server sends only
/// the type, the run's date and direction and IDs; the app writes the text.
/// Titles are short so list rows stay on one line at 320 dp.

/// "Mon 16/11, to school": the run a notification is about; empty when none.
String notificationWhen(AppLocalizations l10n, AppNotification n) {
  final DateTime? d = n.date;
  if (d == null) {
    return '';
  }
  final String day = '${dayShort(l10n, ScheduleDates.weekdayOf(d))} ${d.day}/${d.month}';
  return switch (n.toSchool) {
    true => l10n.notifWhenToSchool(day),
    false => l10n.notifWhenHome(day),
    null => day,
  };
}

String notificationTitle(AppLocalizations l10n, NotificationKind k) => switch (k) {
  NotificationKind.planReady => l10n.notifPlanReadyTitle,
  NotificationKind.noDriver => l10n.notifNoDriverTitle,
  NotificationKind.swapRequested => l10n.notifSwapRequestedTitle,
  NotificationKind.swapAccepted || NotificationKind.runTaken => l10n.notifNewDriverTitle,
  NotificationKind.swapCancelled => l10n.notifSwapCancelledTitle,
  NotificationKind.childAbsent => l10n.notifChildAbsentTitle,
  NotificationKind.childBack => l10n.notifChildBackTitle,
  NotificationKind.driverUnavailable => l10n.notifNeedsDriverTitle,
  NotificationKind.scheduleChanged => l10n.notifScheduleChangedTitle,
  NotificationKind.driveEvening => l10n.notifDriveEveningTitle,
  NotificationKind.driveHour => l10n.notifDriveHourTitle,
  NotificationKind.confirmReminder => l10n.notifConfirmTitle,
  NotificationKind.joinRequested => l10n.notifJoinRequestedTitle,
  NotificationKind.joinApproved => l10n.notifJoinApprovedTitle,
  NotificationKind.joinDeclined => l10n.notifJoinDeclinedTitle,
  NotificationKind.verificationApproved => l10n.notifApprovedTitle,
  NotificationKind.verificationRejected => l10n.notifRejectedTitle,
  NotificationKind.newParent => l10n.notifNewParentTitle,
  NotificationKind.childNotConfirmed => l10n.notifChildNotConfirmedTitle,
  NotificationKind.chatMessage => l10n.notifChatTitle,
};

/// One short sentence. Run types name the run ("Mon 16/11, to school");
/// never a child's or parent's name.
String notificationBody(AppLocalizations l10n, AppNotification n) {
  final String when = notificationWhen(l10n, n);
  final String run = when.isEmpty ? l10n.notifWhenSoon : when;
  return switch (n.kind) {
    NotificationKind.planReady => l10n.notifPlanReadyBody,
    NotificationKind.noDriver => l10n.notifNoDriverBody(run),
    NotificationKind.swapRequested => l10n.notifSwapRequestedBody(run),
    NotificationKind.swapAccepted || NotificationKind.runTaken => l10n.notifNewDriverBody(run),
    NotificationKind.swapCancelled => l10n.notifSwapCancelledBody(run),
    NotificationKind.childAbsent => l10n.notifChildAbsentBody(run),
    NotificationKind.childBack => l10n.notifChildBackBody(run),
    NotificationKind.driverUnavailable => l10n.notifNeedsDriverBody(run),
    NotificationKind.scheduleChanged => l10n.notifScheduleChangedBody,
    NotificationKind.driveEvening => l10n.notifDriveEveningBody(run),
    NotificationKind.driveHour => l10n.notifDriveHourBody(run),
    NotificationKind.confirmReminder => l10n.notifConfirmBody(run),
    NotificationKind.joinRequested => l10n.notifJoinRequestedBody,
    NotificationKind.joinApproved => l10n.notifJoinApprovedBody,
    NotificationKind.joinDeclined => l10n.notifJoinDeclinedBody,
    NotificationKind.verificationApproved => l10n.notifApprovedBody,
    NotificationKind.verificationRejected => l10n.notifRejectedBody,
    NotificationKind.newParent => l10n.notifNewParentBody,
    NotificationKind.childNotConfirmed => l10n.notifChildNotConfirmedBody,
    NotificationKind.chatMessage => l10n.notifChatBody,
  };
}

IconData notificationIcon(NotificationKind k) => switch (k.group) {
  WhatsAppGroup.noDriver || WhatsAppGroup.childNotConfirmed => Icons.warning_amber_rounded,
  WhatsAppGroup.reminders => Icons.alarm_rounded,
  WhatsAppGroup.swaps => Icons.swap_horiz_rounded,
  WhatsAppGroup.absences => Icons.event_busy_outlined,
  WhatsAppGroup.schedule => Icons.calendar_month_outlined,
  WhatsAppGroup.joins => Icons.group_add_outlined,
  WhatsAppGroup.verification => Icons.verified_user_outlined,
  WhatsAppGroup.newParents => Icons.person_pin_circle_outlined,
  null => Icons.chat_bubble_outline_rounded,
};

/// Settings row title for a WhatsApp group (one line at 320 dp).
String whatsAppGroupTitle(AppLocalizations l10n, WhatsAppGroup g) => switch (g) {
  WhatsAppGroup.noDriver => l10n.notifGroupNoDriver,
  WhatsAppGroup.childNotConfirmed => l10n.notifGroupChildNotConfirmed,
  WhatsAppGroup.reminders => l10n.notifGroupReminders,
  WhatsAppGroup.swaps => l10n.notifGroupSwaps,
  WhatsAppGroup.absences => l10n.notifGroupAbsences,
  WhatsAppGroup.schedule => l10n.notifGroupSchedule,
  WhatsAppGroup.joins => l10n.notifGroupJoins,
  WhatsAppGroup.verification => l10n.notifGroupVerification,
  WhatsAppGroup.newParents => l10n.notifGroupNewParents,
};

/// "10:30" today, "Sun 15/11" before.
String notificationTime(AppLocalizations l10n, DateTime createdAtUtc, DateTime now) {
  final DateTime t = createdAtUtc.toLocal();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
  return '${dayShort(l10n, ScheduleDates.weekdayOf(t))} ${t.day}/${t.month}';
}
