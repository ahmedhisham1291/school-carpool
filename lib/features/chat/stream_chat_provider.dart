import 'dart:async';
import 'dart:typed_data';

import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';
import 'package:stream_chat_flutter_core/stream_chat_flutter_core.dart' as sc;
import 'package:stream_chat_persistence/stream_chat_persistence.dart' as scp;

/// Stream Chat through its Flutter SDK (stream_chat_flutter_core, the SDK's
/// UI-free layer) with Stream's offline storage (stream_chat_persistence):
/// chats and messages are kept on the phone, and a message written offline
/// waits in the SDK's send queue and goes out when the phone is back online.
///
/// The phone holds only the short-lived token from getChatToken; it never
/// creates a chat or adds a member (Stream channel-type permissions).
/// Stream's own logs are off: they could carry message text.
class StreamChatProvider implements ChatProvider {
  StreamChatProvider({this.persist = true});

  /// Offline storage on the phone (off in tests of this class).
  final bool persist;

  sc.StreamChatClient? _client;
  sc.StreamChannelListController? _list;
  String _me = '';
  final StreamController<ChatConnection> _connection = StreamController<ChatConnection>.broadcast();
  ChatConnection _state = ChatConnection.connecting;
  StreamSubscription<sc.ConnectionStatus>? _statusSub;

  sc.StreamChatClient get _c {
    final sc.StreamChatClient? c = _client;
    if (c == null) {
      throw const ChatFailure(ChatFailureKind.unavailable);
    }
    return c;
  }

  void _set(ChatConnection s) {
    _state = s;
    if (!_connection.isClosed) {
      _connection.add(s);
    }
  }

  @override
  Future<void> connect(ChatCredentials first, Future<String> Function() refresh) async {
    final sc.StreamChatClient? old = _client;
    if (old != null && _me == first.userId) {
      return;
    }
    if (old != null) {
      await _teardown();
    }
    final sc.StreamChatClient client = sc.StreamChatClient(first.apiKey, logLevel: sc.Level.OFF);
    if (persist) {
      client.chatPersistenceClient = scp.StreamChatPersistenceClient(logLevel: sc.Level.OFF);
    }
    _client = client;
    _me = first.userId;
    await _statusSub?.cancel();
    _statusSub = client.wsConnectionStatusStream.listen((sc.ConnectionStatus s) {
      _set(switch (s) {
        sc.ConnectionStatus.connected => ChatConnection.online,
        sc.ConnectionStatus.connecting => ChatConnection.connecting,
        sc.ConnectionStatus.disconnected => ChatConnection.offline,
      });
    });
    String firstToken = first.token;
    await client.connectUserWithProvider(sc.User(id: first.userId), (String _) async {
      // The first call uses the token we already have; later calls (expiry) ask Cloud Functions.
      if (firstToken.isNotEmpty) {
        final String t = firstToken;
        firstToken = '';
        return t;
      }
      return refresh();
    });
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
    await _connection.close();
  }

  Future<void> _teardown() async {
    final sc.StreamChatClient? client = _client;
    _client = null;
    _list?.dispose();
    _list = null;
    await _statusSub?.cancel();
    _statusSub = null;
    if (client != null) {
      // Sign-out: nothing of this parent's chats stays on the phone.
      await client.disconnectUser(flushChatPersistence: true);
      await client.dispose();
    }
    _me = '';
  }

  @override
  Stream<ChatConnection> get connection async* {
    yield _state;
    yield* _connection.stream;
  }

  sc.StreamChannelListController _controller() => _list ??= sc.StreamChannelListController(
    client: _c,
    filter: sc.Filter.in_('members', <Object>[_me]),
    presence: false,
    limit: 30,
  );

