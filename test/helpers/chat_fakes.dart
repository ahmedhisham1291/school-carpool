import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/features/chat/chat_session.dart';
import 'package:school_carpool/features/chat/chats_screen.dart';

/// Monday 16 Nov 2026, 10:00 UTC: the fixed "now" of chat tests.
final DateTime chatNow = DateTime.utc(2026, 11, 16, 10);

const ChatRef carpoolChat = ChatRef(ChatKind.carpool, 'c-k1');
const ChatRef schoolChat = ChatRef(ChatKind.school, 's-nile');
const ChatRef privateChat = ChatRef(ChatKind.private, 'dm-abc');

/// Fake chats (fake data only).
List<ChatSummary> sampleChats() => <ChatSummary>[
  ChatSummary(
    ref: carpoolChat,
    nameAr: 'مدرسة النيل · 07:30',
    nameEn: 'Nile School · 07:30',
    lastAt: chatNow.subtract(const Duration(minutes: 5)),
    unread: 2,
    memberCount: 3,
    lastMessage: const ChatPreview(kind: ChatMessageKind.text, text: 'Running late'),
  ),
  ChatSummary(
    ref: privateChat,
    nameAr: 'Hoda',
    lastAt: chatNow.subtract(const Duration(hours: 2)),
    memberCount: 2,
    otherUserId: 'uid-hoda',
    lastMessage: const ChatPreview(kind: ChatMessageKind.photo, mine: true),
  ),
  ChatSummary(
    ref: schoolChat,
    nameAr: 'مدرسة النيل الدولية',
    nameEn: 'Nile International School',
    lastAt: chatNow.subtract(const Duration(days: 2)),
    muted: true,
    memberCount: 120,
  ),
];

Map<ChatRef, List<ChatMessage>> sampleMessages() => <ChatRef, List<ChatMessage>>{
  carpoolChat: <ChatMessage>[
    ChatMessage(id: 'm1', authorId: 'uid-hoda', authorName: 'Hoda', kind: ChatMessageKind.text, createdAt: chatNow.subtract(const Duration(minutes: 9)), text: 'Good morning'),
    ChatMessage(id: 'm2', authorId: 'uid-1', authorName: 'Me', kind: ChatMessageKind.text, createdAt: chatNow.subtract(const Duration(minutes: 8)), text: 'On my way', delivery: ChatDelivery.read),
    ChatMessage(id: 'm3', authorId: 'uid-badr', authorName: 'Badr', kind: ChatMessageKind.location, createdAt: chatNow.subtract(const Duration(minutes: 7)), latitude: 30.05, longitude: 31.25),
    ChatMessage(id: 'm4', authorId: 'uid-1', authorName: 'Me', kind: ChatMessageKind.text, createdAt: chatNow.subtract(const Duration(minutes: 6)), text: 'Failed one', delivery: ChatDelivery.failed),
  ],
};

/// A pending request (fake data only).
ChatRequest testChatRequest(String id, {required String from, required String to, String fromName = 'Hoda', String toName = 'Me'}) => ChatRequest(
  id: id,
  fromUid: from,
  toUid: to,
  fromFirstName: fromName,
  toFirstName: toName,
  status: ChatRequestStatus.pending,
  createdAt: chatNow.subtract(const Duration(minutes: 30)),
);

/// Records calls; [failure] makes calls fail.
class FakeChatRepository implements ChatRepository {
  FakeChatRepository({List<ChatRequest>? requests, List<ChatBlock>? blocks, this.requestsOff = false})
    : requests = requests ?? <ChatRequest>[],
      blocks = blocks ?? <ChatBlock>[];

  List<ChatRequest> requests;
  List<ChatBlock> blocks;
  bool requestsOff;
  ChatFailure? failure;
  bool urgentReports = false;
  ChatRequestResult sendResult = const ChatRequestResult(status: ChatRequestStatus.pending);
  final List<String> calls = <String>[];
  final StreamController<int> _changes = StreamController<int>.broadcast();

  void emit() => _changes.add(0);

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final ChatFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    await for (final int _ in _changes.stream) {
      yield read();
    }
  }

  @override
  Future<ChatCredentials> token() async {
    await _maybeFail('token');
    return ChatCredentials(provider: 'fake', apiKey: '', userId: 'uid-1', token: 't', expiresAt: chatNow.add(const Duration(hours: 1)));
  }

  @override
  Future<void> syncMyChats() => _maybeFail('syncMyChats');

  @override
  Future<ChatRequestResult> sendRequest(String toUid) async {
    await _maybeFail('sendRequest:$toUid');
    return sendResult;
  }

  @override
  Future<ChatRequestResult> answerRequest(String requestId, {required bool accept}) async {
    await _maybeFail('answer:$requestId:$accept');
    requests = <ChatRequest>[for (final ChatRequest r in requests) if (r.id != requestId) r];
    emit();
    return ChatRequestResult(status: accept ? ChatRequestStatus.accepted : ChatRequestStatus.declined, chat: accept ? privateChat : null);
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    await _maybeFail('cancel:$requestId');
    requests = <ChatRequest>[for (final ChatRequest r in requests) if (r.id != requestId) r];
    emit();
  }

  @override
  Future<void> setRequestsOff({required bool off}) async {
    await _maybeFail('requestsOff:$off');
    requestsOff = off;
    emit();
  }

  @override
  Future<void> setMuted(ChatRef ref, {required bool muted}) => _maybeFail('mute:${ref.cid}:$muted');

  @override
  Future<void> block(String uid) async {
    await _maybeFail('block:$uid');
    blocks = <ChatBlock>[...blocks, ChatBlock(blockedUid: uid, firstName: uid)];
    emit();
  }

  @override
  Future<void> unblock(String uid) async {
    await _maybeFail('unblock:$uid');
    blocks = <ChatBlock>[for (final ChatBlock b in blocks) if (b.blockedUid != uid) b];
    emit();
  }

  @override
  Future<bool> report({required ChatRef ref, required ReportTarget target, required ReportReason reason, String? messageId, String? uid, String note = ''}) async {
    await _maybeFail('report:${target.name}:${reason.name}:${messageId ?? uid ?? ref.cid}');
    return urgentReports || reason.urgent;
  }

  @override
  Stream<List<ChatRequest>> watchRequests(String uid) => _watch(() => List<ChatRequest>.of(requests));

  @override
  Stream<List<ChatBlock>> watchBlocks(String uid) => _watch(() => List<ChatBlock>.of(blocks));

  @override
  Stream<bool> watchRequestsOff(String uid) => _watch(() => requestsOff);

  Future<void> close() => _changes.close();
}

class FakeChatPhotoPicker implements ChatPhotoPicker {
  Uint8List? next = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
  final List<PhotoSource> picked = <PhotoSource>[];

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    picked.add(source);
    return next;
  }
}

/// Chat overrides for widget tests: the fake provider (no Stream account),
/// the fake repository, the fake photo picker and a fixed clock. Always the
/// same four overrides.
List<Override> chatOverrides({FakeChatProvider? provider, FakeChatRepository? repository, FakeChatPhotoPicker? photos}) {
  final FakeChatProvider p = provider ?? FakeChatProvider(now: chatNow);
  return <Override>[
    chatClientProvider.overrideWith((Ref ref) async => p),
    chatRepositoryProvider.overrideWithValue(repository ?? FakeChatRepository()),
    chatPhotoPickerProvider.overrideWithValue(photos ?? FakeChatPhotoPicker()),
    chatClockProvider.overrideWithValue(() => chatNow),
  ];
}
