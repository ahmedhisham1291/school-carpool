// Our own chat on Firestore (improvement B): the provider behind the
// ChatProvider interface, with the data layer faked in memory (no Firebase)
// and the pure mapping from chat documents to what the screens show.
// A hung test fails within a minute instead of using up the CI job.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/chat/chat_backend.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/firestore_chat_mapping.dart';
import 'package:school_carpool/features/chat/firestore_chat_provider.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 16, 10);

const String _carpool = 'cp_carpool:c-k1';

/// Its photo folder in Storage: "/" in place of ":".
const String _carpoolDir = 'cp_carpool/c-k1';
const String _school = 'cp_school:s-nile';
const String _private = 'cp_private:dm-abc';

/// The chat documents in memory, with what the phone may do to them. Reads
/// and writes are counted, so the tests can say what a screen costs.
class MemoryChatBackend implements ChatBackend {
  final Map<String, Map<String, Object?>> rows = <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> heads = <String, Map<String, Object?>>{};
  final Map<String, List<ChatDoc>> messages = <String, List<ChatDoc>>{};
  final Map<String, Map<String, Map<String, Object?>>> reads = <String, Map<String, Map<String, Object?>>>{};
  final Map<String, String> names = <String, String>{};
  final Map<String, Uint8List> photos = <String, Uint8List>{};
  final StreamController<int> _changes = StreamController<int>.broadcast();
  final List<String> calls = <String>[];

  /// Answers come from the phone's cache only (no connection).
  bool fromCache = false;

  /// The next message writes are refused (the rules), or wait (offline).
  bool refuseWrites = false;
  bool holdWrites = false;
  bool failUploads = false;
  final List<Completer<void>> _held = <Completer<void>>[];
  int _nextId = 1;

  void changed() => _changes.add(0);

  Stream<T> _watch<T>(String what, T Function() read) => Stream<T>.multi((MultiStreamController<T> c) {
    calls.add('listen:$what');
    c.add(read());
    final StreamSubscription<int> sub = _changes.stream.listen((int _) => c.add(read()));
    c.onCancel = () {
      calls.add('cancel:$what');
      return sub.cancel();
    };
  });

  int listening(String what) => calls.where((String c) => c == 'listen:$what').length - calls.where((String c) => c == 'cancel:$what').length;

  @override
  Stream<ChatDocs> watchSummaries(String uid) => _watch(
    'rows',
    () => ChatDocs(<ChatDoc>[for (final MapEntry<String, Map<String, Object?>> e in rows.entries) ChatDoc(e.key, e.value)], fromCache: fromCache),
  );

  @override
  Stream<ChatDoc?> watchHead(String cid) => _watch('head:$cid', () {
    final Map<String, Object?>? h = heads[cid];
    return h == null ? null : ChatDoc(cid, h);
  });

  List<ChatDoc> _newestFirst(String cid) => (messages[cid] ?? <ChatDoc>[]).reversed.toList();

  @override
  Stream<ChatDocs> watchLatest(String cid, int limit) => _watch('latest:$cid', () => ChatDocs(_newestFirst(cid).take(limit).toList()));

  @override
  Future<List<ChatDoc>> older(String cid, DateTime before, int limit) async {
    calls.add('older:$cid');
    return <ChatDoc>[
      for (final ChatDoc d in _newestFirst(cid))
        if (d.time('createdAt')?.isBefore(before) ?? false) d,
    ].take(limit).toList();
  }

  @override
  Stream<ChatDocs> watchReads(String cid) => _watch(
    'reads:$cid',
    () => ChatDocs(<ChatDoc>[for (final MapEntry<String, Map<String, Object?>> e in (reads[cid] ?? <String, Map<String, Object?>>{}).entries) ChatDoc(e.key, e.value)]),
  );

  @override
  Future<ChatDoc?> member(String cid, String uid) async {
    calls.add('member:$uid');
    final String? name = names[uid];
    return name == null ? null : ChatDoc(uid, <String, Object?>{'firstName': name});
  }

  @override
  String newMessageId(String cid) => 'localmsg${_nextId++}'.padRight(12, '0');