  @override
  Stream<List<ChatSummary>> chats() {
    final sc.StreamChannelListController controller = _controller();
    late final StreamController<List<ChatSummary>> out;
    void emit() {
      controller.value.when(
        (List<sc.Channel> items, int? nextPageKey, sc.StreamChatError? error) {
          if (error != null && items.isEmpty) {
            out.addError(const ChatFailure(ChatFailureKind.unavailable));
            return;
          }
          out.add(<ChatSummary>[
            for (final sc.Channel ch in items)
              if (_summary(ch) case final ChatSummary s) s,
          ]);
        },
        loading: () {},
        error: (sc.StreamChatError e) => out.addError(const ChatFailure(ChatFailureKind.unavailable)),
      );
    }

    out = StreamController<List<ChatSummary>>(
      onListen: () {
        controller.addListener(emit);
        emit();
        unawaited(controller.doInitialLoad());
      },
      onCancel: () async {
        controller.removeListener(emit);
        await out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> refreshChats() => _controller().refresh(resetValue: false);

  ChatSummary? _summary(sc.Channel ch) {
    final ChatRef? ref = ChatRef.parse(ch.type, ch.id);
    if (ref == null) {
      return null;
    }
    final sc.Message? last = ch.state?.lastMessage;
    final _Names names = _names(ch, ref.kind);
    return ChatSummary(
      ref: ref,
      nameAr: names.ar,
      nameEn: names.en,
      lastMessage: last == null ? null : _preview(last),
      lastAt: ch.lastMessageAt?.toUtc(),
      unread: ch.state?.unreadCount ?? 0,
      muted: ch.isMuted,
      frozen: ch.frozen,
      memberCount: ch.memberCount ?? 0,
      otherUserId: names.other,
    );
  }

  _Names _names(sc.Channel ch, ChatKind kind) {
    if (kind == ChatKind.private) {
      for (final sc.Member m in ch.state?.members ?? const <sc.Member>[]) {
        final sc.User? u = m.user;
        if (u != null && u.id != _me) {
          return _Names(u.name, '', u.id);
        }
      }
      return const _Names('', '', null);
    }
    final Object? ar = ch.extraData['name_ar'];
    final Object? en = ch.extraData['name_en'];
    return _Names(ar is String ? ar : '', en is String ? en : '', null);
  }

  ChatPreview _preview(sc.Message m) => ChatPreview(kind: _kindOf(m), text: m.text ?? '', mine: m.user?.id == _me);

  static ChatMessageKind _kindOf(sc.Message m) {
    if (m.isDeleted) {
      return ChatMessageKind.deleted;
    }
    for (final sc.Attachment a in m.attachments) {
      if (a.rawType == 'image') {
        return ChatMessageKind.photo;
      }
      if (a.rawType == kLocationAttachment) {
        return ChatMessageKind.location;
      }
    }
    return ChatMessageKind.text;
  }

  @override
  ChatConversation open(ChatRef ref) => _StreamConversation(_c.channel(ref.kind.type, id: ref.id), ref, _me);
}

/// Our location pin: an attachment with only a point (no live sharing).
const String kLocationAttachment = 'location';

class _Names {
  const _Names(this.ar, this.en, this.other);

  final String ar;
  final String en;
  final String? other;
}

class _StreamConversation implements ChatConversation {
  _StreamConversation(this._channel, this._ref, this._me) {
    _ready = _channel.watch().then((_) {});
  }

  final sc.Channel _channel;
  final ChatRef _ref;
  final String _me;
  late final Future<void> _ready;

  Stream<T> _after<T>(Stream<T> Function() make) async* {
    await _ready;
    yield* make();
  }

  ChatInfo _info() {
    final ChatKind kind = _ref.kind;
    String nameAr = '';
    String nameEn = '';
    String? other;
    if (kind == ChatKind.private) {
      for (final sc.Member m in _channel.state?.members ?? const <sc.Member>[]) {
        final sc.User? u = m.user;
        if (u != null && u.id != _me) {
          nameAr = u.name;
          other = u.id;
        }
      }
    } else {
      final Object? ar = _channel.extraData['name_ar'];
      final Object? en = _channel.extraData['name_en'];
      nameAr = ar is String ? ar : '';
      nameEn = en is String ? en : '';
    }
    final bool frozen = _channel.frozen;
    return ChatInfo(
      ref: _ref,
      nameAr: nameAr,
      nameEn: nameEn,
      muted: _channel.isMuted,
      frozen: frozen,
      memberCount: _channel.memberCount ?? 0,
      otherUserId: other,
      canWrite: !frozen && _channel.ownCapabilities.contains(sc.ChannelCapability.sendMessage),
    );
  }

  @override
  Stream<ChatInfo> get info => _after(() async* {
    yield _info();
    yield* _channel.state!.membersStream.map((_) => _info());
  });

  ChatDelivery _delivery(sc.Message m, List<sc.Read> reads) {
    if (m.state.isFailed) {
      return ChatDelivery.failed;
    }
    if (m.state.isOutgoing) {
      return ChatDelivery.sending;
    }
    if (_ref.kind.readReceipts && m.user?.id == _me) {
      final DateTime at = m.createdAt;
      for (final sc.Read r in reads) {
        if (r.user.id != _me && !r.lastRead.isBefore(at)) {
          return ChatDelivery.read;
        }
      }
    }
    return ChatDelivery.sent;
  }

  ChatMessage _map(sc.Message m, List<sc.Read> reads) {
    final ChatMessageKind kind = StreamChatProvider._kindOf(m);
    String? imageUrl;
    List<int>? local;
    double? lat;
    double? lng;
    for (final sc.Attachment a in m.attachments) {
      if (a.rawType == 'image') {
        imageUrl = a.imageUrl ?? a.assetUrl;
        local = a.file?.bytes;
      } else if (a.rawType == kLocationAttachment) {
        final Object? la = a.extraData['lat'];
        final Object? ln = a.extraData['lng'];
        lat = la is num ? la.toDouble() : null;
        lng = ln is num ? ln.toDouble() : null;
      }
    }
    return ChatMessage(
      id: m.id,
      authorId: m.user?.id ?? '',
      authorName: m.user?.name ?? '',
      kind: kind,
      createdAt: m.createdAt.toUtc(),
      text: kind == ChatMessageKind.deleted ? '' : (m.text ?? ''),
      imageUrl: imageUrl,
      localImage: local,
      latitude: lat,
      longitude: lng,
      delivery: _delivery(m, reads),
    );
  }

  List<ChatMessage> _messages() {
    final sc.ChannelClientState? s = _channel.state;
    if (s == null) {
      return const <ChatMessage>[];
    }
    final List<sc.Read> reads = s.read;
    return <ChatMessage>[
      for (final sc.Message m in s.messages)
        if (m.type != 'system' && m.parentId == null) _map(m, reads),
    ];
  }

  @override
  Stream<List<ChatMessage>> get messages => _after(() async* {
    yield _messages();
    final sc.ChannelClientState s = _channel.state!;
    yield* sc.StreamGroup.merge<Object>(<Stream<Object>>[s.messagesStream, s.readStream]).map((_) => _messages());
  });

  @override
  Stream<List<String>> get typing => _after(
    () => _channel.state!.typingEventsStream.map(
      (Map<sc.User, sc.Event> t) => <String>[
        for (final sc.User u in t.keys)
          if (u.id != _me) u.name,
      ],
    ),
  );

  @override
  Future<void> sendText(String text) async {
    await _ready;
    await _channel.sendMessage(sc.Message(text: text));
  }

  @override
  Future<void> sendPhoto(Uint8List jpeg) async {
    await _ready;
    // Prompt 12: chat photos are WebP on the phone (JPEG on the web).
    final String name = ImageSizing.isWebp(jpeg) ? 'photo.webp' : 'photo.jpg';
    final sc.AttachmentFile file = sc.AttachmentFile(size: jpeg.length, bytes: jpeg, name: name);
    await _channel.sendMessage(sc.Message(attachments: <sc.Attachment>[sc.Attachment(type: 'image', file: file)]));
  }

  @override
  Future<void> sendLocation(double latitude, double longitude) async {
    await _ready;
    await _channel.sendMessage(
      sc.Message(
        attachments: <sc.Attachment>[
          sc.Attachment(type: kLocationAttachment, extraData: <String, Object?>{'lat': latitude, 'lng': longitude}),
        ],
      ),
    );
  }

  @override
  Future<void> retry(String messageId) async {
    await _ready;
    for (final sc.Message m in _channel.state?.messages ?? const <sc.Message>[]) {
      if (m.id == messageId && m.state.isFailed) {
        await _channel.retryMessage(m);
      }
    }
  }

  @override
  Future<void> keyStroke() async {
    if (_channel.state != null) {
      await _channel.keyStroke();
    }
  }

  @override
  Future<void> markRead() async {
    await _ready;
    if ((_channel.state?.unreadCount ?? 0) > 0) {
      await _channel.markRead();
    }
  }

  @override
  Future<bool> loadOlder() async {
    await _ready;
    final List<sc.Message> current = _channel.state?.messages ?? const <sc.Message>[];
    if (current.isEmpty) {
      return false;
    }
    final sc.ChannelState s = await _channel.query(messagesPagination: sc.PaginationParams(limit: 30, lessThan: current.first.id));
    return (s.messages?.length ?? 0) >= 30;
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.stopWatching();
    } on Object {
      // Offline: nothing to stop.
    }
  }
}
