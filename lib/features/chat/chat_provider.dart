import 'dart:async';
import 'dart:typed_data';

import 'package:school_carpool/features/chat/chat_models.dart';

/// The chat service as screens see it. Two implementations:
/// - FirestoreChatProvider (firestore_chat_provider.dart): our own chat on
///   Firestore, with Firestore's offline cache and write queue;
/// - FakeChatProvider (below): in memory, for widget tests.
///
/// Nothing here creates a chat or adds a member: Cloud Functions do.
abstract interface class ChatProvider {
  /// Connects as [first.userId]. [refresh] is unused by our own chat (it
  /// needs no token); kept so a provider with tokens fits the same shape.
  Future<void> connect(ChatCredentials first, Future<String> Function() refresh);

  /// Disconnects and clears what was kept on the phone (sign-out).
  Future<void> disconnect();

  Stream<ChatConnection> get connection;

  /// Every chat the parent is in, newest activity first.
  Stream<List<ChatSummary>> chats();

  Future<void> refreshChats();

  ChatConversation open(ChatRef ref);
}

/// One open chat.
abstract interface class ChatConversation {
  Stream<ChatInfo> get info;

  /// Oldest first.
  Stream<List<ChatMessage>> get messages;

  /// First names of the other parents typing now.
  Stream<List<String>> get typing;

  /// Sends now, or keeps it on the phone and sends when back online.
  Future<void> sendText(String text);

  /// A WebP or JPEG with no EXIF (the photo picker strips it before this).
  Future<void> sendPhoto(Uint8List jpeg);

  Future<void> sendLocation(double latitude, double longitude);

  Future<void> retry(String messageId);

  Future<void> keyStroke();

  Future<void> markRead();

  /// False when there is nothing older.
  Future<bool> loadOlder();

  Future<void> dispose();
}

/// In-memory chat with a few fake parents (widget tests).
class FakeChatProvider implements ChatProvider {
  FakeChatProvider({List<ChatSummary>? chats, Map<ChatRef, List<ChatMessage>>? messages, this.me = 'uid-1', DateTime? now})
    : _chats = chats ?? <ChatSummary>[],
      _messages = messages ?? <ChatRef, List<ChatMessage>>{},
      _now = now ?? DateTime.utc(2026, 11, 16, 10);

  final String me;
  final DateTime _now;
  List<ChatSummary> _chats;
  final Map<ChatRef, List<ChatMessage>> _messages;
  final StreamController<int> _changes = StreamController<int>.broadcast();
  final StreamController<ChatConnection> _connection = StreamController<ChatConnection>.broadcast();
  ChatConnection _state = ChatConnection.online;

  /// Set to fail [chats] (error state tests).
  Object? chatsError;

  /// Typing names per chat (tests).
  final Map<ChatRef, List<String>> typingNow = <ChatRef, List<String>>{};

  /// Every call, in order (tests).
  final List<String> calls = <String>[];

  /// When true, sends stay "sending" (offline queue tests).
  bool offline = false;

  int _next = 1;

  void setConnection(ChatConnection value) {
    _state = value;
    _connection.add(value);
  }

  void setSummaries(List<ChatSummary> value) {
    _chats = value;
    _changes.add(0);
  }

  List<ChatMessage> messagesOf(ChatRef ref) => List<ChatMessage>.of(_messages[ref] ?? const <ChatMessage>[]);

  @override
  Future<void> connect(ChatCredentials first, Future<String> Function() refresh) async {
    calls.add('connect:${first.userId}');
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
  }

  @override
  Stream<ChatConnection> get connection async* {
    yield _state;
    yield* _connection.stream;
  }

  @override
  Stream<List<ChatSummary>> chats() async* {
    final Object? error = chatsError;
    if (error != null) {
      throw error;
    }
    yield List<ChatSummary>.of(_chats);
    await for (final int _ in _changes.stream) {
      yield List<ChatSummary>.of(_chats);
    }
  }

  @override
  Future<void> refreshChats() async {
    calls.add('refreshChats');
    _changes.add(0);
  }

