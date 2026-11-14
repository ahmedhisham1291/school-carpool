import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:school_carpool/features/chat/chat_backend.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/firestore_chat_mapping.dart';

/// Loads chat photos (Storage, members of the chat only).
abstract interface class ChatPhotoSource {
  /// The photo's bytes, or null when it is gone or may not be read.
  Future<Uint8List?> photo(String path);
}

/// Our own chat on Firestore (owner decision 14 Nov 2026; it replaced
/// Stream). Messages stay in our database; no outside account.
///
/// - The phone writes its own messages directly (strict rules), so sending
///   is instant and works with a weak signal: Firestore keeps a message
///   written offline and sends it when the phone is back online. A message
///   the rules refuse (removed from the chat, frozen chat, sending too
///   fast) shows as failed.
/// - Cloud Functions decide membership and keep the chat list (last
///   message, unread counters) and the push.
/// - Never a listener on all messages: see `ChatBackend`.
///
/// Message text, names and coordinates are never logged here.
class FirestoreChatProvider implements ChatProvider, ChatPhotoSource {
  FirestoreChatProvider(this._backend, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ChatBackend _backend;
  final DateTime Function() _clock;

  String _me = '';
  _Replay<ChatDocs>? _rows;
  final StreamController<ChatConnection> _connection = StreamController<ChatConnection>.broadcast();
  ChatConnection _state = ChatConnection.connecting;
  final Set<_FirestoreConversation> _open = <_FirestoreConversation>{};

  /// First names by chat and uid, kept while connected.
  final Map<String, Map<String, String>> _names = <String, Map<String, String>>{};

  /// The last photos shown, so scrolling back does not download again.
  final LinkedHashMap<String, Uint8List> _photos = LinkedHashMap<String, Uint8List>();
  static const int _photoCacheSize = 40;

  void _set(ChatConnection s) {
    if (_state != s && !_connection.isClosed) {
      _state = s;
      _connection.add(s);
    }
  }

  @override
  Future<void> connect(ChatCredentials first, Future<String> Function() refresh) async {
    if (_rows != null && _me == first.userId) {
      return;
    }
    await _teardown();
    _me = first.userId;
    final String uid = _me;
    _rows = _Replay<ChatDocs>(
      () => _backend.watchSummaries(uid),
      // Answers from the phone's cache only: no connection right now.
      onValue: (ChatDocs docs) => _set(docs.fromCache ? ChatConnection.offline : ChatConnection.online),
    );
  }

  @override
  Future<void> disconnect() async {
    await _teardown();
    await _connection.close();
  }

  Future<void> _teardown() async {
    for (final _FirestoreConversation c in _open.toList()) {
      await c.dispose();
    }
    _open.clear();
    await _rows?.close();
    _rows = null;
    _names.clear();
    _photos.clear();
    _me = '';
  }

  @override
  Stream<ChatConnection> get connection => Stream<ChatConnection>.multi((MultiStreamController<ChatConnection> c) {
    c.add(_state);
    final StreamSubscription<ChatConnection> sub = _connection.stream.listen(c.add, onDone: c.close);
    c.onCancel = sub.cancel;
  });

  _Replay<ChatDocs> get _connected {
    final _Replay<ChatDocs>? rows = _rows;
    if (rows == null) {
      throw const ChatFailure(ChatFailureKind.unavailable);
    }
    return rows;
  }

  @override
  Stream<List<ChatSummary>> chats() {
    final _Replay<ChatDocs> rows = _connected;
    final String me = _me;
    final Map<String, StreamSubscription<ChatDoc?>> headSubs = <String, StreamSubscription<ChatDoc?>>{};
    final Map<String, ChatDoc> heads = <String, ChatDoc>{};
    List<ChatDoc> current = const <ChatDoc>[];
    bool loaded = false;
    StreamSubscription<ChatDocs>? rowsSub;
    late final StreamController<List<ChatSummary>> out;

    void emit() {
      if (loaded && !out.isClosed) {
        out.add(summariesOf(current, heads, me));
      }
    }

    void onRows(ChatDocs docs) {
      current = docs.docs;
      loaded = true;
      // School and area groups: last message and unread come from the
      // chat's head (one small document each), not from a row per member.
      final Set<String> groups = <String>{
        for (final ChatDoc d in current)
          if (ChatRef.fromCid(d.id)?.kind.small == false) d.id,
      };
      for (final String cid in headSubs.keys.toList()) {
        if (!groups.contains(cid)) {
          unawaited(headSubs.remove(cid)?.cancel());
          heads.remove(cid);
        }
      }
      for (final String cid in groups) {
        headSubs[cid] ??= _backend.watchHead(cid).listen((ChatDoc? head) {
          if (head == null) {
            heads.remove(cid);
          } else {
            heads[cid] = head;
          }
          emit();
        }, onError: (Object _) {});
      }
      emit();
    }

    out = StreamController<List<ChatSummary>>(
      onListen: () {
        rowsSub = rows.stream.listen(onRows, onError: (Object e) => out.addError(ChatFailure.from(e)));
      },
      onCancel: () async {
        await rowsSub?.cancel();
        for (final StreamSubscription<ChatDoc?> s in headSubs.values) {
          await s.cancel();
        }
        headSubs.clear();
        await out.close();
      },
    );
    return out.stream;
  }

  /// The listeners are live: there is nothing to fetch again.
  @override
  Future<void> refreshChats() async {}

  @override
  ChatConversation open(ChatRef ref) {
    final _FirestoreConversation c = _FirestoreConversation(this, _connected, ref, _me);
    _open.add(c);
    return c;
  }

  @override
  Future<Uint8List?> photo(String path) async {
    final Uint8List? cached = _photos.remove(path);
    if (cached != null) {
      _photos[path] = cached;
      return cached;
    }
    final Uint8List? bytes = await _backend.downloadPhoto(path);
    if (bytes != null) {
      _remember(path, bytes);
    }
    return bytes;
  }

  void _remember(String path, Uint8List bytes) {
    _photos[path] = bytes;
    while (_photos.length > _photoCacheSize) {
      _photos.remove(_photos.keys.first);
    }
  }
}

/// A message this phone is sending: shown at once, "sending" until the
/// server has it, "failed" (tap to retry) when the upload or the write fails.
class _Outgoing {
  _Outgoing(this.message, this.fields, {this.photo});

