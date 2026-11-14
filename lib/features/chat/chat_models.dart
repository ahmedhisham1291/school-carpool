import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Chat (F8, F9, F10, F13). The app's own picture of chat, so screens never
/// depend on where chat is kept (the fake provider in tests and the
/// Firestore provider on the phone both produce these).

/// The four kinds of chat (spec section 5), with the type that starts a
/// chat's ID and its route.
enum ChatKind {
  private('cp_private'),
  school('cp_school'),
  area('cp_area'),
  carpool('cp_carpool');

  const ChatKind(this.type);

  /// Chat type (functions/src/chat/model.ts CHANNEL_TYPES).
  final String type;

  /// Private and carpool chats: photos, the location pin, read marks and
  /// typing, and an unread counter per member kept by Cloud Functions.
  /// School and area groups are text only (firestore.rules `smallChat`).
  bool get small => this == ChatKind.private || this == ChatKind.carpool;

  /// Photos only in private and carpool chats (spec section 5).
  bool get photos => small;

  /// The location pin too: an exact location must never go to a whole
  /// school (spec section 6). The rules refuse it in groups.
  bool get locationPin => small;

  /// Read receipts only in small chats.
  bool get readReceipts => small;

  static ChatKind? fromType(String? type) {
    for (final ChatKind k in ChatKind.values) {
      if (k.type == type) {
        return k;
      }
    }
    return null;
  }
}

final RegExp _part = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// A chat by its type and ID ("type:id" is its cid, the document ID).
class ChatRef {
  const ChatRef(this.kind, this.id);

  /// From a route or a push: null unless both parts are ours and safe.
  static ChatRef? parse(String? type, String? id) {
    final ChatKind? kind = ChatKind.fromType(type);
    if (kind == null || id == null || !_part.hasMatch(id)) {
      return null;
    }
    return ChatRef(kind, id);
  }

  static ChatRef? fromCid(String? cid) {
    final int at = cid?.indexOf(':') ?? -1;
    if (cid == null || at <= 0) {
      return null;
    }
    return parse(cid.substring(0, at), cid.substring(at + 1));
  }

  /// The carpool chat of [carpoolId] (made by Cloud Functions).
  factory ChatRef.carpool(String carpoolId) => ChatRef(ChatKind.carpool, 'c-$carpoolId');

  final ChatKind kind;
  final String id;

  String get cid => '${kind.type}:$id';

  /// go_router path of the conversation.
  String get route => '/chats/${kind.type}/$id';

  @override
  bool operator ==(Object other) => other is ChatRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => cid;
}

/// One row of the chat list.
class ChatSummary {
  const ChatSummary({
    required this.ref,
    required this.nameAr,
    this.nameEn = '',
    this.lastMessage,
    this.lastAt,
    this.unread = 0,
    this.muted = false,
    this.frozen = false,
    this.memberCount = 0,
    this.otherUserId,
  });

  final ChatRef ref;

  /// The other parent's first name (private), or the group's Arabic name.
  final String nameAr;

  /// The group's English name ('' when the same in both languages).
  final String nameEn;

  /// The name in the app's language.
  String title(String languageCode) => languageCode == 'en' && nameEn.isNotEmpty ? nameEn : nameAr;

  /// Preview of the newest message (shown on the phone only).
  final ChatPreview? lastMessage;
  final DateTime? lastAt;
  final int unread;
  final bool muted;

  /// A private chat where one parent blocked the other: nobody can write.
  final bool frozen;
  final int memberCount;

  /// Private chats: the other parent's uid (block and report).
  final String? otherUserId;
}

/// What the list shows of the newest message.
class ChatPreview {
  const ChatPreview({required this.kind, this.text = '', this.mine = false});

  final ChatMessageKind kind;
  final String text;
  final bool mine;
}

enum ChatMessageKind { text, photo, location, deleted }

enum ChatDelivery {
  /// Waiting to send (offline, or uploading a photo).
  sending,
  sent,

  /// Seen by the other parent(s) (small chats only).
  read,
  failed,
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.kind,
    required this.createdAt,
    this.text = '',
    this.photoPath,
    this.localImage,
    this.latitude,
    this.longitude,
    this.delivery = ChatDelivery.sent,
  });

  final String id;
  final String authorId;

  /// First name only.
  final String authorName;
  final ChatMessageKind kind;
  final DateTime createdAt;
  final String text;

  /// Where the photo is kept (Storage, members of the chat only).
  final String? photoPath;

  /// A photo still uploading (bytes on the phone).
  final List<int>? localImage;
  final double? latitude;
  final double? longitude;
  final ChatDelivery delivery;

  bool mine(String uid) => authorId == uid;

  ChatMessage withDelivery(ChatDelivery d) => ChatMessage(
    id: id,
    authorId: authorId,
    authorName: authorName,
    kind: kind,
    createdAt: createdAt,
    text: text,
    photoPath: photoPath,
    localImage: localImage,
    latitude: latitude,
    longitude: longitude,
    delivery: d,
  );
}

/// State of the chat connection, for the offline banner.
enum ChatConnection { connecting, online, offline, unavailable }

/// What a conversation screen needs about the chat besides messages.
class ChatInfo {
  const ChatInfo({
    required this.ref,
    required this.nameAr,
    this.nameEn = '',
    this.muted = false,
    this.frozen = false,
    this.memberCount = 0,
    this.otherUserId,
    this.canWrite = true,
  });

  final ChatRef ref;
  final String nameAr;
  final String nameEn;
  final bool muted;
  final bool frozen;
  final int memberCount;
  final String? otherUserId;

  String title(String languageCode) => languageCode == 'en' && nameEn.isNotEmpty ? nameEn : nameAr;

