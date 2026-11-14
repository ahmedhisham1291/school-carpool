// Wallet screens (Prompt 11B: F43, F44, F25) with the fake repository and a
// fake Face ID check: no Firebase, no partner. Written, not run here (no
// Flutter SDK in the build workspace). CI runs it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/one_line.dart';
import '../helpers/test_app.dart';
import '../helpers/wallet_fakes.dart';

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(FakeWalletRepository repo, FakeDeviceAuth auth) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(wallet: repo, deviceAuth: auth),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required FakeWalletRepository repo,
  FakeDeviceAuth? auth,
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 2000 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(repo, auth ?? FakeDeviceAuth()),
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

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, Finder f, String text) async {
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  // The button turns on only after a rebuild with the text.
  await tester.pumpAndSettle();
}

/// Who -> Hoda by parent ID -> confirm -> amount -> note -> review.
Future<void> _toReview(WidgetTester tester, {String amount = '125.50', String note = 'Week 1'}) async {
  await _type(tester, find.byKey(const Key('send.parentId')), 'huda2345');
  await _tap(tester, find.byKey(const Key('send.find')));
  expect(find.byKey(const Key('wallet.receiver')), findsOneWidget);
  await _tap(tester, find.byKey(const Key('send.confirmReceiver')));
  await _type(tester, find.byKey(const Key('send.amount')), amount);
  await _tap(tester, find.byKey(const Key('send.amountNext')));
  await _type(tester, find.byKey(const Key('send.note')), note);
  await _tap(tester, find.byKey(const Key('send.noteNext')));
  expect(find.byKey(const Key('send.summary')), findsOneWidget);
}