  final ChatMessage message;
  final Map<String, Object?> fields;

  /// A photo still to upload (kept for a retry).
  final Uint8List? photo;
  bool uploaded = false;
  bool failed = false;
}

class _FirestoreConversation implements ChatConversation {
  _FirestoreConversation(this._p, this._rows, this._ref, this._me);

  final FirestoreChatProvider _p;
  final _Replay<ChatDocs> _rows;
  final ChatRef _ref;
  final String _me;

  static const Duration _typingShown = Duration(seconds: 6);
  static const Duration _typingEvery = Duration(seconds: 4);
  static const Duration _groupMarkEvery = Duration(seconds: 5);
  static const Duration _rowGrace = Duration(seconds: 3);

  ChatBackend get _backend => _p._backend;
  String get _cid => _ref.cid;
  bool get _small => _ref.kind.small;

  final StreamController<ChatInfo> _info = StreamController<ChatInfo>.broadcast();
  final StreamController<List<ChatMessage>> _messages = StreamController<List<ChatMessage>>.broadcast();
  final StreamController<List<String>> _typing = StreamController<List<String>>.broadcast();
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  bool _started = false;
  bool _disposed = false;

  // Info.
  ChatDoc? _row;
  bool _rowsLoaded = false;
  bool _rowsFromCache = false;
  Timer? _missingTimer;
  ChatDoc? _head;
  Object? _infoError;

