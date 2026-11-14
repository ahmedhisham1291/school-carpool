import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/chat/chat_labels.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/features/chat/chat_session.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// "Now" for chat times (tests fix it).
final Provider<DateTime Function()> chatClockProvider = Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// Routes of the Chats tab.
abstract final class ChatRoutes {
  static const String requestsSegment = 'requests';
  static const String settingsSegment = 'settings';
  static const String requests = '/chats/$requestsSegment';
  static const String settings = '/chats/$settingsSegment';
}

/// Chats tab (spec section 10; F8 to F10): private, school, area and
/// carpool chats, newest activity first. Requests waiting for an answer
/// sit on top. The app bar opens requests and chat settings.
///
/// States: loading (skeleton rows), empty ("No chats yet"), error and
/// offline (retry). When the connection drops, a note says messages will
/// send when the phone is back online (Stream's offline queue).
class ChatsScreen extends ConsumerWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ChatSummary>> list = ref.watch(chatListProvider);
    final List<ChatRequest> incoming = ref.watch(incomingRequestsProvider);
    final bool offline = ref.watch(chatConnectionProvider).value == ChatConnection.offline;

    final Widget body;
    final Object? error = list.error;
    if (error != null) {
      void retry() => ref.invalidate(chatClientProvider);
      body = ChatFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry);
    } else if (!list.hasValue) {
      body = const Skeleton(
        child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow(), SkeletonListRow()]),
      );
    } else {
      final List<ChatSummary> chats = list.value ?? const <ChatSummary>[];
      body = ListView(
        key: const Key('chats.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          if (offline)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, AppSpacing.s8),
              child: AppInlineMessage(key: const Key('chats.offline'), message: l10n.chatOfflineNote, tone: AppStateTone.warning),
            ),
          if (incoming.isNotEmpty)
            AppListRow(
              key: const Key('chats.requestsRow'),
              title: l10n.chatRequestsWaiting(incoming.length),
              leadingIcon: Icons.person_add_alt_rounded,
              onTap: () => context.go(ChatRoutes.requests),
            ),
          if (chats.isEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: AppSpacing.s48),
              child: EmptyStateView(
                key: const Key('chats.empty'),
                icon: Icons.chat_bubble_outline_rounded,
                title: l10n.chatEmptyTitle,
                body: l10n.chatEmptyBody,
              ),
            )
          else
            for (final ChatSummary c in chats) ChatRow(chat: c),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.tabChats),
        actions: <Widget>[
          IconButton(
            key: const Key('chats.requests'),
            tooltip: l10n.chatRequestsTitle,
            icon: Badge(
              isLabelVisible: incoming.isNotEmpty,
              label: Text('${incoming.length}'),
              child: const Icon(Icons.person_add_alt_rounded),
            ),
            onPressed: () => context.go(ChatRoutes.requests),
          ),
          IconButton(
            key: const Key('chats.settings'),
            tooltip: l10n.chatSettingsTitle,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.go(ChatRoutes.settings),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            final ChatProvider? p = ref.read(chatClientProvider).value;
            if (p != null) {
              await p.refreshChats();
            }
          },
          child: body,
        ),
      ),
    );
  }
}

/// One chat: kind icon, name (one line), newest message, time, unread
/// count and a muted mark.
class ChatRow extends ConsumerWidget {
  const ChatRow({required this.chat, super.key});

  final ChatSummary chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String lang = Localizations.localeOf(context).languageCode;
    final DateTime now = ref.watch(chatClockProvider)();
    final DateTime? at = chat.lastAt;
    return AppListRow(
      key: Key('chat.${chat.ref.cid}'),
      title: chatTitle(l10n, chat.ref, chat.title(lang)),
      subtitle: chatPreview(l10n, chat.lastMessage),
      leadingIcon: chatKindIcon(chat.ref.kind),
      showChevron: false,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (at != null)
            OneLineText(
              chatTime(lang, at, now),
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (chat.muted)
                Icon(Icons.notifications_off_outlined, size: AppIconSize.sm, color: context.colors.onSurfaceVariant, semanticLabel: l10n.chatMuted),
              if (chat.unread > 0) ...<Widget>[
                const SizedBox(width: AppSpacing.s4),
                AppCountPill(count: chat.unread, semanticLabel: l10n.chatUnreadCount(chat.unread)),
              ],
            ],
          ),
        ],
      ),
      onTap: () => context.go(chat.ref.route),
    );
  }
}

/// Requests (F8; spec section 5): requests waiting for this parent's
/// answer (Accept, Decline) and requests they sent (Cancel). First names
/// only.
///
/// States: loading (skeleton rows), empty, error and offline.
class ChatRequestsScreen extends ConsumerWidget {
  const ChatRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ChatRequest>> all = ref.watch(chatRequestsProvider);
    final List<ChatRequest> incoming = ref.watch(incomingRequestsProvider);
    final Widget body;
    final Object? error = all.error;
    if (error != null) {
      void retry() => ref.invalidate(chatRequestsProvider);
      body = ChatFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry);
    } else if (!all.hasValue) {
      body = const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()]));
    } else {
      final List<ChatRequest> sent = <ChatRequest>[
        for (final ChatRequest r in all.value ?? const <ChatRequest>[])
          if (r.pending && !incoming.contains(r)) r,
      ];
      body = incoming.isEmpty && sent.isEmpty
          ? EmptyStateView(key: const Key('requests.empty'), icon: Icons.person_add_alt_rounded, title: l10n.chatRequestsEmptyTitle, body: l10n.chatRequestsEmptyBody)
          : ListView(
              key: const Key('requests.list'),
              padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
              children: <Widget>[
                if (incoming.isNotEmpty) ...<Widget>[
                  AppSectionHeader(l10n.chatRequestsIncoming),
                  for (final ChatRequest r in incoming) _IncomingRequest(request: r),
                ],
                if (sent.isNotEmpty) ...<Widget>[
                  AppSectionHeader(l10n.chatRequestsSent),
                  for (final ChatRequest r in sent)
                    AppListRow(
                      key: Key('request.${r.id}'),
                      title: r.toFirstName,
                      subtitle: l10n.chatRequestWaiting,
                      leadingIcon: Icons.person_outline_rounded,
                      showChevron: false,
                      trailing: TextButton(
                        key: Key('request.${r.id}.cancel'),
                        onPressed: () => unawaited(_cancel(context, ref, r)),
                        child: OneLineText(l10n.chatRequestCancel),
                      ),
                    ),
                ],
              ],
            );
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.chatRequestsTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, ChatRequest r) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(chatRepositoryProvider).cancelRequest(r.id);
      showAppSnackBarOn(messenger, l10n.chatRequestCancelled);
    } on ChatFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }
}

