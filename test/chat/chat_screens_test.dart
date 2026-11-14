// Chat screens (F8, F9, F10, F13) through the ChatProvider interface, with
// the in-memory fake chat: no Firebase is needed. The Firestore provider
// behind the same interface is tested in firestore_chat_provider_test.dart.
// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chats_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/chat_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/test_app.dart';

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(FakeChatProvider chat, FakeChatRepository repo) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(chat: chat, chatRepository: repo),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required FakeChatProvider chat,
  required FakeChatRepository repo,
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 1600 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(chat, repo),
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.light(DesignDirection.a),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

/// A fake chat and repository closed after the test.
(FakeChatProvider, FakeChatRepository) _fakes({
  List<ChatSummary>? chats,
  Map<ChatRef, List<ChatMessage>>? messages,
  List<ChatRequest>? requests,
  List<ChatBlock>? blocks,
}) {
  final FakeChatProvider chat = FakeChatProvider(chats: chats ?? sampleChats(), messages: messages ?? sampleMessages(), now: chatNow);
  final FakeChatRepository repo = FakeChatRepository(requests: requests, blocks: blocks);
  addTearDown(chat.close);
  addTearDown(repo.close);
  return (chat, repo);
}

/// The screen reader label of the one icon [icon] on screen.
String? _iconLabel(WidgetTester tester, IconData icon) => tester.widget<Icon>(find.byIcon(icon)).semanticLabel;

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('Chats tab', () {
    testWidgets('lists chats with their names, previews, unread counts and mute marks', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.text('Nile School · 07:30'), findsOneWidget);
      expect(find.text('Running late'), findsOneWidget);
      expect(find.text('Hoda'), findsOneWidget);
      expect(find.text('You: Photo'), findsOneWidget);
      expect(find.text('Nile International School'), findsOneWidget);
      expect(find.byType(AppCountPill), findsOneWidget);
      expect(_iconLabel(tester, Icons.notifications_off_outlined), 'Muted');
    });

    testWidgets('a row opens its chat', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      final GoRouter router = await _pump(tester, '/chats', chat: chat, repo: repo);
      await tester.tap(find.byKey(Key('chat.${carpoolChat.cid}')));
      await tester.pumpAndSettle();
      expect(_path(router), carpoolChat.route);
      expect(find.text('Good morning'), findsOneWidget);
    });

    testWidgets('requests waiting on top; accepting opens the private chat', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(
        requests: <ChatRequest>[testChatRequest('uid-hoda_uid-1', from: 'uid-hoda', to: 'uid-1')],
      );
      final GoRouter router = await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.text('1 chat request'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chats.requestsRow')));
      await tester.pumpAndSettle();
      expect(_path(router), ChatRoutes.requests);
      expect(find.text('Waiting for you'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('request.uid-hoda_uid-1.accept')));
      expect(repo.calls, contains('answer:uid-hoda_uid-1:true'));
      expect(_path(router), privateChat.route);
    });

    testWidgets('empty state', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(chats: <ChatSummary>[]);
      await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.byKey(const Key('chats.empty')), findsOneWidget);
    });

    testWidgets('error state', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      chat.chatsError = const ChatFailure(ChatFailureKind.unavailable);
      await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.byType(ErrorStateView), findsOneWidget);
    });

    testWidgets('offline state', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      chat.chatsError = const ChatFailure(ChatFailureKind.offline);
      await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.byType(OfflineStateView), findsOneWidget);
    });

    testWidgets('a dropped connection shows the offline note', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, '/chats', chat: chat, repo: repo);
      expect(find.byKey(const Key('chats.offline')), findsNothing);
      chat.setConnection(ChatConnection.offline);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats.offline')), findsOneWidget);
    });

    testWidgets('Arabic, right to left', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, '/chats', chat: chat, repo: repo, locale: AppLocales.arabic);
      expect(find.text('مدرسة النيل · 07:30'), findsOneWidget);
      expect(Directionality.of(tester.element(find.byKey(const Key('chats.list')))), TextDirection.rtl);
    });
  });

  group('Conversation', () {
    testWidgets('group chat: authors, read mark on own message, location pin', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      expect(find.text('Good morning'), findsOneWidget);
      expect(find.text('Hoda'), findsOneWidget);
      expect(_iconLabel(tester, Icons.done_all_rounded), 'Read');
      expect(find.byKey(const Key('msg.m3.map')), findsOneWidget);
      expect(chat.calls, contains('markRead:${carpoolChat.cid}'));
    });

    testWidgets('sends text and clears the field', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.enterText(find.byKey(const Key('chat.composer.field')), 'Hello there');
      await tester.pump();
      expect(chat.calls, contains('keyStroke'));
      await tester.tap(find.byKey(const Key('chat.composer.send')));
      await tester.pumpAndSettle();
      expect(chat.calls, contains('sendText:${carpoolChat.cid}'));
      expect(find.text('Hello there'), findsOneWidget);
      final TextField field = tester.widget<TextField>(find.byKey(const Key('chat.composer.field')));
      expect(field.controller?.text, isEmpty);
    });

    testWidgets('offline: a message waits ("Sending") and goes out when back online', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      chat.offline = true;
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.enterText(find.byKey(const Key('chat.composer.field')), 'Queued');
      // Rebuild first: the send button turns on only after a frame with text.
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat.composer.send')));
      await tester.pumpAndSettle();
      expect(chat.calls, contains('sendText:${carpoolChat.cid}'));
      expect(_iconLabel(tester, Icons.schedule_rounded), 'Sending');
      chat.backOnline();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
    });

    testWidgets('a failed message is retried by a tap', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.tap(find.text('Failed one'));
      await tester.pumpAndSettle();
      expect(chat.calls, contains('retry:m4'));
    });

    testWidgets('photos in carpool chats: the photo is sent after picking', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('chat.composer.photo')));
      await tester.pumpAndSettle();
      expect(find.text('Location data is removed from the photo before it is sent.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat.photo.gallery')));
      await tester.pumpAndSettle();
      expect(chat.calls, contains('sendPhoto:${carpoolChat.cid}:68'));
    });

    testWidgets('a photo from another parent is loaded through the chat provider and shown', (WidgetTester tester) async {
      const String path = 'chatPhotos/cp_carpool:c-k1/uid-hoda/photomsg0001.webp';
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(
        messages: <ChatRef, List<ChatMessage>>{
          carpoolChat: <ChatMessage>[
            ChatMessage(id: 'p1', authorId: 'uid-hoda', authorName: 'Hoda', kind: ChatMessageKind.photo, createdAt: chatNow, photoPath: path),
            ChatMessage(id: 'p2', authorId: 'uid-hoda', authorName: 'Hoda', kind: ChatMessageKind.photo, createdAt: chatNow, photoPath: '$path.gone'),
          ],
        },
      );
      chat.photos[path] = base64Decode(kTinyPng);
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      expect(chat.calls, contains('photo:$path'));
      expect(find.descendant(of: find.byKey(const Key('msg.p1')), matching: find.byType(Image)), findsOneWidget);
      // Removed, or not readable any more: a broken-image mark, never an error.
      expect(find.descendant(of: find.byKey(const Key('msg.p2')), matching: find.byIcon(Icons.broken_image_outlined)), findsOneWidget);
    });

    testWidgets('no photos and no location pin in school and area groups', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, schoolChat.route, chat: chat, repo: repo);
      expect(find.byKey(const Key('chat.composer.photo')), findsNothing);
      expect(find.byKey(const Key('chat.composer.location')), findsNothing);
      expect(find.byKey(const Key('chat.composer.field')), findsOneWidget);
    });

    testWidgets('private chats have the photo and location buttons', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, privateChat.route, chat: chat, repo: repo);
      expect(find.byKey(const Key('chat.composer.photo')), findsOneWidget);
      expect(find.byKey(const Key('chat.composer.location')), findsOneWidget);
    });

    testWidgets('location pin after confirming', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('chat.composer.location')));
      await tester.pumpAndSettle();
      expect(find.text('Send your location?'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Send location')));
      await tester.pumpAndSettle();
      expect(chat.calls, contains('sendLocation:${carpoolChat.cid}'));
    });

    testWidgets('long-press a message to report it with a reason', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.longPress(find.text('Good morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat.action.report')));
      await tester.pumpAndSettle();
      // No reason yet: says how to fix it.
      await _tapVisible(tester, find.byKey(const Key('report.send')));
      expect(find.text('Pick a reason to send the report.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('report.reason.harassment')));
      await tester.pump();
      expect(find.byKey(const Key('report.urgentNote')), findsNothing);
      await _tapVisible(tester, find.byKey(const Key('report.send')));
      expect(repo.calls, contains('report:message:harassment:m1'));
      expect(find.text('Report sent. Thank you.'), findsOneWidget);
    });

    testWidgets('urgent reasons say the driving pauses now', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.longPress(find.text('Good morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat.action.report')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report.reason.dangerousDriving')));
      await tester.pump();
      expect(find.byKey(const Key('report.urgentNote')), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('report.send')));
      expect(repo.calls, contains('report:message:dangerousDriving:m1'));
      expect(find.text('Report sent. Driving is paused until review.'), findsOneWidget);
    });

    testWidgets('block from a private chat after confirming', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, privateChat.route, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('chat.info')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chatInfo.block')));
      await tester.pumpAndSettle();
      expect(find.text('Block this parent?'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Block')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('block:uid-hoda'));
    });

    testWidgets('mute from the info sheet', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('chat.info')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chatInfo.mute')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('mute:${carpoolChat.cid}:true'));
      expect(find.text('Chat muted'), findsOneWidget);
    });

    testWidgets("a blocked parent's messages are hidden in groups", (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(blocks: const <ChatBlock>[ChatBlock(blockedUid: 'uid-hoda', firstName: 'Hoda')]);
      await _pump(tester, carpoolChat.route, chat: chat, repo: repo);
      expect(find.text('Good morning'), findsNothing);
      expect(find.text('Hidden: you blocked this parent.'), findsOneWidget);
    });

    testWidgets('a closed (frozen) chat has no composer', (WidgetTester tester) async {
      final List<ChatSummary> chats = <ChatSummary>[
        ChatSummary(ref: privateChat, nameAr: 'Hoda', frozen: true, otherUserId: 'uid-hoda', lastAt: chatNow),
      ];
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(chats: chats);
      await _pump(tester, privateChat.route, chat: chat, repo: repo);
      expect(find.byKey(const Key('chat.closed')), findsOneWidget);
      expect(find.byKey(const Key('chat.composer.field')), findsNothing);
    });

    testWidgets('typing line and empty chat', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(messages: <ChatRef, List<ChatMessage>>{});
      chat.typingNow[privateChat] = <String>['Hoda'];
      await _pump(tester, privateChat.route, chat: chat, repo: repo);
      expect(find.byKey(const Key('chat.empty')), findsOneWidget);
      expect(find.text('Hoda is typing…'), findsOneWidget);
    });

    testWidgets('a strange chat route goes back to the Chats tab', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      final GoRouter router = await _pump(tester, '/chats/messaging/general', chat: chat, repo: repo);
      expect(_path(router), '/chats');
    });
  });

  group('Chat settings', () {
    testWidgets('turning requests off saves at once', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
      await _pump(tester, ChatRoutes.settings, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('chatSettings.requests')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('requestsOff:true'));
      expect(find.byKey(const Key('chatSettings.noBlocked')), findsOneWidget);
    });

    testWidgets('unblock after confirming', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(blocks: const <ChatBlock>[ChatBlock(blockedUid: 'uid-x', firstName: 'Samir')]);
      await _pump(tester, ChatRoutes.settings, chat: chat, repo: repo);
      await tester.tap(find.byKey(const Key('blocked.uid-x.unblock')));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Unblock')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('unblock:uid-x'));
      expect(find.byKey(const Key('blocked.uid-x')), findsNothing);
    });

    testWidgets('sent requests can be cancelled', (WidgetTester tester) async {
      final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(
        requests: <ChatRequest>[testChatRequest('uid-1_uid-hoda', from: 'uid-1', to: 'uid-hoda', toName: 'Hoda')],
      );
      await _pump(tester, ChatRoutes.requests, chat: chat, repo: repo);
      expect(find.text('Sent by you'), findsOneWidget);
      await tester.tap(find.byKey(const Key('request.uid-1_uid-hoda.cancel')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('cancel:uid-1_uid-hoda'));
      expect(find.byKey(const Key('requests.empty')), findsOneWidget);
    });
  });

  group('One line at 320 dp', () {
    for (final Locale locale in <Locale>[AppLocales.arabic, AppLocales.english]) {
      for (final double scale in <double>[1, 2]) {
        for (final String location in <String>['/chats', ChatRoutes.requests, ChatRoutes.settings]) {
          testWidgets('[${locale.languageCode} x$scale] $location', (WidgetTester tester) async {
            final (FakeChatProvider chat, FakeChatRepository repo) = _fakes(
              requests: <ChatRequest>[
                testChatRequest('uid-hoda_uid-1', from: 'uid-hoda', to: 'uid-1'),
                testChatRequest('uid-1_uid-badr', from: 'uid-1', to: 'uid-badr', toName: 'Badr'),
              ],
              blocks: const <ChatBlock>[ChatBlock(blockedUid: 'uid-x', firstName: 'Samir')],
            );
            await _pump(tester, location, chat: chat, repo: repo, locale: locale, width: 320, textScale: scale);
            expectOneLine(find.byType(AppBarTitle), '$location title', allowEllipsis: true);
            expectOneLine(find.byType(AppButton), '$location buttons');
            expectOneLine(find.byType(TextButton), '$location text buttons');
            expectOneLine(find.byType(AppSectionHeader), '$location headers');
            expectOneLine(find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)), '$location rows', allowEllipsis: true);
          });
        }

        testWidgets('[${locale.languageCode} x$scale] conversation and report chips', (WidgetTester tester) async {
          final (FakeChatProvider chat, FakeChatRepository repo) = _fakes();
          await _pump(tester, carpoolChat.route, chat: chat, repo: repo, locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBarTitle), 'conversation title', allowEllipsis: true);
          // The bubble, not the empty side of its line.
          await tester.longPress(find.text('Good morning'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('chat.action.report')));
          await tester.pumpAndSettle();
          expectOneLine(find.byType(AppChip), 'report reasons');
          expectOneLine(find.byKey(const Key('report.send')), 'send report');
        });
      }
    }
  });
}
