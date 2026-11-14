import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/features/chat/stream_chat_provider.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';

/// Builds the chat provider the server asked for: "stream" (a Stream app is
/// set up for this project) or "fake" (dev without one: chat stays on the
/// phone with a few fake parents).
typedef ChatProviderFactory = ChatProvider Function(String provider);

final Provider<ChatProviderFactory> chatProviderFactoryProvider = Provider<ChatProviderFactory>(
  // Offline storage on the phone; the website keeps chat in memory (Stage 2).
  (Ref ref) => (String provider) => provider == 'stream' ? StreamChatProvider(persist: !kIsWeb) : demoChatProvider(),
);

/// The signed-in, VERIFIED parent's uid, or null.
String? _verifiedUid(Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is SessionSignedIn && session.account?.status == AccountStatus.verified) {
    return session.uid;
  }
  return null;
}

/// The connected chat for the signed-in verified parent. Connects with a
/// short-lived token from Cloud Functions and refreshes it when it runs
/// out; joins the parent's chats once. Signing out (or losing verification)
/// disconnects and clears the chat kept on the phone.
final FutureProvider<ChatProvider> chatClientProvider = FutureProvider<ChatProvider>((Ref ref) async {
  final String? uid = _verifiedUid(ref);
  if (uid == null) {
    throw const ChatFailure(ChatFailureKind.notVerified);
  }
  final ChatRepository repo = ref.watch(chatRepositoryProvider);
  final ChatCredentials first = await repo.token();
  final ChatProvider provider = ref.watch(chatProviderFactoryProvider)(first.provider);
  ref.onDispose(() => unawaited(provider.disconnect()));
  await provider.connect(first, () async => (await repo.token()).token);
  // Best effort: the triggers normally did this already.
  unawaited(repo.syncMyChats().catchError((Object _) {}));
  return provider;
});

final StreamProvider<List<ChatSummary>> chatListProvider = StreamProvider<List<ChatSummary>>((Ref ref) async* {
  final ChatProvider provider = await ref.watch(chatClientProvider.future);
  yield* provider.chats();
});

final StreamProvider<ChatConnection> chatConnectionProvider = StreamProvider<ChatConnection>((Ref ref) async* {
  final ChatProvider provider = await ref.watch(chatClientProvider.future);
  yield* provider.connection;
});

/// Requests the parent sent or got.
final StreamProvider<List<ChatRequest>> chatRequestsProvider = StreamProvider<List<ChatRequest>>((Ref ref) {
  final String? uid = _verifiedUid(ref);
  if (uid == null) {
    return Stream<List<ChatRequest>>.value(const <ChatRequest>[]);
  }
  return ref.watch(chatRepositoryProvider).watchRequests(uid);
});

/// Requests waiting for this parent's answer.
final Provider<List<ChatRequest>> incomingRequestsProvider = Provider<List<ChatRequest>>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  final String uid = session is SessionSignedIn ? session.uid : '';
  return <ChatRequest>[
    for (final ChatRequest r in ref.watch(chatRequestsProvider).value ?? const <ChatRequest>[])
      if (r.pending && r.toUid == uid) r,
  ];
});

final StreamProvider<List<ChatBlock>> chatBlocksProvider = StreamProvider<List<ChatBlock>>((Ref ref) {
  final String? uid = _verifiedUid(ref);
  if (uid == null) {
    return Stream<List<ChatBlock>>.value(const <ChatBlock>[]);
  }
  return ref.watch(chatRepositoryProvider).watchBlocks(uid);
});

final StreamProvider<bool> chatRequestsOffProvider = StreamProvider<bool>((Ref ref) {
  final String? uid = _verifiedUid(ref);
  if (uid == null) {
    return Stream<bool>.value(false);
  }
  return ref.watch(chatRepositoryProvider).watchRequestsOff(uid);
});

// ---------------------------------------------------------------------------
// Photos (spec section 5: location data removed before upload)
// ---------------------------------------------------------------------------

enum PhotoSource { camera, gallery }

/// Picks a photo and prepares it for upload: re-encoded as JPEG, at most
/// 1080 on the short side, with EXIF (and so any location) removed. Null
/// when the parent cancelled.
abstract interface class ChatPhotoPicker {
  Future<Uint8List?> pick(PhotoSource source);
}

class DevicePhotoPicker implements ChatPhotoPicker {
  const DevicePhotoPicker(this._compressor);

  final ImageCompressor _compressor;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    final XFile? file = await ImagePicker().pickImage(
      source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (file == null) {
      return null;
    }
    try {
      // keepExif is off: the compressor drops EXIF, GPS included.
      return await _compressor.compress(await file.readAsBytes(), document: false);
    } on Object {
      throw const ChatFailure(ChatFailureKind.photoFailed);
    }
  }
}

final Provider<ChatPhotoPicker> chatPhotoPickerProvider = Provider<ChatPhotoPicker>(
  (Ref ref) => DevicePhotoPicker(ref.watch(imageCompressorProvider)),
);

// ---------------------------------------------------------------------------
// Dev without a Stream app: a few fake parents on the phone
// ---------------------------------------------------------------------------

FakeChatProvider demoChatProvider() {
  final DateTime t = DateTime.now().toUtc();
  const ChatRef school = ChatRef(ChatKind.school, 's-demo');
  const ChatRef carpool = ChatRef(ChatKind.carpool, 'c-demo');
  return FakeChatProvider(
    me: 'me',
    chats: <ChatSummary>[
      ChatSummary(
        ref: carpool,
        nameAr: 'مشوار المدرسة · 07:30',
        nameEn: 'School run · 07:30',
        lastAt: t,
        unread: 1,
        memberCount: 3,
        lastMessage: const ChatPreview(kind: ChatMessageKind.text, text: 'صباح الخير'),
      ),
      ChatSummary(
        ref: school,
        nameAr: 'مدرسة تجريبية',
        nameEn: 'Demo school',
        lastAt: t.subtract(const Duration(hours: 3)),
        muted: true,
        memberCount: 64,
      ),
    ],
    messages: <ChatRef, List<ChatMessage>>{
      carpool: <ChatMessage>[
        ChatMessage(
          id: 'demo-1',
          authorId: 'demo-hoda',
          authorName: 'هدى',
          kind: ChatMessageKind.text,
          createdAt: t.subtract(const Duration(minutes: 3)),
          text: 'صباح الخير',
        ),
      ],
    },
  );
}
