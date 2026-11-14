import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/chat/chat_labels.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Report (F13; spec section 6): a reason from a fixed list and an
/// optional short note. Urgent reasons say what happens next (the driver's
/// days pause at once and an admin reviews it today). Returns true when
/// sent.
Future<bool> showReportSheet(
  BuildContext context,
  WidgetRef ref, {
  required ChatRef chat,
  required ReportTarget target,
  String? messageId,
  String? uid,
}) async {
  final AppLocalizations l10n = context.l10n;
  final String title = switch (target) {
    ReportTarget.message => l10n.chatReportMessage,
    ReportTarget.user => l10n.chatReportParent,
    ReportTarget.group => l10n.chatReportGroup,
  };
  final bool? sent = await showAppSheet<bool>(
    context: context,
    title: title,
    body: ReportForm(chat: chat, target: target, messageId: messageId, uid: uid),
  );
  return sent ?? false;
}

class ReportForm extends ConsumerStatefulWidget {
  const ReportForm({required this.chat, required this.target, super.key, this.messageId, this.uid});

  final ChatRef chat;
  final ReportTarget target;
  final String? messageId;
  final String? uid;

  @override
  ConsumerState<ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends ConsumerState<ReportForm> {
  ReportReason? _reason;
  final TextEditingController _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ReportReason? reason = _reason;
    if (reason == null) {
      setState(() => _error = context.l10n.chatReportPickReason);
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bool urgent = await ref.read(chatRepositoryProvider).report(
        ref: widget.chat,
        target: widget.target,
        reason: reason,
        messageId: widget.messageId,
        uid: widget.uid,
        note: _note.text.trim(),
      );
      navigator.pop(true);
      showAppSnackBarOn(messenger, urgent ? l10n.chatReportSentUrgent : l10n.chatReportSent);
    } on ChatFailure catch (f) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = f.message(l10n);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ReportReason? reason = _reason;
    final String? error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.chatReportIntro),
        const SizedBox(height: AppSpacing.s16),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final ReportReason r in ReportReason.values)
              AppChip(
                key: Key('report.reason.${r.name}'),
                label: reportReasonLabel(l10n, r),
                selected: reason == r,
                onSelected: _busy
                    ? null
                    : (bool _) => setState(() {
                        _reason = r;
                        _error = null;
                      }),
              ),
          ],
        ),
        if (reason != null && reason.urgent) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('report.urgentNote'), message: l10n.chatReportUrgentNote, tone: AppStateTone.warning),
        ],
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('report.note'),
          label: l10n.chatReportNote,
          helperText: l10n.chatReportNoteHelp,
          controller: _note,
          maxLength: 300,
          enabled: !_busy,
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('report.send'),
          label: l10n.chatReportSend,
          expand: true,
          loading: _busy,
          onPressed: () => unawaited(_send()),
        ),
      ],
    );
  }
}

/// Asks, then blocks (F13). Returns true when blocked.
Future<bool> confirmAndBlock(BuildContext context, WidgetRef ref, {required String uid, required String firstName}) async {
  final AppLocalizations l10n = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool ok = await showConfirmDialog(
    context: context,
    title: l10n.chatBlockConfirmTitle,
    body: l10n.chatBlockConfirmBody(firstName),
    confirmLabel: l10n.chatBlock,
    destructive: true,
  );
  if (!ok) {
    return false;
  }
  try {
    await ref.read(chatRepositoryProvider).block(uid);
    showAppSnackBarOn(messenger, l10n.chatBlocked(firstName));
    return true;
  } on ChatFailure catch (f) {
    showAppSnackBarOn(messenger, f.message(l10n));
    return false;
  }
}

/// Chat info (spec section 10, "group info"): what the chat is, mute, and
/// report or block.
class ChatInfoSheet extends ConsumerStatefulWidget {
  const ChatInfoSheet({required this.info, super.key});

  final ChatInfo info;

  @override
  ConsumerState<ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends ConsumerState<ChatInfoSheet> {
  bool? _muted;

  Future<void> _setMuted(bool muted) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _muted = muted);
    try {
      await ref.read(chatRepositoryProvider).setMuted(widget.info.ref, muted: muted);
      showAppSnackBarOn(messenger, muted ? l10n.chatMutedDone : l10n.chatUnmutedDone);
    } on ChatFailure catch (f) {
      if (mounted) {
        setState(() => _muted = !muted);
      }
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ChatInfo info = widget.info;
    final String? other = info.otherUserId;
    final bool private = info.ref.kind == ChatKind.private;
    final String name = info.title(Localizations.localeOf(context).languageCode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(private ? l10n.chatInfoPrivate : l10n.chatInfoGroup(info.memberCount)),
        const SizedBox(height: AppSpacing.s8),
        AppSwitchRow(
          key: const Key('chatInfo.mute'),
          title: l10n.chatMute,
          subtitle: l10n.chatMuteBody,
          leadingIcon: Icons.notifications_off_outlined,
          value: _muted ?? info.muted,
          onChanged: (bool v) => unawaited(_setMuted(v)),
        ),
        AppListRow(
          key: const Key('chatInfo.report'),
          title: private ? l10n.chatReportParent : l10n.chatReportGroup,
          leadingIcon: Icons.flag_outlined,
          inset: false,
          onTap: () async {
            final NavigatorState navigator = Navigator.of(context);
            final bool sent = await showReportSheet(
              context,
              ref,
              chat: info.ref,
              target: private && other != null ? ReportTarget.user : ReportTarget.group,
              uid: private ? other : null,
            );
            if (sent) {
              navigator.pop();
            }
          },
        ),
        if (private && other != null)
          AppListRow(
            key: const Key('chatInfo.block'),
            title: l10n.chatBlockName(name),
            leadingIcon: Icons.block_rounded,
            inset: false,
            onTap: () async {
              final NavigatorState navigator = Navigator.of(context);
              if (await confirmAndBlock(context, ref, uid: other, firstName: name)) {
                navigator.pop();
              }
            },
          ),
      ],
    );
  }
}

/// Message button (nearby map card, carpool members): asks the other parent
/// for a private chat (spec section 5). Opens the chat at once when they
/// had already asked, or it exists.
Future<void> startPrivateChat(WidgetRef ref, ScaffoldMessengerState messenger, AppLocalizations l10n, {required String uid, required String firstName, void Function(String route)? open}) async {
  try {
    final ChatRequestResult r = await ref.read(chatRepositoryProvider).sendRequest(uid);
    final ChatRef? chat = r.chat;
    if (r.status == ChatRequestStatus.accepted && chat != null) {
      open?.call(chat.route);
      return;
    }
    showAppSnackBarOn(messenger, l10n.chatRequestSentTo(firstName));
  } on ChatFailure catch (f) {
    showAppSnackBarOn(messenger, f.message(l10n));
  }
}