  /// False when frozen or the parent may not write.
  final bool canWrite;
}

/// Who chat connects as. Our own chat needs no token: the Firebase sign-in
/// is the identity and firestore.rules decide what the parent may read.
class ChatCredentials {
  const ChatCredentials({required this.provider, required this.userId});

  /// "firestore" (the app) or "fake" (widget tests).
  final String provider;
  final String userId;
}

// ---------------------------------------------------------------------------
// Firestore records the app may read (firestore.rules)
// ---------------------------------------------------------------------------

enum ChatRequestStatus { pending, accepted, declined, cancelled }

class ChatRequest {
  const ChatRequest({
    required this.id,
    required this.fromUid,
    required this.toUid,
    required this.fromFirstName,
    required this.toFirstName,
    required this.status,
    required this.createdAt,
    this.cid,
  });

  factory ChatRequest.fromDoc(String id, Map<String, dynamic> d) => ChatRequest(
    id: id,
    fromUid: d['fromUid'] is String ? d['fromUid'] as String : '',
    toUid: d['toUid'] is String ? d['toUid'] as String : '',
    fromFirstName: d['fromFirstName'] is String ? d['fromFirstName'] as String : '',
    toFirstName: d['toFirstName'] is String ? d['toFirstName'] as String : '',
    status: ChatRequestStatus.values.firstWhere((ChatRequestStatus s) => s.name == d['status'], orElse: () => ChatRequestStatus.cancelled),
    // Firestore Timestamps are read as UTC.
    createdAt: d['createdAt'] is Timestamp ? (d['createdAt'] as Timestamp).toDate().toUtc() : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    cid: d['cid'] is String ? d['cid'] as String : null,
  );

  final String id;
  final String fromUid;
  final String toUid;
  final String fromFirstName;
  final String toFirstName;
  final ChatRequestStatus status;
  final DateTime createdAt;
  final String? cid;

  bool get pending => status == ChatRequestStatus.pending;
}

class ChatBlock {
  const ChatBlock({required this.blockedUid, required this.firstName});

  final String blockedUid;
  final String firstName;
}

/// Report reasons (functions/src/chat/model.ts). Urgent ones pause the
/// reported driver's driving days at once (spec section 6).
enum ReportReason {
  harassment,
  spam,
  inappropriate,
  privacy,
  childSafety,
  dangerousDriving,
  other;

  bool get urgent => this == ReportReason.childSafety || this == ReportReason.dangerousDriving;
}

enum ReportTarget { message, user, group }

// ---------------------------------------------------------------------------
// Failures
// ---------------------------------------------------------------------------

enum ChatFailureKind {
  offline,
  notVerified,
  suspended,
  notFound,
  notMember,
  blocked,
  requestsOff,
  noSharedSchool,
  alreadyPending,
  alreadyConnected,
  rateLimited,
  unavailable,
  photoFailed,
  unknown,
}

class ChatFailure implements Exception {
  const ChatFailure(this.kind);

  factory ChatFailure.from(Object error) {
    if (error is ChatFailure) {
      return error;
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Object? reason = details is Map<Object?, Object?> ? details['reason'] : null;
      return ChatFailure(switch (reason) {
        'not-verified' => ChatFailureKind.notVerified,
        'suspended' => ChatFailureKind.suspended,
        'not-found' || 'self' => ChatFailureKind.notFound,
        'not-member' || 'not-allowed' => ChatFailureKind.notMember,
        'blocked' => ChatFailureKind.blocked,
        'requests-off' => ChatFailureKind.requestsOff,
        'no-shared-school' => ChatFailureKind.noSharedSchool,
        'already-pending' => ChatFailureKind.alreadyPending,
        'already-connected' => ChatFailureKind.alreadyConnected,
        'rate-limited' => ChatFailureKind.rateLimited,
        'chat-unavailable' => ChatFailureKind.unavailable,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => ChatFailureKind.offline,
          _ => ChatFailureKind.unknown,
        },
      });
    }
    if (error is FirebaseException) {
      return ChatFailure(switch (error.code) {
        'unavailable' || 'deadline-exceeded' => ChatFailureKind.offline,
        // The rules: not (or no longer) a member, or not verified.
        'permission-denied' || 'unauthorized' => ChatFailureKind.notMember,
        _ => ChatFailureKind.unknown,
      });
    }
    return const ChatFailure(ChatFailureKind.unknown);
  }

  final ChatFailureKind kind;

  bool get isOffline => kind == ChatFailureKind.offline;

  /// One short sentence that says what happened and what to do.
  String message(AppLocalizations l10n) => switch (kind) {
    ChatFailureKind.offline => l10n.errorOfflineShort,
    ChatFailureKind.notVerified => l10n.chatErrorNotVerified,
    ChatFailureKind.suspended => l10n.chatErrorSuspended,
    ChatFailureKind.notFound => l10n.chatErrorNotFound,
    ChatFailureKind.notMember => l10n.chatErrorNotMember,
    ChatFailureKind.blocked => l10n.chatErrorBlocked,
    ChatFailureKind.requestsOff => l10n.chatErrorRequestsOff,
    ChatFailureKind.noSharedSchool => l10n.chatErrorNoSharedSchool,
    ChatFailureKind.alreadyPending => l10n.chatErrorAlreadyPending,
    ChatFailureKind.alreadyConnected => l10n.chatErrorAlreadyConnected,
    ChatFailureKind.rateLimited => l10n.chatErrorTooMany,
    ChatFailureKind.unavailable => l10n.chatErrorUnavailable,
    ChatFailureKind.photoFailed => l10n.chatErrorPhoto,
    ChatFailureKind.unknown => l10n.chatErrorUnknown,
  };

  @override
  String toString() => 'ChatFailure(${kind.name})';
}