class _IncomingRequest extends ConsumerStatefulWidget {
  const _IncomingRequest({required this.request});

  final ChatRequest request;

  @override
  ConsumerState<_IncomingRequest> createState() => _IncomingRequestState();
}

class _IncomingRequestState extends ConsumerState<_IncomingRequest> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final GoRouter? router = GoRouter.maybeOf(context);
    setState(() => _busy = true);
    try {
      final ChatRequestResult r = await ref.read(chatRepositoryProvider).answerRequest(widget.request.id, accept: accept);
      final ChatRef? chat = r.chat;
      showAppSnackBarOn(messenger, accept ? l10n.chatRequestAccepted : l10n.chatRequestDeclined);
      if (accept && chat != null) {
        unawaited(ref.read(chatClientProvider).value?.refreshChats());
        router?.go(chat.route);
      }
    } on ChatFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final ChatRequest r = widget.request;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
      child: AppCard(
        key: Key('request.${r.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OneLineText(r.fromFirstName, style: context.text.titleSmall),
            const SizedBox(height: AppSpacing.s4),
            Text(l10n.chatRequestBody, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              key: Key('request.${r.id}.accept'),
              label: l10n.chatRequestAccept,
              // Several requests can wait: no filled button (one primary per screen).
              variant: AppButtonVariant.secondary,
              expand: true,
              loading: _busy,
              onPressed: _busy ? null : () => unawaited(_answer(true)),
            ),
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              key: Key('request.${r.id}.decline'),
              label: l10n.chatRequestDecline,
              variant: AppButtonVariant.tertiary,
              expand: true,
              onPressed: _busy ? null : () => unawaited(_answer(false)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chat settings (spec section 5): allow new requests or not, and the
/// parents this parent blocked (Unblock, after asking).
///
/// States: loading (skeleton rows), error and offline; the blocked list
/// has its own empty line.
class ChatSettingsScreen extends ConsumerStatefulWidget {
  const ChatSettingsScreen({super.key});

  @override
  ConsumerState<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends ConsumerState<ChatSettingsScreen> {
  bool? _pending;

  Future<void> _setRequests(bool allow) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _pending = allow);
    try {
      await ref.read(chatRepositoryProvider).setRequestsOff(off: !allow);
      showAppSnackBarOn(messenger, l10n.chatSettingsSaved);
    } on ChatFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _pending = null);
      }
    }
  }

  Future<void> _unblock(ChatBlock b) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.chatUnblockConfirmTitle,
      body: l10n.chatUnblockConfirmBody(b.firstName),
      confirmLabel: l10n.chatUnblock,
    );
    if (!ok) {
      return;
    }
    try {
      await ref.read(chatRepositoryProvider).unblock(b.blockedUid);
      showAppSnackBarOn(messenger, l10n.chatUnblocked);
    } on ChatFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<bool> off = ref.watch(chatRequestsOffProvider);
    final AsyncValue<List<ChatBlock>> blocks = ref.watch(chatBlocksProvider);
    final Object? error = off.error ?? blocks.error;
    final Widget body;
    if (error != null) {
      void retry() {
        ref
          ..invalidate(chatRequestsOffProvider)
          ..invalidate(chatBlocksProvider);
      }

      body = ChatFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry);
    } else if (!off.hasValue || !blocks.hasValue) {
      body = const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()]));
    } else {
      final List<ChatBlock> list = blocks.value ?? const <ChatBlock>[];
      body = ListView(
        key: const Key('chatSettings.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          AppSwitchRow(
            key: const Key('chatSettings.requests'),
            title: l10n.chatSettingsAllowRequests,
            subtitle: l10n.chatSettingsAllowRequestsBody,
            leadingIcon: Icons.person_add_alt_rounded,
            value: _pending ?? !(off.value ?? false),
            onChanged: _pending == null ? (bool v) => unawaited(_setRequests(v)) : null,
          ),
          AppSectionHeader(l10n.chatSettingsBlocked),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
              child: Text(l10n.chatSettingsNoBlocked, key: const Key('chatSettings.noBlocked'), style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
            )
          else
            for (final ChatBlock b in list)
              AppListRow(
                key: Key('blocked.${b.blockedUid}'),
                title: b.firstName,
                leadingIcon: Icons.block_rounded,
                showChevron: false,
                trailing: TextButton(
                  key: Key('blocked.${b.blockedUid}.unblock'),
                  onPressed: () => unawaited(_unblock(b)),
                  child: OneLineText(l10n.chatUnblock),
                ),
              ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.chatSettingsTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}
