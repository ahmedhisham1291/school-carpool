import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Where our own chat keeps its data, as `FirestoreChatProvider` needs it:
/// a few narrow reads and writes, so the provider's logic is tested with an
/// in-memory backend and no Firebase.
///
/// COST (docs/COSTS.md): there is never a listener on all messages. One
/// query for the parent's chat list rows, one document per school or area
/// group in that list, and, only while a chat is open, its newest
/// [ChatBackend.pageSize] messages (older ones are fetched a page at a
/// time, not listened to) and, in small chats, the read marks.
abstract interface class ChatBackend {
  /// Messages listened to in the open chat, and fetched per older page.
  static const int pageSize = 30;

  /// The parent's open chat list rows (userChats/`uid`/summaries).
  Stream<ChatDocs> watchSummaries(String uid);

  /// The head of one chat (chats/`cid`); null when it does not exist.
  Stream<ChatDoc?> watchHead(String cid);

  /// The newest [limit] messages, newest first.
  Stream<ChatDocs> watchLatest(String cid, int limit);

  /// Up to [limit] messages older than [before], newest first (one read).
  Future<List<ChatDoc>> older(String cid, DateTime before, int limit);

  /// Read and typing times of the members (small chats only).
  Stream<ChatDocs> watchReads(String cid);

  /// One member's document (first name); null when there is none.
  Future<ChatDoc?> member(String cid, String uid);

  String newMessageId(String cid);

  /// Creates the message with the server's time. Completes when the server
  /// took it (offline: the write waits on the phone and the future with
  /// it); fails when the rules refuse it.
  Future<void> createMessage(String cid, String id, Map<String, Object?> fields);

  /// Unread back to zero on the parent's own row; in small chats also the
  /// read mark the other members see.
  Future<void> markRead(String uid, String cid, {required int readSeq, required bool small});

  Future<void> setTyping(String cid, String uid, {required bool typing});

  Future<void> uploadPhoto(String path, Uint8List bytes, String contentType);

  /// The photo's bytes, or null when it is gone or may not be read.
  Future<Uint8List?> downloadPhoto(String path);

  /// True when a file is already at [path] (an upload whose answer was lost).
  Future<bool> photoExists(String path);
}

/// One document: its ID, its fields (times as UTC [DateTime]) and whether a
/// write of this phone has not reached the server yet.
class ChatDoc {
  const ChatDoc(this.id, this.data, {this.pending = false});

  final String id;
  final Map<String, Object?> data;
  final bool pending;

  String text(String key) {
    final Object? v = data[key];
    return v is String ? v : '';
  }

  int number(String key) {
    final Object? v = data[key];
    return v is num ? v.toInt() : 0;
  }

  DateTime? time(String key) {
    final Object? v = data[key];
    return v is DateTime ? v : null;
  }
}

/// A query result. [fromCache]: not confirmed by the server (offline).
class ChatDocs {
  const ChatDocs(this.docs, {this.fromCache = false});

  final List<ChatDoc> docs;
  final bool fromCache;
}

/// Firestore and Storage (firestore.rules "Own chat", storage.rules
/// "chatPhotos"). Firestore's own offline cache keeps the chats readable
/// and queues messages written without a connection.
class FirestoreChatBackend implements ChatBackend {
  FirestoreChatBackend(this._db, this._storage);

  final FirebaseFirestore _db;

  /// Looked up on first use, so tests that never touch a photo need no Storage.
  final FirebaseStorage Function() _storage;

  /// Largest photo the app downloads (the rules cap uploads at 3 MB).
  static const int _maxPhotoBytes = 3 * 1024 * 1024;

  DocumentReference<Map<String, dynamic>> _chat(String cid) => _db.collection('chats').doc(cid);

  CollectionReference<Map<String, dynamic>> _messages(String cid) => _chat(cid).collection('messages');

  DocumentReference<Map<String, dynamic>> _summary(String uid, String cid) =>
      _db.collection('userChats').doc(uid).collection('summaries').doc(cid);

