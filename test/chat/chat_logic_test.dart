// Chat logic (Prompt 9). Written, not run here (no Flutter SDK in the build
// workspace). CI runs it.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/chat/chat_labels.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/chat_fakes.dart';

void main() {
  group('ChatRef', () {
    test('parses only our four channel types and safe IDs', () {
      expect(ChatRef.parse('cp_carpool', 'c-k1'), carpoolChat);
      expect(ChatRef.parse('messaging', 'general'), isNull);
      expect(ChatRef.parse('cp_private', '../x'), isNull);
      expect(ChatRef.parse('cp_private', null), isNull);
      expect(ChatRef.fromCid('cp_school:s-nile'), schoolChat);
      expect(ChatRef.fromCid('cp_school'), isNull);
      expect(ChatRef.fromCid(null), isNull);
    });

    test('routes and the carpool chat of a carpool', () {
      expect(ChatRef.carpool('k1'), carpoolChat);
      expect(carpoolChat.route, '/chats/cp_carpool/c-k1');
      expect(carpoolChat.cid, 'cp_carpool:c-k1');
    });

    test('photos and read receipts only in private and carpool chats', () {
      expect(ChatKind.private.photos, isTrue);
      expect(ChatKind.carpool.photos, isTrue);
      expect(ChatKind.school.photos, isFalse);
      expect(ChatKind.area.readReceipts, isFalse);
    });

    test('a chat push may open a chat; other routes still fall back', () {
      expect(NotificationRoutes.safe('/chats/cp_private/dm-0123abc'), '/chats/cp_private/dm-0123abc');
      expect(NotificationRoutes.safe('/chats/messaging/x'), NotificationRoutes.fallback);
      expect(NotificationRoutes.safe('/chats/cp_private/a/b'), NotificationRoutes.fallback);
    });
  });

  group('ChatFailure', () {
    ChatFailureKind kindOf(String reason, [String code = 'failed-precondition']) =>
        ChatFailure.from(FirebaseFunctionsException(message: reason, code: code, details: <Object?, Object?>{'reason': reason})).kind;

    test('maps server reasons to messages that say what to do', () {
      expect(kindOf('blocked'), ChatFailureKind.blocked);
      expect(kindOf('requests-off'), ChatFailureKind.requestsOff);
      expect(kindOf('no-shared-school'), ChatFailureKind.noSharedSchool);
      expect(kindOf('rate-limited', 'resource-exhausted'), ChatFailureKind.rateLimited);
      expect(kindOf('suspended', 'permission-denied'), ChatFailureKind.suspended);
      expect(kindOf('self', 'invalid-argument'), ChatFailureKind.notFound);
      expect(ChatFailure.from(FirebaseFunctionsException(message: 'x', code: 'unavailable')).isOffline, isTrue);
      expect(ChatFailure.from(StateError('x')).kind, ChatFailureKind.unknown);
      final AppLocalizations l10n = lookupAppLocalizations(AppLocales.english);
      for (final ChatFailureKind k in ChatFailureKind.values) {
        expect(ChatFailure(k).message(l10n), isNotEmpty);
      }
    });
  });

  group('labels', () {
    final AppLocalizations l10n = lookupAppLocalizations(AppLocales.english);

    test('previews: own messages, photos, locations, removed', () {
      expect(chatPreview(l10n, null), 'No messages yet');
      expect(chatPreview(l10n, const ChatPreview(kind: ChatMessageKind.text, text: 'a\nb')), 'a b');
      expect(chatPreview(l10n, const ChatPreview(kind: ChatMessageKind.photo, mine: true)), 'You: Photo');
      expect(chatPreview(l10n, const ChatPreview(kind: ChatMessageKind.location)), 'Location');
      expect(chatPreview(l10n, const ChatPreview(kind: ChatMessageKind.deleted)), 'Message removed');
    });

    test('times: today, this week, older', () {
      final DateTime now = DateTime(2026, 11, 16, 12);
      expect(chatTime('en', DateTime(2026, 11, 16, 9, 5), now), '09:05');
      expect(chatTime('en', DateTime(2026, 11, 14, 9), now), 'Sat');
      expect(chatTime('en', DateTime(2026, 10, 1, 9), now), '10/1');
    });

    test('a missing name falls back to the kind of chat', () {
      expect(chatTitle(l10n, schoolChat, ''), 'School group');
      expect(chatTitle(l10n, schoolChat, 'Nile'), 'Nile');
    });

    test('urgent reasons are child safety and dangerous driving only', () {
      expect(<ReportReason>[for (final ReportReason r in ReportReason.values) if (r.urgent) r], <ReportReason>[
        ReportReason.childSafety,
        ReportReason.dangerousDriving,
      ]);
    });
  });

  group('ChatCredentials', () {
    test('reads the token answer; anything but stream is the fake', () {
      final ChatCredentials c = ChatCredentials.fromMap(<Object?, Object?>{
        'provider': 'stream',
        'apiKey': 'k',
        'userId': 'u',
        'token': 't',
        'expiresAtMs': 1000,
      });
      expect(c.provider, 'stream');
      expect(c.expiresAt, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
      expect(ChatCredentials.fromMap(<Object?, Object?>{'provider': 'other'}).provider, 'fake');
    });
  });

  group('FakeChatProvider (offline queue)', () {
    test('messages written offline wait, then send', () async {
      final FakeChatProvider p = FakeChatProvider(chats: sampleChats(), now: chatNow);
      addTearDown(p.close);
      p.offline = true;
      final ChatConversation c = p.open(carpoolChat);
      await c.sendText('hi');
      expect(p.messagesOf(carpoolChat).single.delivery, ChatDelivery.sending);
      p.backOnline();
      expect(p.messagesOf(carpoolChat).single.delivery, ChatDelivery.sent);
      await c.dispose();
    });
  });
}