  @override
  ChatConversation open(ChatRef ref) {
    calls.add('open:${ref.cid}');
    return _FakeConversation(this, ref);
  }

  ChatSummary? _summary(ChatRef ref) {
    for (final ChatSummary s in _chats) {
      if (s.ref == ref) {
        return s;
      }
    }
    return null;
  }

  void _add(ChatRef ref, ChatMessage m) {
    (_messages[ref] ??= <ChatMessage>[]).add(m);
    _changes.add(0);
  }

  void _replace(ChatRef ref, ChatMessage m) {
    final List<ChatMessage> list = _messages[ref] ?? <ChatMessage>[];
    final int i = list.indexWhere((ChatMessage x) => x.id == m.id);
    if (i >= 0) {
      list[i] = m;
      _changes.add(0);
    }
  }

  ChatMessage _new(ChatMessageKind kind, {String text = '', List<int>? image, double? lat, double? lng}) => ChatMessage(
    id: 'fake-${_next++}',
    authorId: me,
    authorName: '',
    kind: kind,
    createdAt: _now,
    text: text,
    localImage: image,
    latitude: lat,
    longitude: lng,
    delivery: offline ? ChatDelivery.sending : ChatDelivery.sent,
  );

  /// Sends what waited (offline queue tests).
  void backOnline() {
    offline = false;
    for (final List<ChatMessage> list in _messages.values) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].delivery == ChatDelivery.sending) {
          list[i] = list[i].withDelivery(ChatDelivery.sent);
        }
      }
    }
    _changes.add(0);
  }

  /// Closes the streams (call from tearDown).
  Future<void> close() async {
    await _changes.close();
    await _connection.close();
  }
}

class _FakeConversation implements ChatConversation {
  _FakeConversation(this._p, this._ref);

  final FakeChatProvider _p;
  final ChatRef _ref;

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    await for (final int _ in _p._changes.stream) {
      yield read();
    }
  }

  @override
  Stream<ChatInfo> get info => _watch(() {
    final ChatSummary? s = _p._summary(_ref);
    return ChatInfo(
      ref: _ref,
      nameAr: s?.nameAr ?? '',
      nameEn: s?.nameEn ?? '',
      muted: s?.muted ?? false,
      frozen: s?.frozen ?? false,
      memberCount: s?.memberCount ?? 2,
      otherUserId: s?.otherUserId,
      canWrite: !(s?.frozen ?? false),
    );
  });

  @override
  Stream<List<ChatMessage>> get messages => _watch(() => _p.messagesOf(_ref));

  @override
  Stream<List<String>> get typing => _watch(() => List<String>.of(_p.typingNow[_ref] ?? const <String>[]));

  @override
  Future<void> sendText(String text) async {
    _p.calls.add('sendText:${_ref.cid}');
    _p._add(_ref, _p._new(ChatMessageKind.text, text: text));
  }

  @override
  Future<void> sendPhoto(Uint8List jpeg) async {
    _p.calls.add('sendPhoto:${_ref.cid}:${jpeg.length}');
    _p._add(_ref, _p._new(ChatMessageKind.photo, image: jpeg));
  }

  @override
  Future<void> sendLocation(double latitude, double longitude) async {
    _p.calls.add('sendLocation:${_ref.cid}');
    _p._add(_ref, _p._new(ChatMessageKind.location, lat: latitude, lng: longitude));
  }

  @override
  Future<void> retry(String messageId) async {
    _p.calls.add('retry:$messageId');
    for (final ChatMessage m in _p.messagesOf(_ref)) {
      if (m.id == messageId) {
        _p._replace(_ref, m.withDelivery(ChatDelivery.sent));
      }
    }
  }

  @override
  Future<void> keyStroke() async {
    _p.calls.add('keyStroke');
  }

  @override
  Future<void> markRead() async {
    _p.calls.add('markRead:${_ref.cid}');
  }

  @override
  Future<bool> loadOlder() async => false;

  @override
  Future<void> dispose() async {}
}