  @override
  Future<void> createMessage(String cid, String id, Map<String, Object?> fields) async {
    calls.add('create:$id');
    if (refuseWrites) {
      throw const ChatFailure(ChatFailureKind.notMember);
    }
    // As Firestore does: the write shows at once, without a server time.
    (messages[cid] ??= <ChatDoc>[]).add(ChatDoc(id, <String, Object?>{...fields}, pending: true));
    changed();
    if (holdWrites) {
      final Completer<void> c = Completer<void>();
      _held.add(c);
      await c.future;
    }
    serverTook(cid, id, _t0.add(Duration(minutes: _nextId)));
  }

  /// The server took the write: it has a time and is no longer pending.
  void serverTook(String cid, String id, DateTime at) {
    final List<ChatDoc> list = messages[cid] ?? <ChatDoc>[];
    final int i = list.indexWhere((ChatDoc d) => d.id == id);
    if (i >= 0) {
      list[i] = ChatDoc(id, <String, Object?>{...list[i].data, 'createdAt': at});
      changed();
    }
  }

  void backOnline() {
    holdWrites = false;
    for (final Completer<void> c in _held) {
      c.complete();
    }
    _held.clear();
  }

  @override
  Future<void> markRead(String uid, String cid, {required int readSeq, required bool small}) async {
    calls.add('markRead:$cid:$readSeq:$small');
    rows[cid] = <String, Object?>{...?rows[cid], 'unread': 0, 'readSeq': readSeq};
    if (small) {
      (reads[cid] ??= <String, Map<String, Object?>>{})[uid] = <String, Object?>{'readAt': _t0.add(const Duration(hours: 1))};
    }
    changed();
  }

  @override
  Future<void> setTyping(String cid, String uid, {required bool typing}) async {
    calls.add('typing:$typing');
  }

  @override
  Future<void> uploadPhoto(String path, Uint8List bytes, String contentType) async {
    calls.add('upload:$path:$contentType');
    if (failUploads) {
      throw const ChatFailure(ChatFailureKind.photoFailed);
    }
    photos[path] = bytes;
  }

  @override
  Future<Uint8List?> downloadPhoto(String path) async {
    calls.add('download:$path');
    return photos[path];
  }

  void addMessage(String cid, String id, String from, {String text = 'hi', required DateTime at, String kind = 'text', Map<String, Object?> extra = const <String, Object?>{}}) {
    (messages[cid] ??= <ChatDoc>[]).add(ChatDoc(id, <String, Object?>{'senderUid': from, 'kind': kind, 'text': text, 'createdAt': at, ...extra}));
  }

  Future<void> close() => _changes.close();
}

Map<String, Object?> _row({String kind = 'carpool', int unread = 0, int readSeq = 0, Object? muted, bool frozen = false, Map<String, Object?> extra = const <String, Object?>{}}) => <String, Object?>{
  'kind': kind,
  'nameAr': 'مدرسة النيل · 07:30',
  'nameEn': 'Nile School · 07:30',
  'otherUid': null,
  'otherName': '',
  'muted': muted,
  'frozen': frozen,
  'open': true,
  'memberCount': 3,
  'unread': unread,
  'readSeq': readSeq,
  ...extra,
};

/// A WebP header (RIFF....WEBP) and a JPEG start: enough to tell them apart.
final Uint8List _webp = Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 1, 2]);
final Uint8List _jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 1, 2]);

Future<FirestoreChatProvider> _connect(MemoryChatBackend backend, {DateTime Function()? clock}) async {
  final FirestoreChatProvider p = FirestoreChatProvider(backend, clock: clock ?? () => _t0);
  await p.connect(const ChatCredentials(provider: 'firestore', userId: 'me'), () async => '');
  return p;
}

/// Lets stream events and futures settle.
Future<void> _settle() => pumpEventQueue();

