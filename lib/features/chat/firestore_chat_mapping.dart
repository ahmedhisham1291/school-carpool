import 'dart:typed_data';

import 'package:school_carpool/features/chat/chat_backend.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';

/// From chat documents (functions/src/chat/data.ts) to what the screens
/// show. Pure: no Firebase here, unit-tested.

/// Longest message text (firestore.rules and MESSAGE_TEXT_MAX on the server).
const int kMaxMessageText = 2000;

/// School and area groups with more members than this count as muted until
/// the parent chooses (functions/src/chat/model.ts LARGE_GROUP_SIZE).
const int kLargeGroupSize = 50;

/// Sender of system messages (the driver's quick messages). Not a person.
const String kSystemSender = 'carpool-system';

ChatMessageKind _kind(Object? v) => switch (v) {
  'photo' => ChatMessageKind.photo,
  'location' => ChatMessageKind.location,
  'deleted' => ChatMessageKind.deleted,
  _ => ChatMessageKind.text,
};

/// The chat list's preview of the last message, or null when there is none.
ChatPreview? previewOf(Object? last, String me) {
  if (last is! Map<String, Object?>) {
    return null;
  }
  final Object? text = last['text'];
  return ChatPreview(kind: _kind(last['kind']), text: text is String ? text : '', mine: last['senderUid'] == me);
}

/// One row of the chat list. [row] is the parent's own summary; [head] is
/// the chat's head, used for school and area groups (their rows are not
/// rewritten on every message: unread is the head's counter minus what the
/// parent read).
ChatSummary? summaryOf(ChatDoc row, ChatDoc? head, String me) {
  final ChatRef? ref = ChatRef.fromCid(row.id);
  if (ref == null) {
    return null;
  }
  final bool small = ref.kind.small;
  final ChatDoc source = small || head == null ? row : head;
  final int members = source.number('memberCount');
  final Object? muted = row.data['muted'];
  final String other = row.text('otherUid');
  return ChatSummary(
    ref: ref,
    nameAr: ref.kind == ChatKind.private ? row.text('otherName') : source.text('nameAr'),
    nameEn: ref.kind == ChatKind.private ? '' : source.text('nameEn'),
    lastMessage: previewOf(source.data['last'], me),
    lastAt: source.time('lastAt'),
    unread: small ? row.number('unread') : _positive((head?.number('seq') ?? 0) - row.number('readSeq')),
    muted: muted is bool ? muted : !small && members > kLargeGroupSize,
    frozen: row.data['frozen'] == true,
    memberCount: members,
    otherUserId: other.isEmpty ? null : other,
  );
}

int _positive(int v) => v < 0 ? 0 : v;

/// The chat list: newest activity first; chats without messages last, by name.
List<ChatSummary> summariesOf(List<ChatDoc> rows, Map<String, ChatDoc> heads, String me) {
  final List<ChatSummary> out = <ChatSummary>[
    for (final ChatDoc row in rows)
      if (summaryOf(row, heads[row.id], me) case final ChatSummary s) s,
  ];
  final DateTime never = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  out.sort((ChatSummary a, ChatSummary b) {
    final int byTime = (b.lastAt ?? never).compareTo(a.lastAt ?? never);
    return byTime != 0 ? byTime : a.ref.cid.compareTo(b.ref.cid);
  });
  return out;
}

/// What the conversation screen needs besides messages.
ChatInfo infoOf(ChatRef ref, ChatDoc row, ChatDoc? head, String me) {
  final ChatSummary? s = summaryOf(row, head, me);
  final bool frozen = row.data['frozen'] == true || head?.data['frozen'] == true;
  return ChatInfo(
    ref: ref,
    nameAr: s?.nameAr ?? '',
    nameEn: s?.nameEn ?? '',
    muted: s?.muted ?? false,
    frozen: frozen,
    memberCount: head?.number('memberCount') ?? row.number('memberCount'),
    otherUserId: s?.otherUserId,
    canWrite: !frozen,
  );
}

/// One message. [at] is its time (a message this phone just wrote has none
/// from the server yet). [readByOther]: another member's read mark is at or
/// after it (small chats).
ChatMessage messageOf(ChatDoc doc, {required DateTime at, required String me, required String authorName, required bool readByOther}) {
  final String sender = doc.text('senderUid');
  final bool system = sender == kSystemSender;
  final Object? lat = doc.data['lat'];
  final Object? lng = doc.data['lng'];
  final String path = doc.text('photoPath');
  return ChatMessage(
    id: doc.id,
    // No author for system messages: nothing to block or report as a parent.
    authorId: system ? '' : sender,
    authorName: system ? '' : authorName,
    kind: _kind(doc.data['kind']),
    createdAt: at,
    text: doc.text('text'),
    photoPath: path.isEmpty ? null : path,
    latitude: lat is num ? lat.toDouble() : null,
    longitude: lng is num ? lng.toDouble() : null,
    delivery: doc.pending
        ? ChatDelivery.sending
        : sender == me && readByOther
        ? ChatDelivery.read
        : ChatDelivery.sent,
  );
}

/// Keeps [known] (every message loaded so far, by ID) in step with a new
/// snapshot of the newest [limit] messages ([window], newest first).
///
/// A message inside the window's time range that is no longer in the
/// window was removed (an admin, the sending limit, a refused write). A
/// message older than the window only slid out of it as new ones came, and
/// stays (older pages are fetched, not listened to).
void mergeWindow(Map<String, ChatDoc> known, List<ChatDoc> window, int limit) {
  final Set<String> ids = <String>{for (final ChatDoc d in window) d.id};
  final bool full = window.length >= limit;
  DateTime? oldest;
  for (final ChatDoc d in window) {
    final DateTime? t = d.time('createdAt');
    if (t != null && (oldest == null || t.isBefore(oldest))) {
      oldest = t;
    }
  }
  final DateTime? edge = oldest;
  known.removeWhere((String id, ChatDoc d) {
    if (ids.contains(id)) {
      return false;
    }
    if (!full) {
      // The window holds every message of the chat.
      return true;
    }
    final DateTime? t = d.time('createdAt');
    return t == null || (edge != null && !t.isBefore(edge));
  });
  for (final ChatDoc d in window) {
    known[d.id] = d;
  }
}

/// [text] in pieces of at most [max] characters (a very long text is sent
/// as several messages instead of being refused). Never cuts an emoji in two.
List<String> splitText(String text, {int max = kMaxMessageText}) {
  final List<String> out = <String>[];
  String rest = text;
  while (rest.length > max) {
    int cut = max;
    final int unit = rest.codeUnitAt(cut - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      cut -= 1;
    }
    out.add(rest.substring(0, cut));
    rest = rest.substring(cut);
  }
  if (rest.isNotEmpty) {
    out.add(rest);
  }
  return out;
}

/// Where a chat photo is kept: the sender's own folder of that chat, under
/// the message's ID (firestore.rules and storage.rules allow nothing else).
String photoPathFor(String cid, String uid, String messageId, Uint8List bytes) =>
    'chatPhotos/$cid/$uid/$messageId.${ImageSizing.isWebp(bytes) ? 'webp' : 'jpg'}';

String photoContentType(Uint8List bytes) => ImageSizing.isWebp(bytes) ? 'image/webp' : 'image/jpeg';