  // Messages.
  final Map<String, ChatDoc> _known = <String, ChatDoc>{};
  final Map<String, _Outgoing> _outgoing = <String, _Outgoing>{};
  final Map<String, DateTime> _localTimes = <String, DateTime>{};
  final Set<String> _nameAsked = <String>{};
  bool _messagesLoaded = false;
  Object? _messagesError;

  // Read marks and typing (small chats).
  final Map<String, DateTime> _readAt = <String, DateTime>{};
  final Map<String, DateTime?> _typingSeen = <String, DateTime?>{};
  final Map<String, DateTime> _typingUntil = <String, DateTime>{};
  bool _readsLoaded = false;
  Timer? _typingTimer;
  DateTime? _lastKeyStroke;

  // Marking read.
  bool _marking = false;
  DateTime? _lastMark;
  Timer? _markTimer;

  Map<String, String> get _names => _p._names[_cid] ??= <String, String>{};

  /// Starts the listeners on first use.
  void _start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _subs
      ..add(
        _rows.stream.listen((ChatDocs docs) {
          _rowsLoaded = true;
          _rowsFromCache = docs.fromCache;
          _row = null;
          for (final ChatDoc d in docs.docs) {
            if (d.id == _cid) {
              _row = d;
            }
          }
          _emitInfo();
          _maybeMarkRead();
        }, onError: _infoFailed),
      )
      ..add(
        _backend.watchHead(_cid).listen((ChatDoc? head) {
          _head = head;
          _emitInfo();
          _maybeMarkRead();
        }, onError: _infoFailed),
      )
      ..add(
        _backend.watchLatest(_cid, ChatBackend.pageSize).listen((ChatDocs docs) {
          mergeWindow(_known, docs.docs, ChatBackend.pageSize);
          _messagesLoaded = true;
          _messagesError = null;
          _emitMessages();
        }, onError: (Object e) {
          _messagesError = ChatFailure.from(e);
          _add(_messages, null, _messagesError);
        }),
      );
    if (_small) {
      _subs.add(_backend.watchReads(_cid).listen(_onReads, onError: (Object _) {}));
    }
  }

  void _infoFailed(Object e) {
    _infoError = ChatFailure.from(e);
    _add(_info, null, _infoError);
  }

  void _add<T>(StreamController<T> c, T? value, [Object? error]) {
    if (c.isClosed) {
      return;
    }
    if (error != null) {
      c.addError(error);
    } else if (value != null) {
      c.add(value);
    }
  }

  /// The stream of [c], starting with what is known now.
  Stream<T> _from<T extends Object>(StreamController<T> c, T? Function() now, Object? Function() error) =>
      Stream<T>.multi((MultiStreamController<T> out) {
        _start();
        final Object? e = error();
        final T? value = now();
        if (e != null) {
          out.addError(e);
        } else if (value != null) {
          out.add(value);
        }
        final StreamSubscription<T> sub = c.stream.listen(out.add, onError: out.addError, onDone: out.close);
        out.onCancel = sub.cancel;
      });

  // -------------------------------------------------------------------------
  // Info
  // -------------------------------------------------------------------------

  ChatInfo? _infoNow() {
    final ChatDoc? row = _row;
    return row == null ? null : infoOf(_ref, row, _head, _me);
  }

  void _emitInfo() {
    if (!_rowsLoaded) {
      return;
    }
    final ChatInfo? info = _infoNow();
    if (info != null) {
      _missingTimer?.cancel();
      _missingTimer = null;
      _infoError = null;
      _add(_info, info);
      return;
    }
    // No open row. From the phone's cache alone that proves nothing; and a
    // chat opened a moment ago (a request just accepted) gets its row a
    // moment later. Only then: not (or no longer) a member of this chat.
    if (_rowsFromCache || _missingTimer != null || _disposed) {
      return;
    }
    _missingTimer = Timer(_rowGrace, () {
      _missingTimer = null;
      if (_row == null && !_disposed) {
        _infoError = const ChatFailure(ChatFailureKind.notMember);
        _add(_info, null, _infoError);
      }
    });
  }