void main() {
  late MemoryChatBackend backend;

  setUp(() {
    backend = MemoryChatBackend();
    addTearDown(backend.close);
  });

  group('mapping', () {
    test('a small chat row: name, preview, unread and members from the row itself', () {
      final ChatSummary s = summaryOf(
        ChatDoc(_carpool, _row(unread: 2, extra: <String, Object?>{'lastAt': _t0, 'last': <String, Object?>{'kind': 'text', 'senderUid': 'hoda', 'text': 'On my way'}})),
        null,
        'me',
      )!;
      expect(s.ref, const ChatRef(ChatKind.carpool, 'c-k1'));
      expect(s.title('en'), 'Nile School · 07:30');
      expect(s.unread, 2);
      expect(s.memberCount, 3);
      expect(s.lastAt, _t0);
      expect(s.lastMessage?.text, 'On my way');
      expect(s.lastMessage?.mine, isFalse);
      expect(s.muted, isFalse);
    });

    test('a private chat row is named after the other parent', () {
      final ChatSummary s = summaryOf(ChatDoc(_private, _row(kind: 'private', extra: <String, Object?>{'otherUid': 'uid-hoda', 'otherName': 'Hoda'})), null, 'me')!;
      expect(s.nameAr, 'Hoda');
      expect(s.nameEn, '');
      expect(s.otherUserId, 'uid-hoda');
    });

    test('a school group counts unread from the head: its counter minus what the parent read', () {
      final ChatDoc row = ChatDoc(_school, _row(kind: 'school', unread: 9, readSeq: 4));
      final ChatDoc head = ChatDoc(_school, <String, Object?>{
        'nameAr': 'مدرسة النيل',
        'nameEn': 'Nile School',
        'memberCount': 120,
        'seq': 7,
        'lastAt': _t0,
        'last': <String, Object?>{'kind': 'text', 'senderUid': 'me', 'text': 'Thanks'},
      });
      final ChatSummary s = summaryOf(row, head, 'me')!;
      expect(s.unread, 3);
      expect(s.memberCount, 120);
      expect(s.lastMessage?.mine, isTrue);
      // Large groups count as muted until the parent chooses.
      expect(s.muted, isTrue);
      expect(summaryOf(ChatDoc(_school, _row(kind: 'school', muted: false)), head, 'me')!.muted, isFalse);
      // Without the head yet: nothing unread, never a negative number.
      expect(summaryOf(row, null, 'me')!.unread, 0);
      expect(summaryOf(ChatDoc(_school, _row(kind: 'school', readSeq: 99)), head, 'me')!.unread, 0);
    });

    test('rows that are not ours are skipped; newest activity first', () {
      final List<ChatSummary> list = summariesOf(
        <ChatDoc>[
          ChatDoc(_carpool, _row(extra: <String, Object?>{'lastAt': _t0.subtract(const Duration(hours: 1))})),
          ChatDoc('messaging:general', _row()),
          ChatDoc(_private, _row(kind: 'private', extra: <String, Object?>{'lastAt': _t0})),
          ChatDoc(_school, _row(kind: 'school')),
        ],
        const <String, ChatDoc>{},
        'me',
      );
      expect(<String>[for (final ChatSummary s in list) s.ref.cid], <String>[_private, _carpool, _school]);
    });

    test('previews: photo, location and removed carry no text of their own', () {
      expect(previewOf(const <String, Object?>{'kind': 'photo', 'senderUid': 'a', 'text': ''}, 'me')?.kind, ChatMessageKind.photo);
      expect(previewOf(const <String, Object?>{'kind': 'location', 'senderUid': 'a', 'text': ''}, 'me')?.kind, ChatMessageKind.location);
      expect(previewOf(const <String, Object?>{'kind': 'deleted', 'senderUid': 'a', 'text': ''}, 'me')?.kind, ChatMessageKind.deleted);
      expect(previewOf(null, 'me'), isNull);
    });

    test('messages: pending is "sending", read needs another member\'s mark, system messages have no author', () {
      ChatMessage of(ChatDoc d, {bool read = false}) => messageOf(d, at: _t0, me: 'me', authorName: 'Hoda', readByOther: read);
      const Map<String, Object?> mine = <String, Object?>{'senderUid': 'me', 'kind': 'text', 'text': 'hi'};
      expect(of(const ChatDoc('m1', mine, pending: true)).delivery, ChatDelivery.sending);
      expect(of(const ChatDoc('m1', mine)).delivery, ChatDelivery.sent);
      expect(of(const ChatDoc('m1', mine), read: true).delivery, ChatDelivery.read);
      final ChatMessage theirs = of(const ChatDoc('m2', <String, Object?>{'senderUid': 'hoda', 'kind': 'location', 'lat': 30.05, 'lng': 31}), read: true);
      expect(theirs.delivery, ChatDelivery.sent);
      expect(theirs.kind, ChatMessageKind.location);
      expect(theirs.latitude, 30.05);
      expect(theirs.longitude, 31.0);
      expect(theirs.authorName, 'Hoda');
      final ChatMessage system = of(const ChatDoc('m3', <String, Object?>{'senderUid': kSystemSender, 'kind': 'text', 'text': 'Badr: at the gate'}));
      expect(system.authorId, '');
      expect(system.authorName, '');
      expect(system.text, 'Badr: at the gate');
      final ChatMessage photo = of(const ChatDoc('m4', <String, Object?>{'senderUid': 'hoda', 'kind': 'photo', 'photoPath': 'chatPhotos/x/hoda/m4.webp'}));
      expect(photo.photoPath, 'chatPhotos/x/hoda/m4.webp');
    });

    test('the window of newest messages: removed ones go, older ones that slid out stay', () {
      ChatDoc m(int i) => ChatDoc('m$i', <String, Object?>{'createdAt': _t0.add(Duration(minutes: i))});
      final Map<String, ChatDoc> known = <String, ChatDoc>{};
      mergeWindow(known, <ChatDoc>[m(3), m(2), m(1)], 3);
      expect(known.keys, <String>['m3', 'm2', 'm1']);
      // A new message: m1 slides out of the window of 3 but stays loaded.
      mergeWindow(known, <ChatDoc>[m(4), m(3), m(2)], 3);
      expect(known.keys.toSet(), <String>{'m1', 'm2', 'm3', 'm4'});
      // An admin removed m3: the window reaches back to m1 again.
      mergeWindow(known, <ChatDoc>[m(4), m(2), m(1)], 3);
      expect(known.keys.toSet(), <String>{'m1', 'm2', 'm4'});
      // A refused write of our own (no server time) disappears.
      known['mine'] = const ChatDoc('mine', <String, Object?>{}, pending: true);
      mergeWindow(known, <ChatDoc>[m(4), m(2), m(1)], 3);
      expect(known.containsKey('mine'), isFalse);
      // Fewer than a full window: it is the whole chat.
      mergeWindow(known, <ChatDoc>[m(4)], 3);
      expect(known.keys, <String>['m4']);
      mergeWindow(known, const <ChatDoc>[], 3);
      expect(known, isEmpty);
    });

    test('long text is split at the limit, never inside an emoji; photo paths follow the rules', () {
      expect(splitText(''), isEmpty);
      expect(splitText('hello'), <String>['hello']);
      expect(splitText('abcdef', max: 4), <String>['abcd', 'ef']);
      final List<String> parts = splitText('abc\u{1F600}def', max: 4);
      expect(parts.join(), 'abc\u{1F600}def');
      expect(parts.first, 'abc');
      expect(splitText('x' * (kMaxMessageText + 1)), hasLength(2));
      expect(photoPathFor(_carpool, 'me', 'msg1', _webp), 'chatPhotos/$_carpoolDir/me/msg1.webp');
      expect(photoPathFor(_carpool, 'me', 'msg1', _jpeg), 'chatPhotos/$_carpoolDir/me/msg1.jpg');
      expect(photoContentType(_webp), 'image/webp');
      expect(photoContentType(_jpeg), 'image/jpeg');
    });

    test('small chats are private and carpool chats only', () {
      expect(ChatKind.carpool.small && ChatKind.private.small, isTrue);
      expect(ChatKind.school.small || ChatKind.area.small, isFalse);
      expect(ChatKind.school.photos || ChatKind.school.locationPin || ChatKind.area.readReceipts, isFalse);
    });
  });

  group('chat list', () {
    test('one listener on the rows, one head per school or area group, none on messages', () async {
      backend.rows[_carpool] = _row(unread: 1, extra: <String, Object?>{'lastAt': _t0});
      backend.rows[_school] = _row(kind: 'school', readSeq: 2);
      backend.heads[_school] = <String, Object?>{'nameAr': 'مدرسة', 'nameEn': 'School', 'memberCount': 80, 'seq': 5, 'lastAt': _t0.subtract(const Duration(days: 1))};
      final FirestoreChatProvider p = await _connect(backend);
      addTearDown(p.disconnect);
      final List<List<ChatSummary>> seen = <List<ChatSummary>>[];
      final StreamSubscription<List<ChatSummary>> sub = p.chats().listen(seen.add);
      await _settle();
      expect(<String>[for (final ChatSummary s in seen.last) s.ref.cid], <String>[_carpool, _school]);
      expect(seen.last.last.unread, 3);
      expect(seen.last.last.title('en'), 'School');
      expect(backend.listening('rows'), 1);
      expect(backend.listening('head:$_school'), 1);
      expect(backend.calls.where((String c) => c.startsWith('listen:head:$_carpool')), isEmpty);
      expect(backend.calls.where((String c) => c.startsWith('listen:latest') || c.startsWith('listen:reads')), isEmpty);

      // A new message in the school group: the head changes, the list follows.
      backend.heads[_school] = <String, Object?>{...backend.heads[_school]!, 'seq': 6, 'lastAt': _t0.add(const Duration(minutes: 1))};
      backend.changed();
      await _settle();
      expect(seen.last.first.ref.cid, _school);
      expect(seen.last.first.unread, 4);

      // Removed from the school group: its row and its head listener go.
      backend.rows.remove(_school);
      backend.changed();
      await _settle();
      expect(seen.last, hasLength(1));
      expect(backend.listening('head:$_school'), 0);

      await sub.cancel();
      await _settle();
      expect(backend.listening('rows'), 0);
    });

    test('offline (answers from the cache) and back online', () async {
      backend.fromCache = true;
      backend.rows[_carpool] = _row();
      final FirestoreChatProvider p = await _connect(backend);
      addTearDown(p.disconnect);
      final List<ChatConnection> states = <ChatConnection>[];
      final StreamSubscription<ChatConnection> sub = p.connection.listen(states.add);
      final StreamSubscription<List<ChatSummary>> list = p.chats().listen((List<ChatSummary> _) {});
      await _settle();
      expect(states, <ChatConnection>[ChatConnection.connecting, ChatConnection.offline]);
      backend.fromCache = false;
      backend.changed();
      await _settle();
      expect(states.last, ChatConnection.online);
      await sub.cancel();
      await list.cancel();
    });

    test('not connected: no chats', () {
      final FirestoreChatProvider p = FirestoreChatProvider(backend);
      expect(p.chats, throwsA(isA<ChatFailure>()));
    });
  });

  group('conversation', () {
    const ChatRef carpool = ChatRef(ChatKind.carpool, 'c-k1');
    const ChatRef school = ChatRef(ChatKind.school, 's-nile');

    Future<(FirestoreChatProvider, ChatConversation, List<List<ChatMessage>>)> open(ChatRef ref, {DateTime Function()? clock}) async {
      final FirestoreChatProvider p = await _connect(backend, clock: clock);
      addTearDown(p.disconnect);
      final ChatConversation c = p.open(ref);
      final List<List<ChatMessage>> seen = <List<ChatMessage>>[];
      final StreamSubscription<List<ChatMessage>> sub = c.messages.listen(seen.add);
      addTearDown(() async {
        await sub.cancel();
      });
      await _settle();
      return (p, c, seen);
    }

    test('listens to the newest page only; older pages are fetched, oldest first on screen', () async {
      backend.rows[_carpool] = _row();
      backend.names['hoda'] = 'Hoda';
      for (int i = 1; i <= 45; i++) {
        backend.addMessage(_carpool, 'm${i.toString().padLeft(2, '0')}', i.isEven ? 'hoda' : 'me', text: 'msg $i', at: _t0.add(Duration(minutes: i)));
      }
      final (_, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      expect(seen.last, hasLength(ChatBackend.pageSize));
      expect(seen.last.first.id, 'm16');
      expect(seen.last.last.id, 'm45');
      expect(seen.last.last.text, 'msg 45');
      // First names come from the member documents: one read per author.
      expect(seen.last.firstWhere((ChatMessage m) => m.authorId == 'hoda').authorName, 'Hoda');
      expect(backend.calls.where((String x) => x == 'member:hoda'), hasLength(1));
      expect(backend.listening('latest:$_carpool'), 1);

      expect(await c.loadOlder(), isFalse, reason: '15 left: fewer than a page, so nothing more after it');
      await _settle();
      expect(seen.last, hasLength(45));
      expect(seen.last.first.id, 'm01');
      expect(backend.calls.where((String x) => x == 'older:$_carpool'), hasLength(1));
    });

    test('sending text: shown at once as sending, sent when the server took it', () async {
      backend.rows[_carpool] = _row();
      backend.holdWrites = true;
      final (_, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      expect(seen.last, isEmpty);
      await c.sendText('  On my way  ');
      await _settle();
      expect(seen.last.single.text, 'On my way');
      expect(seen.last.single.delivery, ChatDelivery.sending);
      expect(seen.last.single.mine('me'), isTrue);
      // Offline: the write waits on the phone; back online it goes.
      backend.backOnline();
      await _settle();
      expect(seen.last.single.delivery, ChatDelivery.sent);
      expect(backend.messages[_carpool]!.single.data, containsPair('senderUid', 'me'));
      expect(backend.messages[_carpool]!.single.data.keys.toSet(), <String>{'senderUid', 'kind', 'text', 'createdAt'});
    });

    test('a write the rules refuse shows as failed; a tap retries it', () async {
      backend.rows[_carpool] = _row();
      backend.refuseWrites = true;
      final (_, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      await c.sendText('hello');
      await _settle();
      expect(seen.last.single.delivery, ChatDelivery.failed);
      final String id = seen.last.single.id;
      backend.refuseWrites = false;
      await c.retry(id);
      await _settle();
      expect(seen.last.single.id, id);
      expect(seen.last.single.delivery, ChatDelivery.sent);
      expect(backend.calls.where((String x) => x == 'create:$id'), hasLength(2));
    });

    test('a photo is uploaded to the sender\'s own folder first, then the message names it', () async {
      backend.rows[_carpool] = _row();
      final (FirestoreChatProvider p, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      await c.sendPhoto(_webp);
      await _settle();
      final ChatMessage m = seen.last.single;
      expect(m.kind, ChatMessageKind.photo);
      expect(m.photoPath, 'chatPhotos/$_carpoolDir/me/${m.id}.webp');
      expect(backend.photos.keys.single, m.photoPath);
      final int upload = backend.calls.indexWhere((String x) => x.startsWith('upload:'));
      expect(backend.calls[upload], endsWith(':image/webp'));
      expect(upload, lessThan(backend.calls.indexOf('create:${m.id}')));
      expect(backend.messages[_carpool]!.single.data.keys.toSet(), <String>{'senderUid', 'kind', 'photoPath', 'createdAt'});
      // Our own photo is not downloaded again.
      expect(await p.photo(m.photoPath!), _webp);
      expect(backend.calls.where((String x) => x.startsWith('download:')), isEmpty);
    });

    test('a failed upload writes no message; retry uploads and sends', () async {
      backend.rows[_carpool] = _row();
      backend.failUploads = true;
      final (_, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      await c.sendPhoto(_jpeg);
      await _settle();
      expect(seen.last.single.delivery, ChatDelivery.failed);
      expect(seen.last.single.localImage, isNotNull);
      expect(backend.messages[_carpool], isNull);
      backend.failUploads = false;
      await c.retry(seen.last.single.id);
      await _settle();
      expect(seen.last.single.delivery, ChatDelivery.sent);
      expect(seen.last.single.photoPath, endsWith('.jpg'));
    });

    test('a location pin carries the point and nothing else; neither pins nor photos in a school group', () async {
      backend.rows[_carpool] = _row();
      backend.rows[_school] = _row(kind: 'school');
      final (FirestoreChatProvider p, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      await c.sendLocation(30.05, 31.25);
      await _settle();
      expect(seen.last.single.kind, ChatMessageKind.location);
      expect(backend.messages[_carpool]!.single.data.keys.toSet(), <String>{'senderUid', 'kind', 'lat', 'lng', 'createdAt'});
      final ChatConversation group = p.open(school);
      await expectLater(group.sendLocation(30, 31), throwsA(isA<ChatFailure>()));
      await expectLater(group.sendPhoto(_webp), throwsA(isA<ChatFailure>()));
      expect(backend.messages[_school], isNull);
    });

    test('a message removed by an admin disappears; photos of others are fetched once', () async {
      backend.rows[_carpool] = _row();
      backend.photos['chatPhotos/$_carpoolDir/hoda/m2.webp'] = _webp;
      backend.addMessage(_carpool, 'm1', 'hoda', at: _t0.add(const Duration(minutes: 1)));
      backend.addMessage(_carpool, 'm2', 'hoda', text: '', kind: 'photo', at: _t0.add(const Duration(minutes: 2)), extra: <String, Object?>{'photoPath': 'chatPhotos/$_carpoolDir/hoda/m2.webp'});
      final (FirestoreChatProvider p, _, List<List<ChatMessage>> seen) = await open(carpool);
      expect(seen.last, hasLength(2));
      expect(await p.photo('chatPhotos/$_carpoolDir/hoda/m2.webp'), _webp);
      expect(await p.photo('chatPhotos/$_carpoolDir/hoda/m2.webp'), _webp);
      expect(backend.calls.where((String x) => x.startsWith('download:')), hasLength(1));
      expect(await p.photo('chatPhotos/$_carpoolDir/hoda/gone.webp'), isNull);
      backend.messages[_carpool]!.removeWhere((ChatDoc d) => d.id == 'm1');
      backend.changed();
      await _settle();
      expect(<String>[for (final ChatMessage m in seen.last) m.id], <String>['m2']);
    });

    test('small chat: opening it marks it read (unread to zero and the read mark); "read" shows when another member read', () async {
      backend.rows[_carpool] = _row(unread: 2);
      backend.addMessage(_carpool, 'm1', 'me', at: _t0.add(const Duration(minutes: 1)));
      final (_, ChatConversation c, List<List<ChatMessage>> seen) = await open(carpool);
      await c.markRead();
      await _settle();
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), <String>['markRead:$_carpool:0:true']);
      expect(backend.rows[_carpool]!['unread'], 0);
      expect(seen.last.single.delivery, ChatDelivery.sent);
      // Nothing unread: no second write however often the screen asks.
      await c.markRead();
      await _settle();
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), hasLength(1));
      // Hoda reads it.
      (backend.reads[_carpool] ??= <String, Map<String, Object?>>{})['hoda'] = <String, Object?>{'readAt': _t0.add(const Duration(minutes: 5))};
      backend.changed();
      await _settle();
      expect(seen.last.single.delivery, ChatDelivery.read);
      // A new message while the chat is open is marked read by itself.
      backend.rows[_carpool] = <String, Object?>{...backend.rows[_carpool]!, 'unread': 1};
      backend.changed();
      await _settle();
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), hasLength(2));
    });

    // Real, short timings (ChatTimings): no test here waits on seconds, and
    // none runs under testWidgets' fake clock (awaiting a subscription's
    // cancel there never completes).
    test('school group: read up to the head\'s counter, without read marks, at most once per interval', () async {
      backend.rows[_school] = _row(kind: 'school', readSeq: 2);
      backend.heads[_school] = <String, Object?>{'nameAr': 'مدرسة', 'nameEn': 'School', 'memberCount': 80, 'seq': 5};
      final FirestoreChatProvider p = FirestoreChatProvider(backend, timings: const ChatTimings(groupMarkEvery: Duration(milliseconds: 600)));
      addTearDown(p.disconnect);
      await p.connect(const ChatCredentials(provider: 'firestore', userId: 'me'), () async => '');
      final ChatConversation c = p.open(school);
      final StreamSubscription<List<ChatMessage>> sub = c.messages.listen((List<ChatMessage> _) {});
      addTearDown(() async {
        await sub.cancel();
      });
      await _settle();
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), <String>['markRead:$_school:5:false']);
      expect(backend.calls.where((String x) => x.startsWith('listen:reads')), isEmpty);
      // Three more messages at once: one more write, after the interval.
      for (int seq = 6; seq <= 8; seq++) {
        backend.heads[_school] = <String, Object?>{...backend.heads[_school]!, 'seq': seq};
        backend.changed();
      }
      await _settle();
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(backend.calls.where((String x) => x.startsWith('markRead:')).last, 'markRead:$_school:8:false');
      expect(backend.calls.where((String x) => x.startsWith('markRead:')), hasLength(2));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('typing: at most one write every few seconds, cleared on send, never in a school group', () async {
      DateTime now = _t0;
      backend.rows[_carpool] = _row();
      backend.rows[_school] = _row(kind: 'school');
      final (FirestoreChatProvider p, ChatConversation c, _) = await open(carpool, clock: () => now);
      await c.keyStroke();
      await c.keyStroke();
      now = now.add(const Duration(seconds: 1));
      await c.keyStroke();
      expect(backend.calls.where((String x) => x == 'typing:true'), hasLength(1));
      now = now.add(const Duration(seconds: 5));
      await c.keyStroke();
      expect(backend.calls.where((String x) => x == 'typing:true'), hasLength(2));
      await c.sendText('done');
      await _settle();
      expect(backend.calls.where((String x) => x == 'typing:false'), hasLength(1));
      final ChatConversation group = p.open(school);
      await group.keyStroke();
      expect(backend.calls.where((String x) => x == 'typing:true'), hasLength(2));
    });

    test('the typing line shows another member\'s new typing time and goes away by itself', () async {
      backend.rows[_carpool] = _row();
      backend.names['hoda'] = 'Hoda';
      // An old typing time from before we opened the chat is not "typing now".
      backend.reads[_carpool] = <String, Map<String, Object?>>{
        'hoda': <String, Object?>{'typingAt': _t0.subtract(const Duration(hours: 1))},
      };
      final FirestoreChatProvider p = FirestoreChatProvider(backend, timings: const ChatTimings(typingShown: Duration(milliseconds: 600)));
      addTearDown(p.disconnect);
      await p.connect(const ChatCredentials(provider: 'firestore', userId: 'me'), () async => '');
      final ChatConversation c = p.open(carpool);
      final List<List<String>> typing = <List<String>>[];
      final StreamSubscription<List<String>> sub = c.typing.listen(typing.add);
      addTearDown(() async {
        await sub.cancel();
      });
      await _settle();
      expect(typing.last, isEmpty);
      backend.reads[_carpool]!['hoda'] = <String, Object?>{'typingAt': _t0.add(const Duration(seconds: 1))};
      backend.reads[_carpool]!['me'] = <String, Object?>{'typingAt': _t0.add(const Duration(seconds: 1))};
      backend.changed();
      await _settle();
      expect(typing.last, <String>['Hoda']);
      // Twice the interval and more: a timer that fires a moment early looks once more.
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect(typing.last, isEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('info: name, members and frozen; a chat the parent is not in says so after a moment', () async {
      backend.rows[_private] = _row(kind: 'private', frozen: true, extra: <String, Object?>{'otherUid': 'uid-hoda', 'otherName': 'Hoda', 'memberCount': 2});
      final FirestoreChatProvider p = FirestoreChatProvider(backend, timings: const ChatTimings(rowGrace: Duration(milliseconds: 600)));
      addTearDown(p.disconnect);
      await p.connect(const ChatCredentials(provider: 'firestore', userId: 'me'), () async => '');
      final List<ChatInfo> infos = <ChatInfo>[];
      final StreamSubscription<ChatInfo> sub = p.open(const ChatRef(ChatKind.private, 'dm-abc')).info.listen(infos.add);
      addTearDown(() async {
        await sub.cancel();
      });
      await _settle();
      expect(infos.last.title('ar'), 'Hoda');
      expect(infos.last.otherUserId, 'uid-hoda');
      expect(infos.last.memberCount, 2);
      expect(infos.last.frozen, isTrue);
      expect(infos.last.canWrite, isFalse);

      final List<Object> errors = <Object>[];
      final StreamSubscription<ChatInfo> other = p.open(carpool).info.listen((ChatInfo _) {}, onError: errors.add);
      addTearDown(() async {
        await other.cancel();
      });
      await _settle();
      expect(errors, isEmpty, reason: 'a chat opened a moment ago gets its row a moment later');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(errors.single, isA<ChatFailure>().having((ChatFailure f) => f.kind, 'kind', ChatFailureKind.notMember));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('disposing a conversation stops its listeners; the chat list listener stays', () async {
      backend.rows[_carpool] = _row();
      final (FirestoreChatProvider p, ChatConversation c, _) = await open(carpool);
      final StreamSubscription<List<ChatSummary>> list = p.chats().listen((List<ChatSummary> _) {});
      await _settle();
      expect(backend.listening('latest:$_carpool'), 1);
      expect(backend.listening('reads:$_carpool'), 1);
      await c.dispose();
      await _settle();
      expect(backend.listening('latest:$_carpool'), 0);
      expect(backend.listening('reads:$_carpool'), 0);
      expect(backend.listening('head:$_carpool'), 0);
      expect(backend.listening('rows'), 1);
      await list.cancel();
    });
  });
}
