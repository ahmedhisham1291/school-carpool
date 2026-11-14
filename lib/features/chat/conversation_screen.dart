import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/chat/chat_labels.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_session.dart';
import 'package:school_carpool/features/chat/chat_sheets.dart';
import 'package:school_carpool/features/chat/chats_screen.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/location_service.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

/// One chat (spec section 10, "conversation"): messages oldest at the top,
/// newest at the bottom, the composer below. Photos and the location pin
/// only where the chat allows them (photos: private and carpool chats).
/// Read marks in small chats, a typing line, and an offline note: a
/// message written offline waits on the phone and sends when back online.
///
/// Long-press another parent's message to report it or block them. The
/// info button opens mute, report and block. A blocked parent's messages
/// in a group are hidden behind a short line.
///
/// States: loading (skeleton bubbles), empty ("No messages yet"), error
/// and offline (retry), and closed (a private chat where one parent
/// blocked the other: no composer).
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({required this.chat, super.key});

  final ChatRef chat;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final TextEditingController _text = TextEditingController();
  ChatConversation? _conversation;
  final List<StreamSubscription<Object>> _subs = <StreamSubscription<Object>>[];
  List<ChatMessage>? _messages;
  ChatInfo? _info;
  List<String> _typing = const <String>[];
  Object? _error;
  int _lastCount = 0;

  @override
  void dispose() {
    for (final StreamSubscription<Object> s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_conversation?.dispose());
    _text.dispose();
    super.dispose();
  }

  void _open(ChatProvider provider) {
    if (_conversation != null) {
      return;
    }
    final ChatConversation c = provider.open(widget.chat);
    _conversation = c;
    _subs
      ..add(
        c.messages.listen((List<ChatMessage> list) {
          if (!mounted) {
            return;
          }
          setState(() => _messages = list);
          if (list.length != _lastCount) {
            _lastCount = list.length;
            unawaited(c.markRead().catchError((Object _) {}));
          }
        }, onError: _failed),
      )
      ..add(
        c.info.listen((ChatInfo info) {
          if (mounted) {
            setState(() => _info = info);
          }
        }, onError: _failed),
      )
      ..add(
        c.typing.listen((List<String> names) {
          if (mounted) {
            setState(() => _typing = names);
          }
        }, onError: (Object _) {}),
      );
  }

  void _failed(Object error) {
    if (mounted) {
      setState(() => _error = error);
    }
  }

  void _retryAll() {
    for (final StreamSubscription<Object> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    unawaited(_conversation?.dispose());
    setState(() {
      _conversation = null;
      _error = null;
      _messages = null;
    });
    ref.invalidate(chatClientProvider);
  }

  Future<void> _run(Future<void> Function(ChatConversation c) action) async {
    final ChatConversation? c = _conversation;
    if (c == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action(c);
    } on Object catch (error) {
      showAppSnackBarOn(messenger, ChatFailure.from(error).message(l10n));
    }
  }

  void _sendText() {
    final String text = _text.text.trim();
    if (text.isEmpty) {
      return;
    }
    _text.clear();
    unawaited(_run((ChatConversation c) => c.sendText(text)));
  }

  Future<void> _sendPhoto() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PhotoSource? source = await showAppSheet<PhotoSource>(
      context: context,
      title: l10n.chatPhotoTitle,
      body: Builder(
        builder: (BuildContext sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.chatPhotoPrivacy),
            const SizedBox(height: AppSpacing.s8),
            AppListRow(
              key: const Key('chat.photo.camera'),
              title: l10n.chatPhotoCamera,
              leadingIcon: Icons.photo_camera_outlined,
              inset: false,
              onTap: () => Navigator.of(sheet).pop(PhotoSource.camera),
            ),
            AppListRow(
              key: const Key('chat.photo.gallery'),
              title: l10n.chatPhotoGallery,
              leadingIcon: Icons.photo_library_outlined,
              inset: false,
              onTap: () => Navigator.of(sheet).pop(PhotoSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) {
      return;
    }
    try {
      final Uint8List? jpeg = await ref.read(chatPhotoPickerProvider).pick(source);
      if (jpeg != null) {
        await _run((ChatConversation c) => c.sendPhoto(jpeg));
      }
    } on ChatFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  Future<void> _sendLocation() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.chatLocationConfirmTitle,
      body: l10n.chatLocationConfirmBody,
      confirmLabel: l10n.chatLocationSend,
    );
    if (!ok) {
      return;
    }
    final LocationService location = ref.read(locationServiceProvider);
    try {
      LocationAccess access = await location.access();
      if (access != LocationAccess.granted) {
        access = await location.request();
      }
      if (access != LocationAccess.granted) {
        showAppSnackBarOn(messenger, l10n.chatLocationDenied);
        return;
      }
      final GeoPin pin = await location.current();
      await _run((ChatConversation c) => c.sendLocation(pin.lat, pin.lng));
    } on LocationFailure {
      showAppSnackBarOn(messenger, l10n.chatLocationFailed);
    }
  }

  Future<void> _messageActions(ChatMessage m) async {
    final AppLocalizations l10n = context.l10n;
    final ChatRef chat = widget.chat;
    await showAppSheet<void>(
      context: context,
      title: l10n.chatMessageActions,
      body: Builder(
        builder: (BuildContext sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppListRow(
              key: const Key('chat.action.report'),
              title: l10n.chatReportMessage,
              leadingIcon: Icons.flag_outlined,
              inset: false,
              onTap: () async {
                Navigator.of(sheet).pop();
                await showReportSheet(context, ref, chat: chat, target: ReportTarget.message, messageId: m.id);
              },
            ),
            if (m.authorId.isNotEmpty)
              AppListRow(
                key: const Key('chat.action.block'),
                title: l10n.chatBlockName(m.authorName),
                leadingIcon: Icons.block_rounded,
                inset: false,
                onTap: () async {
                  Navigator.of(sheet).pop();
                  await confirmAndBlock(context, ref, uid: m.authorId, firstName: m.authorName);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showInfo(ChatInfo info) async {
    final AppLocalizations l10n = context.l10n;
    await showAppSheet<void>(
      context: context,
      title: chatTitle(l10n, info.ref, info.title(Localizations.localeOf(context).languageCode)),
      body: ChatInfoSheet(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<ChatProvider> client = ref.watch(chatClientProvider);
    final ChatProvider? provider = client.value;
    if (provider != null) {
      _open(provider);
    }
    final SessionState session = ref.watch(sessionProvider);
    final String me = session is SessionSignedIn ? session.uid : '';
    final Set<String> blocked = <String>{
      for (final ChatBlock b in ref.watch(chatBlocksProvider).value ?? const <ChatBlock>[]) b.blockedUid,
    };
    final bool offline = ref.watch(chatConnectionProvider).value == ChatConnection.offline;
    final ChatInfo? info = _info;
    final String lang = Localizations.localeOf(context).languageCode;
    final String title = info == null ? chatKindLabel(l10n, widget.chat.kind) : chatTitle(l10n, widget.chat, info.title(lang));
    final Object? error = client.error ?? _error;
    final List<ChatMessage>? messages = _messages;

    final Widget body;
    if (error != null) {
      body = ChatFailure.from(error).isOffline ? OfflineStateView(onRetry: _retryAll) : ErrorStateView(onRetry: _retryAll);
    } else if (messages == null) {
      body = const _SkeletonBubbles();
    } else {
      body = Column(
        children: <Widget>[
          if (offline)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s8, AppSpacing.s16, 0),
              child: AppInlineMessage(key: const Key('chat.offline'), message: l10n.chatOfflineNote, tone: AppStateTone.warning),
            ),
          Expanded(
            child: messages.isEmpty
                ? EmptyStateView(
                    key: const Key('chat.empty'),
                    icon: Icons.waving_hand_outlined,
                    title: l10n.chatNoMessages,
                    body: l10n.chatSayHello,
                  )
                : _MessageList(
                    messages: messages,
                    me: me,
                    group: widget.chat.kind != ChatKind.private,
                    blocked: blocked,
                    onRetry: (ChatMessage m) => unawaited(_run((ChatConversation c) => c.retry(m.id))),
                    onLongPress: (ChatMessage m) => unawaited(_messageActions(m)),
                    loadOlder: () => _conversation?.loadOlder() ?? Future<bool>.value(false),
                  ),
          ),
          if (_typing.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s24, AppSpacing.s4, AppSpacing.s24, AppSpacing.s4),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: OneLineText(
                  _typing.length == 1 ? l10n.chatTypingOne(_typing.first) : l10n.chatTypingMany(_typing.length),
                  key: const Key('chat.typing'),
                  style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
            ),
          if (info != null && !info.canWrite)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
                child: AppInlineMessage(key: const Key('chat.closed'), message: l10n.chatClosed, icon: Icons.lock_outline_rounded),
              ),
            )
          else
            AppChatComposer(
              controller: _text,
              hint: l10n.chatComposerHint,
              sendLabel: l10n.chatSend,
              onSend: _sendText,
              onPhoto: widget.chat.kind.photos ? () => unawaited(_sendPhoto()) : null,
              photoLabel: l10n.chatPhotoTitle,
              onLocation: widget.chat.kind.locationPin ? () => unawaited(_sendLocation()) : null,
              locationLabel: l10n.chatLocationSend,
              onChanged: (String _) => unawaited(_conversation?.keyStroke().catchError((Object _) {})),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(title),
        actions: <Widget>[
          IconButton(
            key: const Key('chat.info'),
            tooltip: l10n.chatInfoTitle,
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: info == null ? null : () => unawaited(_showInfo(info)),
          ),
        ],
      ),
      body: body,
    );
  }
}

class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({
    required this.messages,
    required this.me,
    required this.group,
    required this.blocked,
    required this.onRetry,
    required this.onLongPress,
    required this.loadOlder,
  });

  final List<ChatMessage> messages;
  final String me;
  final bool group;
  final Set<String> blocked;
  final ValueChanged<ChatMessage> onRetry;
  final ValueChanged<ChatMessage> onLongPress;
  final Future<bool> Function() loadOlder;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  bool _loading = false;
  bool _more = true;

  bool _onScroll(ScrollNotification n) {
    if (_more && !_loading && n.metrics.extentAfter < 200) {
      setState(() => _loading = true);
      unawaited(
        widget.loadOlder().then((bool more) {
          if (mounted) {
            setState(() {
              _more = more;
              _loading = false;
            });
          }
        }, onError: (Object _) {
          if (mounted) {
            setState(() => _loading = false);
          }
        }),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String lang = Localizations.localeOf(context).languageCode;
    final DateTime now = ref.watch(chatClockProvider)();
    final List<ChatMessage> list = widget.messages;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        key: const Key('chat.messages'),
        // Newest at the bottom, next to the composer.
        reverse: true,
        padding: const EdgeInsetsDirectional.symmetric(vertical: AppSpacing.s8),
        itemCount: list.length,
        itemBuilder: (BuildContext context, int i) {
          final ChatMessage m = list[list.length - 1 - i];
          final bool mine = m.mine(widget.me);
          final String time = chatTime(lang, m.createdAt, now);
          if (!mine && widget.blocked.contains(m.authorId)) {
            return AppChatBubble(
              key: Key('msg.${m.id}'),
              mine: false,
              time: time,
              child: Text(l10n.chatHiddenBlocked, style: TextStyle(color: context.colors.onSurfaceVariant)),
            );
          }
          return AppChatBubble(
            key: Key('msg.${m.id}'),
            mine: mine,
            time: time,
            author: widget.group && !mine && m.authorName.isNotEmpty ? m.authorName : null,
            status: mine
                ? switch (m.delivery) {
                    ChatDelivery.sending => AppChatStatus.sending,
                    ChatDelivery.sent => AppChatStatus.sent,
                    ChatDelivery.read => AppChatStatus.read,
                    ChatDelivery.failed => AppChatStatus.failed,
                  }
                : AppChatStatus.none,
            statusLabel: mine ? deliveryLabel(l10n, m.delivery) : null,
            onTap: mine && m.delivery == ChatDelivery.failed ? () => widget.onRetry(m) : null,
            onLongPress: mine || m.kind == ChatMessageKind.deleted ? null : () => widget.onLongPress(m),
            child: _content(context, l10n, m),
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context, AppLocalizations l10n, ChatMessage m) {
    switch (m.kind) {
      case ChatMessageKind.deleted:
        return Text(l10n.chatMessageRemoved, style: TextStyle(color: context.colors.onSurfaceVariant, fontStyle: FontStyle.italic));
      case ChatMessageKind.text:
        return Text(m.text);
      case ChatMessageKind.photo:
        final List<int>? local = m.localImage;
        final String? url = m.imageUrl;
        final Widget image = local != null
            ? Image.memory(Uint8List.fromList(local), fit: BoxFit.cover, semanticLabel: l10n.chatPhoto)
            : url != null
            ? Image.network(
                url,
                fit: BoxFit.cover,
                semanticLabel: l10n.chatPhoto,
                errorBuilder: (BuildContext context, Object e, StackTrace? s) => Icon(Icons.broken_image_outlined, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
              )
            : Icon(Icons.image_outlined, size: AppIconSize.xl, color: context.colors.onSurfaceVariant);
        return ClipRRect(
          borderRadius: AppRadii.control,
          child: SizedBox.square(dimension: AppSpacing.chatPhoto, child: image),
        );
      case ChatMessageKind.location:
        final double? lat = m.latitude;
        final double? lng = m.longitude;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.location_on_rounded, size: AppIconSize.md, color: context.colors.primary),
                const SizedBox(width: AppSpacing.s4),
                Flexible(child: OneLineText(l10n.chatLocation, style: context.text.titleSmall)),
              ],
            ),
            if (lat != null && lng != null)
              TextButton(
                key: Key('msg.${m.id}.map'),
                onPressed: () => unawaited(
                  launchUrl(
                    Uri.https('www.google.com', '/maps/search/', <String, String>{'api': '1', 'query': '$lat,$lng'}),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                child: OneLineText(l10n.chatOpenMap),
              ),
          ],
        );
    }
  }
}

class _SkeletonBubbles extends StatelessWidget {
  const _SkeletonBubbles();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: EdgeInsetsDirectional.all(AppSpacing.s16),
      child: Column(
        children: <Widget>[
          Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBox(width: AppSpacing.chatPhoto, height: AppSpacing.s48)),
          SizedBox(height: AppSpacing.s16),
          Align(alignment: AlignmentDirectional.centerEnd, child: SkeletonBox(width: AppSpacing.s64 * 2, height: AppSpacing.s40)),
          SizedBox(height: AppSpacing.s16),
          Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBox(width: AppSpacing.chatPhoto, height: AppSpacing.s64)),
        ],
      ),
    ),
  );
}
