import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Chat through our Cloud Functions (Prompt 9): the token, requests,
/// blocks, mutes, settings and reports. The app reads its own requests,
/// blocks, mutes and settings from Firestore (firestore.rules) and writes
/// none of them.
abstract interface class ChatRepository {
  /// A short-lived Stream token (verified, non-suspended parents only).
  Future<ChatCredentials> token();

  /// Puts the parent in their school, area and carpool chats.
  Future<void> syncMyChats();

  /// Returns the request's status ("pending", or "accepted" when the other
  /// parent had asked first) and the chat once accepted.
  Future<ChatRequestResult> sendRequest(String toUid);

  Future<ChatRequestResult> answerRequest(String requestId, {required bool accept});

  Future<void> cancelRequest(String requestId);

  Future<void> setRequestsOff({required bool off});

  Future<void> setMuted(ChatRef ref, {required bool muted});

  Future<void> block(String uid);

  Future<void> unblock(String uid);

  /// Returns whether the report was urgent (driving paused at once).
  Future<bool> report({required ChatRef ref, required ReportTarget target, required ReportReason reason, String? messageId, String? uid, String note = ''});

  /// Requests the parent sent or got (newest first, at most 50 each way).
  Stream<List<ChatRequest>> watchRequests(String uid);

  Stream<List<ChatBlock>> watchBlocks(String uid);

  /// Requests off (spec section 5).
  Stream<bool> watchRequestsOff(String uid);
}

class ChatRequestResult {
  const ChatRequestResult({required this.status, this.chat});

  final ChatRequestStatus status;
  final ChatRef? chat;
}

class FirebaseChatRepository implements ChatRepository {
  FirebaseChatRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  Future<Map<Object?, Object?>> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> r = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? value = r.data;
      return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(ChatFailure.from(error), stackTrace);
    }
  }

  ChatRequestResult _result(Map<Object?, Object?> m) {
    final Object? cid = m['cid'];
    return ChatRequestResult(
      status: ChatRequestStatus.values.firstWhere((ChatRequestStatus s) => s.name == m['status'], orElse: () => ChatRequestStatus.pending),
      chat: ChatRef.fromCid(cid is String ? cid : null),
    );
  }

  @override
  Future<ChatCredentials> token() async => ChatCredentials.fromMap(await _call('getChatToken'));

  @override
  Future<void> syncMyChats() => _call('syncMyChats');

  @override
  Future<ChatRequestResult> sendRequest(String toUid) async => _result(await _call('sendChatRequest', <String, Object?>{'toUid': toUid}));

  @override
  Future<ChatRequestResult> answerRequest(String requestId, {required bool accept}) async =>
      _result(await _call('answerChatRequest', <String, Object?>{'requestId': requestId, 'accept': accept}));

  @override
  Future<void> cancelRequest(String requestId) => _call('cancelChatRequest', <String, Object?>{'requestId': requestId});

  @override
  Future<void> setRequestsOff({required bool off}) => _call('updateChatSettings', <String, Object?>{'requestsOff': off});

  @override
  Future<void> setMuted(ChatRef ref, {required bool muted}) => _call('setChatMute', <String, Object?>{'cid': ref.cid, 'muted': muted});

  @override
  Future<void> block(String uid) => _call('blockChatUser', <String, Object?>{'uid': uid});

  @override
  Future<void> unblock(String uid) => _call('unblockChatUser', <String, Object?>{'uid': uid});

  @override
  Future<bool> report({
    required ChatRef ref,
    required ReportTarget target,
    required ReportReason reason,
    String? messageId,
    String? uid,
    String note = '',
  }) async {
    final Map<Object?, Object?> r = await _call('reportChat', <String, Object?>{
      'targetType': target.name,
      'cid': ref.cid,
      'reason': reason.name,
      'messageId': ?messageId,
      'uid': ?uid,
      if (note.isNotEmpty) 'note': note,
    });
    return r['urgent'] == true;
  }

  Stream<List<ChatRequest>> _requests(String field, String uid) => _db
      .collection('chatRequests')
      .where(field, isEqualTo: uid)
      .limit(50)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> s) => <ChatRequest>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) ChatRequest.fromDoc(d.id, d.data()),
        ],
      );

  @override
  Stream<List<ChatRequest>> watchRequests(String uid) async* {
    // Two queries (the rules allow each); merged newest first.
    List<ChatRequest> sent = const <ChatRequest>[];
    List<ChatRequest> got = const <ChatRequest>[];
    List<ChatRequest> both() => <ChatRequest>[...got, ...sent]..sort((ChatRequest a, ChatRequest b) => b.createdAt.compareTo(a.createdAt));
    await for (final (String which, List<ChatRequest> list) in _merge(
      _requests('fromUid', uid).map((List<ChatRequest> l) => ('sent', l)),
      _requests('toUid', uid).map((List<ChatRequest> l) => ('got', l)),
    )) {
      if (which == 'sent') {
        sent = list;
      } else {
        got = list;
      }
      yield both();
    }
  }

  /// Both streams in one; errors pass through; cancelled together.
  static Stream<T> _merge<T>(Stream<T> a, Stream<T> b) {
    final List<StreamSubscription<T>> subs = <StreamSubscription<T>>[];
    late final StreamController<T> out;
    out = StreamController<T>(
      onListen: () {
        for (final Stream<T> s in <Stream<T>>[a, b]) {
          subs.add(s.listen(out.add, onError: out.addError));
        }
      },
      onCancel: () async {
        for (final StreamSubscription<T> sub in subs) {
          await sub.cancel();
        }
        subs.clear();
        await out.close();
      },
    );
    return out.stream;
  }

  @override
  Stream<List<ChatBlock>> watchBlocks(String uid) => _db
      .collection('chatBlocks')
      .where('blockerUid', isEqualTo: uid)
      .limit(200)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> s) => <ChatBlock>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs)
            ChatBlock(
              blockedUid: d.data()['blockedUid'] is String ? d.data()['blockedUid'] as String : '',
              firstName: d.data()['blockedFirstName'] is String ? d.data()['blockedFirstName'] as String : '',
            ),
        ],
      );

  @override
  Stream<bool> watchRequestsOff(String uid) => _db
      .collection('chatSettings')
      .doc(uid)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> s) => s.data()?['requestsOff'] == true);
}

final Provider<ChatRepository> chatRepositoryProvider = Provider<ChatRepository>(
  (Ref ref) => FirebaseChatRepository(functionsClient(), ref.watch(firestoreProvider)),
);
