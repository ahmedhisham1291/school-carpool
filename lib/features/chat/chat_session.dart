import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/chat/chat_backend.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/features/chat/firestore_chat_provider.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';

/// Builds the chat provider: our own chat on Firestore, in every flavor
/// (dev runs it on the Firestore emulator). Widget tests override
/// [chatClientProvider] with the in-memory fake instead.
typedef ChatProviderFactory = ChatProvider Function(String provider);

final Provider<ChatProviderFactory> chatProviderFactoryProvider = Provider<ChatProviderFactory>((Ref ref) {
  final ChatBackend backend = FirestoreChatBackend(ref.watch(firestoreProvider), () => FirebaseStorage.instance);
  return (String provider) => FirestoreChatProvider(backend);
});

/// The uid of a signed-in, VERIFIED parent, or null (also when suspended or
/// banned: the record's status is then not "verified").
String? verifiedUidOf(SessionState session) =>
    session is SessionSignedIn && session.account?.status == AccountStatus.verified ? session.uid : null;

/// Changes only when the facts chat depends on change (who is signed in,
/// and whether they may chat). Other writes to the parent's record
/// (language, email, driving pause...) do not reconnect chat.
final Provider<String?> chatUidProvider = Provider<String?>((Ref ref) => ref.watch(sessionProvider.select(verifiedUidOf)));

String? _verifiedUid(Ref ref) => ref.watch(chatUidProvider);

/// The connected chat for the signed-in verified parent. No token and no
/// server call is needed to connect (firestore.rules decide what the parent
/// reads), so chat also opens offline from Firestore's cache. Signing out
/// (or losing verification) disconnects.
/// Riverpod 3 retries a failed provider by itself. A parent who may not chat
/// (not verified, suspended) must get the error at once, not a screen that
/// keeps loading; other failures retry a few times.
Duration? chatClientRetry(int retryCount, Object error) {
  if (error is ChatFailure && (error.kind == ChatFailureKind.notVerified || error.kind == ChatFailureKind.suspended)) {
    return null;
  }
  return retryCount < 3 ? Duration(milliseconds: 500 * (1 << retryCount)) : null;
}

final FutureProvider<ChatProvider> chatClientProvider = FutureProvider<ChatProvider>(retry: chatClientRetry, (Ref ref) async {
  final String? uid = _verifiedUid(ref);
  if (uid == null) {
    throw const ChatFailure(ChatFailureKind.notVerified);
  }
  final ChatRepository repo = ref.watch(chatRepositoryProvider);
  const String kind = 'firestore';
  final ChatProvider provider = ref.watch(chatProviderFactoryProvider)(kind);
  ref.onDispose(() => unawaited(provider.disconnect()));
  await provider.connect(ChatCredentials(provider: kind, userId: uid), () async => '');
  // Best effort: the triggers normally did this already (a missed change
  // is repaired here; offline it simply fails and nothing is lost).
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

/// Picks a photo and prepares it for upload: re-encoded (WebP on the phone,
/// JPEG on the web), long edge at most 1600, with EXIF (and so any
/// location) removed. Null when the parent cancelled.
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
    final Uint8List out;
    try {
      // keepExif is off: the compressor drops EXIF, GPS included.
      // Prompt 12: WebP on the phone (smaller); long edge at most 1600.
      out = await _compressor.compress(await file.readAsBytes(), document: false, webp: true);
    } on Object {
      throw const ChatFailure(ChatFailureKind.photoFailed);
    }
    // Belt and braces: never upload a JPEG that still carries EXIF.
    if (jpegHasExif(out)) {
      throw const ChatFailure(ChatFailureKind.photoFailed);
    }
    return out;
  }
}

/// True when [bytes] is a JPEG with an APP1 "Exif" segment before the image
/// data (where GPS location lives). Non-JPEG data returns false.
bool jpegHasExif(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return false;
  }
  int i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) {
      return false;
    }
    final int marker = bytes[i + 1];
    // Start of scan or end of image: no more metadata segments.
    if (marker == 0xDA || marker == 0xD9) {
      return false;
    }
    final int length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (marker == 0xE1 &&
        i + 10 <= bytes.length &&
        bytes[i + 4] == 0x45 &&
        bytes[i + 5] == 0x78 &&
        bytes[i + 6] == 0x69 &&
        bytes[i + 7] == 0x66) {
      return true;
    }
    if (length < 2) {
      return false;
    }
    i += 2 + length;
  }
  return false;
}

final Provider<ChatPhotoPicker> chatPhotoPickerProvider = Provider<ChatPhotoPicker>(
  (Ref ref) => DevicePhotoPicker(ref.watch(imageCompressorProvider)),
);
