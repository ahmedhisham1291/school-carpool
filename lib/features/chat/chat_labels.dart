import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Words and icons for chat screens. Every string comes from the
/// ARB files.

IconData chatKindIcon(ChatKind kind) => switch (kind) {
  ChatKind.private => Icons.person_outline_rounded,
  ChatKind.school => Icons.school_outlined,
  ChatKind.area => Icons.holiday_village_outlined,
  ChatKind.carpool => Icons.directions_car_outlined,
};

String chatKindLabel(AppLocalizations l10n, ChatKind kind) => switch (kind) {
  ChatKind.private => l10n.chatKindPrivate,
  ChatKind.school => l10n.chatKindSchool,
  ChatKind.area => l10n.chatKindArea,
  ChatKind.carpool => l10n.chatKindCarpool,
};

/// A chat's name, or what it is when the name is missing.
String chatTitle(AppLocalizations l10n, ChatRef ref, String name) => name.isNotEmpty ? name : chatKindLabel(l10n, ref.kind);

/// The list's preview line: "You: ..." for the parent's own, "Photo",
/// "Location" or "Message removed" for the others.
String chatPreview(AppLocalizations l10n, ChatPreview? p) {
  if (p == null) {
    return l10n.chatNoMessages;
  }
  final String body = switch (p.kind) {
    ChatMessageKind.text => p.text.replaceAll('\n', ' '),
    ChatMessageKind.photo => l10n.chatPhoto,
    ChatMessageKind.location => l10n.chatLocation,
    ChatMessageKind.deleted => l10n.chatMessageRemoved,
  };
  return p.mine ? l10n.chatPreviewMine(body) : body;
}

/// "09:41" today, "Mon" this week, "16/11" before (local time).
String chatTime(String locale, DateTime at, DateTime now) {
  final DateTime local = at.toLocal();
  final DateTime today = DateTime(now.toLocal().year, now.toLocal().month, now.toLocal().day);
  if (!local.isBefore(today)) {
    return DateFormat.Hm(locale).format(local);
  }
  if (today.difference(local).inDays < 6) {
    return DateFormat.E(locale).format(local);
  }
  return DateFormat.Md(locale).format(local);
}

String reportReasonLabel(AppLocalizations l10n, ReportReason r) => switch (r) {
  ReportReason.harassment => l10n.chatReasonHarassment,
  ReportReason.spam => l10n.chatReasonSpam,
  ReportReason.inappropriate => l10n.chatReasonInappropriate,
  ReportReason.privacy => l10n.chatReasonPrivacy,
  ReportReason.childSafety => l10n.chatReasonChildSafety,
  ReportReason.dangerousDriving => l10n.chatReasonDriving,
  ReportReason.other => l10n.chatReasonOther,
};

String deliveryLabel(AppLocalizations l10n, ChatDelivery d) => switch (d) {
  ChatDelivery.sending => l10n.chatSending,
  ChatDelivery.sent => l10n.chatSent,
  ChatDelivery.read => l10n.chatRead,
  ChatDelivery.failed => l10n.chatFailed,
};