  @override
  Stream<ChatInfo> get info => _from(_info, _infoNow, () => _infoError);

  // -------------------------------------------------------------------------
  // Messages
  // -------------------------------------------------------------------------

  DateTime _timeOf(ChatDoc d) => d.time('createdAt') ?? (_localTimes[d.id] ??= _clock());

  DateTime _clock() => _p._clock().toUtc();

  String _nameOf(String uid) {
    if (uid.isEmpty || uid == _me || uid == kSystemSender) {
      return '';
    }
    final String? known = _names[uid];
    if (known != null) {
      return known;
    }
    if (_nameAsked.add(uid)) {
      // One small read per author, once (Firestore's cache keeps it).
      unawaited(
        _backend.member(_cid, uid).then((ChatDoc? m) {
          _names[uid] = m?.text('firstName') ?? '';
          _emitMessages();
          _emitTyping();
        }, onError: (Object _) {}),
      );
    }
    return '';
  }

  bool _readByOther(DateTime at) {
    if (!_small) {
      return false;
    }
    for (final MapEntry<String, DateTime> e in _readAt.entries) {
      if (e.key != _me && !e.value.isBefore(at)) {
        return true;
      }
    }
    return false;
  }

  List<ChatMessage>? _messagesNow() {
    if (!_messagesLoaded) {
      return null;
    }
    final List<ChatMessage> out = <ChatMessage>[];
    for (final ChatDoc d in _known.values) {
      if (!d.pending) {
        // The server has it: no longer "sending".
        _outgoing.remove(d.id);
      }
      final DateTime at = _timeOf(d);
      final ChatMessage m = messageOf(d, at: at, me: _me, authorName: _nameOf(d.text('senderUid')), readByOther: _readByOther(at));
      // Our own photo while it is still being sent: show the bytes we have.
      final List<int>? local = _outgoing[d.id]?.message.localImage;
      out.add(
        local == null
            ? m
            : ChatMessage(
                id: m.id,
                authorId: m.authorId,
                authorName: m.authorName,
                kind: m.kind,
                createdAt: m.createdAt,
                photoPath: m.photoPath,
                localImage: local,
                delivery: m.delivery,
              ),
      );
    }
    for (final _Outgoing o in _outgoing.values) {
      if (!_known.containsKey(o.message.id)) {
        out.add(o.message.withDelivery(o.failed ? ChatDelivery.failed : ChatDelivery.sending));
      }
    }
    out.sort((ChatMessage a, ChatMessage b) {
      final int byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return out;
  }

  void _emitMessages() => _add(_messages, _messagesNow());

  @override
  Stream<List<ChatMessage>> get messages => _from(_messages, _messagesNow, () => _messagesError);

  @override
  Future<bool> loadOlder() async {
    DateTime? oldest;
    for (final ChatDoc d in _known.values) {
      final DateTime? t = d.time('createdAt');
      if (t != null && (oldest == null || t.isBefore(oldest))) {
        oldest = t;
      }
    }
    if (oldest == null || _disposed) {
      return false;
    }
    final List<ChatDoc> page = await _backend.older(_cid, oldest, ChatBackend.pageSize);
    for (final ChatDoc d in page) {
      _known.putIfAbsent(d.id, () => d);
    }
    _emitMessages();
    return page.length >= ChatBackend.pageSize;
  }

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  _Outgoing _queue(ChatMessageKind kind, Map<String, Object?> fields, {String text = '', Uint8List? photo, String? photoPath, double? lat, double? lng, String? id}) {
    final String messageId = id ?? _backend.newMessageId(_cid);
    final _Outgoing o = _Outgoing(
      ChatMessage(
        id: messageId,
        authorId: _me,
        authorName: '',
        kind: kind,
        createdAt: _localTimes[messageId] = _clock(),
        text: text,
        photoPath: photoPath,
        localImage: photo,
        latitude: lat,
        longitude: lng,
        delivery: ChatDelivery.sending,
      ),
      <String, Object?>{'senderUid': _me, ...fields},
      photo: photo,
    );
    _outgoing[messageId] = o;
    return o;
  }

  /// Uploads the photo when there is one, then writes the message. Never
  /// throws: a failure shows on the bubble (tap to retry).
  Future<void> _deliver(_Outgoing o) async {
    o.failed = false;
    _emitMessages();
    final Uint8List? photo = o.photo;
    final String? path = o.message.photoPath;
    if (photo != null && path != null && !o.uploaded) {
      try {
        await _backend.uploadPhoto(path, photo, photoContentType(photo));
        o.uploaded = true;
        _p._remember(path, photo);
      } on Object {
        o.failed = true;
        _emitMessages();
        return;
      }
    }
    // Not awaited: offline, the write waits on the phone and so would we.
    unawaited(
      _backend.createMessage(_cid, o.message.id, o.fields).then((_) {
        _outgoing.remove(o.message.id);
        _emitMessages();
      }, onError: (Object _) {
        o.failed = true;
        _emitMessages();
      }),
    );
    _emitMessages();
  }

  @override
  Future<void> sendText(String text) async {
    _stopTyping();
    for (final String part in splitText(text.trim())) {
      await _deliver(_queue(ChatMessageKind.text, <String, Object?>{'kind': 'text', 'text': part}, text: part));
    }
  }

  @override
  Future<void> sendPhoto(Uint8List jpeg) async {
    if (!_ref.kind.photos) {
      throw const ChatFailure(ChatFailureKind.notMember);
    }
    final String id = _backend.newMessageId(_cid);
    final String path = photoPathFor(_cid, _me, id, jpeg);
    await _deliver(_queue(ChatMessageKind.photo, <String, Object?>{'kind': 'photo', 'photoPath': path}, photo: jpeg, photoPath: path, id: id));
  }

  @override
  Future<void> sendLocation(double latitude, double longitude) async {
    if (!_ref.kind.locationPin) {
      throw const ChatFailure(ChatFailureKind.notMember);
    }
    await _deliver(
      _queue(ChatMessageKind.location, <String, Object?>{'kind': 'location', 'lat': latitude, 'lng': longitude}, lat: latitude, lng: longitude),
    );
  }

  @override
  Future<void> retry(String messageId) async {
    final _Outgoing? o = _outgoing[messageId];
    if (o != null && o.failed) {
      await _deliver(o);
    }
  }

  // -------------------------------------------------------------------------
  // Typing and read marks
  // -------------------------------------------------------------------------

  @override
  Future<void> keyStroke() async {
    if (!_small || _disposed) {
      return;
    }
    final DateTime now = _clock();
    final DateTime? last = _lastKeyStroke;
    if (last != null && now.difference(last) < _typingEvery) {
      return;
    }
    _lastKeyStroke = now;
    await _backend.setTyping(_cid, _me, typing: true);
  }

  void _stopTyping() {
    if (_lastKeyStroke != null) {
      _lastKeyStroke = null;
      unawaited(_backend.setTyping(_cid, _me, typing: false).catchError((Object _) {}));
    }
  }

  void _onReads(ChatDocs docs) {
    final DateTime now = _clock();
    for (final ChatDoc d in docs.docs) {
      final DateTime? read = d.time('readAt');
      if (read != null) {
        _readAt[d.id] = read;
      }
      if (d.id == _me) {
        continue;
      }
      final DateTime? typing = d.time('typingAt');
      if (typing == null) {
        _typingUntil.remove(d.id);
      } else if (_readsLoaded && typing != _typingSeen[d.id]) {
        // A new typing time since we opened the chat: typing now.
        _typingUntil[d.id] = now.add(_typingShown);
      }
      _typingSeen[d.id] = typing;
    }
    _readsLoaded = true;
    _emitMessages();
    _emitTyping();
  }

  List<String> _typingNow() {
    final DateTime now = _clock();
    _typingUntil.removeWhere((String _, DateTime until) => !until.isAfter(now));
    return <String>[
      for (final String uid in _typingUntil.keys)
        if (_nameOf(uid).isNotEmpty) _nameOf(uid),
    ];
  }

  void _emitTyping() {
    _add(_typing, _typingNow());
    _typingTimer?.cancel();
    _typingTimer = null;
    if (_typingUntil.isNotEmpty && !_disposed) {
      // The line goes away by itself when no new typing time comes.
      _typingTimer = Timer(_typingShown, _emitTyping);
    }
  }

  @override
  Stream<List<String>> get typing => _from(_typing, _typingNow, () => null);

  @override
  Future<void> markRead() async => _maybeMarkRead();

  /// Marks the chat read while it is open and something is unread. Small
  /// chats: at once (the others see "read"). School and area groups: at
  /// most every few seconds (one write, however many messages came).
  void _maybeMarkRead() {
    final ChatDoc? row = _row;
    if (row == null || _disposed || _marking || !_started) {
      return;
    }
    final int seq = _head?.number('seq') ?? row.number('readSeq');
    final bool unread = _small ? row.number('unread') > 0 : seq > row.number('readSeq');
    if (!unread) {
      return;
    }
    final DateTime now = _clock();
    final DateTime? last = _lastMark;
    if (!_small && last != null && now.difference(last) < _groupMarkEvery) {
      _markTimer ??= Timer(_groupMarkEvery, () {
        _markTimer = null;
        _maybeMarkRead();
      });
      return;
    }
    _marking = true;
    _lastMark = now;
    unawaited(
      _backend.markRead(_me, _cid, readSeq: seq, small: _small).then((_) {}, onError: (Object _) {}).whenComplete(() {
        _marking = false;
        _maybeMarkRead();
      }),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _stopTyping();
    _disposed = true;
    _p._open.remove(this);
    _typingTimer?.cancel();
    _markTimer?.cancel();
    _missingTimer?.cancel();
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _info.close();
    await _messages.close();
    await _typing.close();
  }
}

/// One listener on [_source] shared by everyone who listens to [stream];
/// each new listener first gets the last value. The source is listened to
/// only while somebody listens.
class _Replay<T extends Object> {
  _Replay(this._source, {this.onValue});

  final Stream<T> Function() _source;
  final void Function(T value)? onValue;
  final Set<MultiStreamController<T>> _listeners = <MultiStreamController<T>>{};
  StreamSubscription<T>? _sub;
  T? _last;
  Object? _error;
  bool _closed = false;

  Stream<T> get stream => Stream<T>.multi((MultiStreamController<T> c) {
    if (_closed) {
      unawaited(c.close());
      return;
    }
    _listeners.add(c);
    final Object? error = _error;
    final T? last = _last;
    if (error != null) {
      c.addError(error);
    } else if (last != null) {
      c.add(last);
    }
    _sub ??= _source().listen(
      (T value) {
        _last = value;
        _error = null;
        onValue?.call(value);
        for (final MultiStreamController<T> l in _listeners.toList()) {
          l.add(value);
        }
      },
      onError: (Object e) {
        _error = e;
        for (final MultiStreamController<T> l in _listeners.toList()) {
          l.addError(e);
        }
      },
    );
    c.onCancel = () async {
      _listeners.remove(c);
      if (_listeners.isEmpty) {
        final StreamSubscription<T>? sub = _sub;
        _sub = null;
        _last = null;
        _error = null;
        await sub?.cancel();
      }
    };
  });

  Future<void> close() async {
    _closed = true;
    final StreamSubscription<T>? sub = _sub;
    _sub = null;
    await sub?.cancel();
    for (final MultiStreamController<T> l in _listeners.toList()) {
      await l.close();
    }
    _listeners.clear();
  }
}