void main() {
  group('wallet screen', () {
    testWidgets('balance from the server, actions and history (date, other parent, amount, note, status)', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.balance')), findsOneWidget);
      expect(find.textContaining('500'), findsWidgets);
      expect(find.byKey(const Key('wallet.send')), findsOneWidget);
      expect(find.byKey(const Key('wallet.add')), findsOneWidget);
      expect(find.byKey(const Key('wallet.withdraw')), findsOneWidget);
      expect(find.text('From Hoda'), findsOneWidget);
      expect(find.text('To Badr'), findsOneWidget);
      expect(find.text('Withdrawal'), findsOneWidget);
      expect(find.textContaining('Week 1'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(repo.calls, containsAll(<String>['wallet', 'history']));
    });

    testWidgets('not opened: agree to the partner terms, then Open wallet', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository(info: closedWallet, transfers: <WalletTransfer>[]);
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.open')), findsOneWidget);
      final Finder open = find.byKey(const Key('wallet.openButton'));
      await tester.ensureVisible(open);
      expect(tester.widget<ButtonStyleButton>(find.descendant(of: open, matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton))).onPressed, isNull);
      await _tap(tester, find.byKey(const Key('wallet.terms')));
      await _tap(tester, open);
      expect(repo.openedWith, '2026-11-14');
      expect(find.byKey(const Key('wallet.balance')), findsOneWidget);
      expect(find.byKey(const Key('wallet.historyEmpty')), findsOneWidget);
    });

    testWidgets('frozen: a note, and Send, Add and Withdraw are off', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository(info: const WalletInfo(available: true, status: WalletStatus.frozen, termsVersion: 'v', balance: 100));
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.frozen')), findsOneWidget);
      for (final String k in <String>['wallet.send', 'wallet.add', 'wallet.withdraw']) {
        final ButtonStyleButton b = tester.widget<ButtonStyleButton>(find.descendant(of: find.byKey(Key(k)), matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton)));
        expect(b.onPressed, isNull, reason: k);
      }
    });

    testWidgets('switched off, not verified, error and offline states', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository(info: const WalletInfo(available: false, status: WalletStatus.none, termsVersion: ''));
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.off')), findsOneWidget);
    });

    testWidgets('not verified: says to verify first', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..failure = const WalletFailure(WalletFailureKind.notVerified);
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.notVerified')), findsOneWidget);
    });

    testWidgets('offline, then retry', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..failure = const WalletFailure(WalletFailureKind.offline);
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.text('Try again'), findsOneWidget);
      await _tap(tester, find.text('Try again'));
      expect(find.byKey(const Key('wallet.balance')), findsOneWidget);
    });

    testWidgets('partner down: error with retry, never a stale balance', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..failure = const WalletFailure(WalletFailureKind.unavailable);
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      expect(find.byKey(const Key('wallet.error')), findsOneWidget);
      expect(find.byKey(const Key('wallet.balance')), findsNothing);
    });

    testWidgets('Arabic: right to left', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.wallet, repo: FakeWalletRepository(), locale: AppLocales.arabic);
      expect(Directionality.of(tester.element(find.byKey(const Key('wallet.balance')))), TextDirection.rtl);
    });
  });

  group('send', () {
    testWidgets('by parent ID: receiver first, then amount, note, review, Face ID, sent', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth();
      final GoRouter router = await _pump(tester, WalletRoutes.send(), repo: repo, auth: auth);
      await _toReview(tester);
      expect(find.text('Hoda'), findsWidgets);
      expect(find.text('Verified'), findsWidgets);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(auth.reasons, hasLength(1));
      expect(repo.sends, hasLength(1));
      final SendRequest s = repo.sends.single;
      expect(s.receiver.parentId, 'HUDA2345');
      expect(s.amount, 12550);
      expect(s.note, 'Week 1');
      expect(find.byKey(const Key('wallet.outcome.done')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('wallet.done')));
      expect(_path(router), ProfileRoutes.wallet);
    });

    testWidgets('from a carpool: pick a parent of my carpool', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _tap(tester, find.byKey(const Key('send.contact.c-k1.uid-badr')));
      await _tap(tester, find.byKey(const Key('send.confirmReceiver')));
      await _type(tester, find.byKey(const Key('send.amount')), '20');
      await _tap(tester, find.byKey(const Key('send.amountNext')));
      await _tap(tester, find.byKey(const Key('send.noteNext')));
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(repo.sends.single.receiver.uid, 'uid-badr');
      expect(repo.sends.single.toJson()['carpoolId'], 'c-k1');
    });

    testWidgets('Pay contribution: the organizer and the agreed amount are filled in; still confirmed', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth();
      await _pump(tester, WalletRoutes.send(carpoolId: 'c-k1', amount: 30000), repo: repo, auth: auth);
      // Straight to the confirmation of Hoda, the organizer.
      expect(find.byKey(const Key('wallet.receiver')), findsOneWidget);
      expect(repo.sends, isEmpty, reason: 'nothing is sent automatically');
      await _tap(tester, find.byKey(const Key('send.confirmReceiver')));
      expect(find.byKey(const Key('send.contributionNote')), findsOneWidget);
      expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('send.amount')), matching: find.byType(EditableText))).controller.text, '300');
      await _tap(tester, find.byKey(const Key('send.amountNext')));
      await _tap(tester, find.byKey(const Key('send.noteNext')));
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(repo.sends.single.amount, 30000);
      expect(repo.sends.single.receiver.uid, 'uid-hoda');
      expect(auth.reasons, hasLength(1));
    });

    testWidgets('a double tap sends once (button busy, one request ID)', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..hold = Completer<void>();
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _toReview(tester);
      final Finder send = find.byKey(const Key('send.send'));
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pump();
      await tester.tap(send, warnIfMissed: false);
      await tester.pump();
      repo.hold!.complete();
      await tester.pumpAndSettle();
      expect(repo.sends, hasLength(1));
      expect(find.byKey(const Key('wallet.outcome.done')), findsOneWidget);
    });

    testWidgets('lost answer: the retry uses the same request ID, and the server sends once', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth();
      await _pump(tester, WalletRoutes.send(), repo: repo, auth: auth);
      await _toReview(tester);
      repo.failure = const WalletFailure(WalletFailureKind.offline);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(find.byKey(const Key('send.error')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(repo.sends.map((SendRequest s) => s.requestId).toSet(), hasLength(1));
      expect(repo.byRequest, hasLength(1));
      expect(auth.reasons, hasLength(2), reason: 'a fresh check before every try');
      expect(find.byKey(const Key('wallet.outcome.done')), findsOneWidget);
    });

    testWidgets('no Face ID: nothing is sent', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth(DeviceAuthResult.cancelled);
      await _pump(tester, WalletRoutes.send(), repo: repo, auth: auth);
      await _toReview(tester);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(repo.sends, isEmpty);
      expect(find.byKey(const Key('send.error')), findsOneWidget);
      auth.result = DeviceAuthResult.unavailable;
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(repo.sends, isEmpty);
      expect(find.text('Set a phone passcode or Face ID first to send money.'), findsOneWidget);
    });

    testWidgets('above the limit: refused as the parent types', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository(
        info: const WalletInfo(available: true, status: WalletStatus.active, termsVersion: 'v', balance: 900000, limits: WalletLimits(perTransferMax: 100000)),
      );
      await _pump(tester, ProfileRoutes.wallet, repo: repo);
      await _tap(tester, find.byKey(const Key('wallet.send')));
      await _type(tester, find.byKey(const Key('send.parentId')), 'HUDA2345');
      await _tap(tester, find.byKey(const Key('send.find')));
      await _tap(tester, find.byKey(const Key('send.confirmReceiver')));
      await _type(tester, find.byKey(const Key('send.amount')), '1500');
      expect(find.textContaining('The most per transfer is'), findsOneWidget);
      final ButtonStyleButton next = tester.widget<ButtonStyleButton>(
        find.descendant(of: find.byKey(const Key('send.amountNext')), matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton)),
      );
      expect(next.onPressed, isNull);
    });

    testWidgets('the server refuses a frozen wallet: one sentence, nothing sent', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _toReview(tester);
      repo.failure = const WalletFailure(WalletFailureKind.frozen);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(find.text('Your wallet is paused. Contact support.'), findsOneWidget);
      expect(repo.byRequest, isEmpty);
    });

    testWidgets('pending, then Check again shows done', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..nextStatus = TransferStatus.pending;
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _toReview(tester);
      await _tap(tester, find.byKey(const Key('send.send')));
      expect(find.byKey(const Key('wallet.outcome.pending')), findsOneWidget);
      final WalletTransfer t = repo.transfers.first;
      repo.transfers = <WalletTransfer>[
        WalletTransfer(id: t.id, kind: t.kind, outgoing: true, amount: t.amount, status: TransferStatus.done, createdAt: t.createdAt, otherName: t.otherName),
      ];
      await _tap(tester, find.byKey(const Key('wallet.checkAgain')));
      expect(find.byKey(const Key('wallet.outcome.done')), findsOneWidget);
    });

    testWidgets('an unknown parent ID says so; a wrong shape is caught before asking', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _type(tester, find.byKey(const Key('send.parentId')), 'ZZZZ2345');
      await _tap(tester, find.byKey(const Key('send.find')));
      expect(find.text('No parent has this ID. Check it and try again.'), findsOneWidget);
      await _type(tester, find.byKey(const Key('send.parentId')), 'ABCD0000');
      expect(repo.calls.where((String c) => c.startsWith('lookup:')), hasLength(1));
    });

    testWidgets('an unverified receiver cannot be paid', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository()..parents = <String, ReceiverPreview>{'HUDA2345': const ReceiverPreview(firstName: 'Hoda', verified: false)};
      await _pump(tester, WalletRoutes.send(), repo: repo);
      await _type(tester, find.byKey(const Key('send.parentId')), 'HUDA2345');
      await _tap(tester, find.byKey(const Key('send.find')));
      expect(find.text('Not verified'), findsOneWidget);
      final ButtonStyleButton yes = tester.widget<ButtonStyleButton>(
        find.descendant(of: find.byKey(const Key('send.confirmReceiver')), matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton)),
      );
      expect(yes.onPressed, isNull);
    });
  });

  group('add money, withdraw, report', () {
    testWidgets('add test money', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth();
      await _pump(tester, WalletRoutes.add, repo: repo, auth: auth);
      await _type(tester, find.byKey(const Key('money.amount')), '200');
      await _tap(tester, find.byKey(const Key('money.submit')));
      expect(repo.calls.any((String c) => c.startsWith('add:') && c.endsWith(':20000')), isTrue);
      expect(find.byKey(const Key('wallet.outcome.done')), findsOneWidget);
      expect(auth.reasons, isEmpty, reason: 'money coming in needs no check');
    });

    testWidgets('withdraw needs a fresh check', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final FakeDeviceAuth auth = FakeDeviceAuth();
      await _pump(tester, WalletRoutes.withdraw, repo: repo, auth: auth);
      await _type(tester, find.byKey(const Key('money.amount')), '50');
      await _tap(tester, find.byKey(const Key('money.submit')));
      expect(auth.reasons, hasLength(1));
      expect(repo.calls.any((String c) => c.startsWith('withdraw:') && c.endsWith(':5000')), isTrue);
    });

    testWidgets('report a problem from the history', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      final GoRouter router = await _pump(tester, ProfileRoutes.wallet, repo: repo);
      await _tap(tester, find.byKey(const Key('wallet.row.t_1')));
      expect(_path(router), WalletRoutes.transfer('t_1'));
      expect(find.byKey(const Key('report.unauthorized')), findsNothing);
      await _tap(tester, find.byKey(const Key('transfer.report')));
      expect(find.byKey(const Key('report.unauthorized')), findsNothing, reason: 'received money: "Not me" does not apply');
      await _tap(tester, find.byKey(const Key('report.wrongAmount')));
      await _type(tester, find.byKey(const Key('report.note')), 'Expected 150');
      await _tap(tester, find.byKey(const Key('report.send')));
      expect(repo.reports.single, (WalletReportReason.wrongAmount, 'Expected 150'));
      expect(find.text('Report sent'), findsOneWidget);
    });

    testWidgets('"Not me" on a sent transfer pauses my wallet', (WidgetTester tester) async {
      final FakeWalletRepository repo = FakeWalletRepository();
      await _pump(tester, WalletRoutes.transfer('t_2'), repo: repo);
      await _tap(tester, find.byKey(const Key('transfer.report')));
      await _tap(tester, find.byKey(const Key('report.unauthorized')));
      expect(find.byKey(const Key('report.freezeNote')), findsOneWidget);
      await _tap(tester, find.byKey(const Key('report.send')));
      expect(find.text('Reported; wallet paused'), findsOneWidget);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        final String where = '${locale.languageCode} x$scale';
        testWidgets('wallet buttons and title in $where', (WidgetTester tester) async {
          await _pump(tester, ProfileRoutes.wallet, repo: FakeWalletRepository(), locale: locale, width: 320, textScale: scale);
          for (final String k in <String>['wallet.send', 'wallet.add', 'wallet.withdraw']) {
            expectOneLine(find.byKey(Key(k)), '$k $where', requireText: true);
          }
          expectOneLine(find.byType(AppBar), 'app bar $where', requireText: true);
        });
        testWidgets('send steps in $where', (WidgetTester tester) async {
          await _pump(tester, WalletRoutes.send(), repo: FakeWalletRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byKey(const Key('send.find')), 'find $where', requireText: true);
          await _type(tester, find.byKey(const Key('send.parentId')), 'HUDA2345');
          await _tap(tester, find.byKey(const Key('send.find')));
          expectOneLine(find.byKey(const Key('send.confirmReceiver')), 'confirm $where', requireText: true);
          expectOneLine(find.byKey(const Key('send.otherReceiver')), 'other $where', requireText: true);
        });
        testWidgets('transfer detail in $where', (WidgetTester tester) async {
          await _pump(tester, WalletRoutes.transfer('t_2'), repo: FakeWalletRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byKey(const Key('transfer.report')), 'report $where', requireText: true);
          expectOneLine(find.byKey(const Key('transfer.check')), 'check $where', requireText: true);
          expectOneLine(find.byKey(const Key('transfer.status')), 'status $where', requireText: true);
        });
      }
    }
  });
}