  static Object? _plain(Object? v) {
    if (v is Timestamp) {
      return v.toDate().toUtc();
    }
    if (v is Map<Object?, Object?>) {
      return <String, Object?>{for (final MapEntry<Object?, Object?> e in v.entries) '${e.key}': _plain(e.value)};
    }
    return v;
  }

  static ChatDoc _doc(String id, Map<String, dynamic>? data, {required bool pending}) => ChatDoc(
    id,
    <String, Object?>{for (final MapEntry<String, dynamic> e in (data ?? const <String, dynamic>{}).entries) e.key: _plain(e.value)},
    pending: pending,
  );

  static ChatDocs _docs(QuerySnapshot<Map<String, dynamic>> s) => ChatDocs(<ChatDoc>[
    for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) _doc(d.id, d.data(), pending: d.metadata.hasPendingWrites),
  ], fromCache: s.metadata.isFromCache);

  @override
  Stream<ChatDocs> watchSummaries(String uid) => _db
      .collection('userChats')
      .doc(uid)
      .collection('summaries')
      // The rules show open rows only (a removed or cut-off parent has none).
      .where('open', isEqualTo: true)
      .limit(100)
      // Metadata changes too: that is how "back online" is noticed.
      .snapshots(includeMetadataChanges: true)
      .map(_docs);

  @override
  Stream<ChatDoc?> watchHead(String cid) => _chat(cid).snapshots().map(
    (DocumentSnapshot<Map<String, dynamic>> s) => s.exists ? _doc(s.id, s.data(), pending: false) : null,
  );

  @override
  Stream<ChatDocs> watchLatest(String cid, int limit) => _messages(cid).orderBy('createdAt', descending: true).limit(limit).snapshots().map(_docs);

  @override
  Future<List<ChatDoc>> older(String cid, DateTime before, int limit) async {
    final QuerySnapshot<Map<String, dynamic>> s = await _messages(cid)
        .orderBy('createdAt', descending: true)
        .startAfter(<Object>[Timestamp.fromDate(before)])
        .limit(limit)
        .get();
    return _docs(s).docs;
  }

  @override
  Stream<ChatDocs> watchReads(String cid) => _chat(cid).collection('reads').limit(50).snapshots().map(_docs);

  @override
  Future<ChatDoc?> member(String cid, String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> s = await _chat(cid).collection('chatMembers').doc(uid).get();
    return s.exists ? _doc(s.id, s.data(), pending: false) : null;
  }

  @override
  String newMessageId(String cid) => _messages(cid).doc().id;

  @override
  Future<void> createMessage(String cid, String id, Map<String, Object?> fields) =>
      _messages(cid).doc(id).set(<String, Object?>{...fields, 'createdAt': FieldValue.serverTimestamp()});

  @override
  Future<void> markRead(String uid, String cid, {required int readSeq, required bool small}) async {
    final WriteBatch batch = _db.batch()
      ..update(_summary(uid, cid), <String, Object?>{'unread': 0, 'readSeq': readSeq, 'readAt': FieldValue.serverTimestamp()});
    if (small) {
      batch.set(_chat(cid).collection('reads').doc(uid), <String, Object?>{'readAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    }
    await batch.commit();
  }

  @override
  Future<void> setTyping(String cid, String uid, {required bool typing}) => _chat(cid)
      .collection('reads')
      .doc(uid)
      .set(<String, Object?>{'typingAt': typing ? FieldValue.serverTimestamp() : null}, SetOptions(merge: true));

  @override
  Future<void> uploadPhoto(String path, Uint8List bytes, String contentType) async {
    await _storage().ref(path).putData(bytes, SettableMetadata(contentType: contentType));
  }

  @override
  Future<bool> photoExists(String path) async {
    try {
      await _storage().ref(path).getMetadata();
      return true;
    } on FirebaseException {
      return false;
    }
  }

  @override
  Future<Uint8List?> downloadPhoto(String path) async {
    try {
      return await _storage().ref(path).getData(_maxPhotoBytes);
    } on FirebaseException {
      // Removed by an admin, or this parent may no longer read the chat.
      return null;
    }
  }
}
