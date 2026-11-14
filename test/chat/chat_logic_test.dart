// Chat logic (Prompt 9). Written, not run here (no Flutter SDK in the build
// workspace). CI runs it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/chat/chat_labels.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chat_repository.dart';
import 'package:school_carpool/features/chat/chat_session.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/chat_fakes.dart';
import '../helpers/test_app.dart';

final NotifierProvider<_Session, SessionState> _sessionHolder = NotifierProvider<_Session, SessionState>(_Session.new);

class _Session extends Notifier<SessionState> {
  @override
  SessionState build() => testVerifiedSession;

  void set(SessionState s) => state = s;
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

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
      expect(ChatKind.school.locationPin, isFalse);
      expect(ChatKind.area.locationPin, isFalse);
      expect(ChatKind.carpool.locationPin, isTrue);
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

  group('chat connection follows only the token-relevant facts', () {
    test('a record change that keeps the parent verified does not reconnect (offline queue kept); suspension does', () async {
      final FakeChatProvider fake = FakeChatProvider(chats: sampleChats(), now: chatNow);
      final FakeChatRepository repo = FakeChatRepository();
      addTearDown(fake.close);
      addTearDown(repo.close);
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          sessionProvider.overrideWith((Ref ref) => ref.watch(_sessionHolder)),
          chatRepositoryProvider.overrideWithValue(repo),
          chatProviderFactoryProvider.overrideWithValue((String _) => fake),
        ],
      );
      addTearDown(container.dispose);
      // Kept alive for the whole test (closed with the container).
      container.listen<AsyncValue<ChatProvider>>(chatClientProvider, (_, _) {});
      expect(await container.read(chatClientProvider.future), same(fake));
      expect(repo.calls.where((String c) => c == 'token'), hasLength(1));

      // Language and email changed: same uid, still verified.
      container.read(_sessionHolder.notifier).set(
        const SessionSignedIn(
          uid: 'uid-1',
          account: Account(
            parentId: 'ABCD2345',
            status: AccountStatus.verified,
            phone: '+201000000001',
            email: 'new@example.com',
            emailVerified: true,
            termsAccepted: true,
            language: 'en',
          ),
        ),
      );
      await container.read(chatClientProvider.future);
      expect(repo.calls.where((String c) => c == 'token'), hasLength(1));
      expect(fake.calls, isNot(contains('disconnect')));

      // Suspended: chat is cut off on the phone too.
      container.read(_sessionHolder.notifier).set(
        const SessionSignedIn(
          uid: 'uid-1',
          account: Account(
            parentId: 'ABCD2345',
            status: AccountStatus.suspended,
            phone: '+201000000001',
            email: 'new@example.com',
            emailVerified: true,
            termsAccepted: true,
            language: 'en',
          ),
        ),
      );
      await expectLater(container.read(chatClientProvider.future), throwsA(isA<ChatFailure>()));
      expect(fake.calls, contains('disconnect'));
    });
  });

  test('no retry when the parent may not chat; a few retries otherwise', () {
    expect(chatClientRetry(0, const ChatFailure(ChatFailureKind.notVerified)), isNull);
    expect(chatClientRetry(0, const ChatFailure(ChatFailureKind.suspended)), isNull);
    expect(chatClientRetry(0, const ChatFailure(ChatFailureKind.offline)), isNotNull);
    expect(chatClientRetry(3, const ChatFailure(ChatFailureKind.offline)), isNull);
  });

  group('photos carry no EXIF', () {
    test('a JPEG with an EXIF (APP1) segment is detected; a clean one is not', () {
      // SOI, APP1 "Exif\0\0" with a tiny body, then SOS.
      final Uint8List withExif = Uint8List.fromList(<int>[
        0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x0A, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x4D, 0x4D, 0xFF, 0xDA, 0x00, 0x02,
      ]);
      final Uint8List clean = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xDA, 0x00, 0x02]);
      expect(jpegHasExif(withExif), isTrue);
      expect(jpegHasExif(clean), isFalse);
      expect(jpegHasExif(base64Decode(kTinyPng)), isFalse);
    });
  });
}
