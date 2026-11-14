// Settle up screens (F45) with the fake repository: no Firebase, no
// InstaPay, no money. The list and summary, my InstaPay address, a new
// request in three steps, a record with the payee's address and Copy, the
// actions of each side, reports, states (loading, empty, error, offline,
// not verified) and one line at 320 dp in Arabic and English. Written, not
// run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/one_line.dart';
import '../helpers/settle_fakes.dart';
import '../helpers/test_app.dart';

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(FakeSettleUpRepository repo, SessionState session) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(session: session, settle: repo),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required FakeSettleUpRepository repo,
  SessionState session = testVerifiedSession,
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
}) async {
  // Tall: every list is built without scrolling.
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 3200 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(repo.dispose);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      // A fresh scope for every pump (some tests open several screens).
      key: UniqueKey(),
      overrides: _overrides(repo, session),
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

Finder _key(String k) => find.byKey(Key(k));

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

AppButton _button(WidgetTester tester, String key) => tester.widget<AppButton>(_key(key));

/// Records what the app copies (the system clipboard channel).
List<String> _clipboard(WidgetTester tester) {
  final List<String> copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
    if (call.method == 'Clipboard.setData') {
      final Object? args = call.arguments;
      if (args is Map<Object?, Object?> && args['text'] is String) {
        copied.add(args['text']! as String);
      }
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// Who (Hoda) -> amount, reason, note -> review.
Future<void> _toReview(WidgetTester tester, {String amount = '150', bool paid = false}) async {
  if (paid) {
    await _tap(tester, _key('settleNew.kindPaid'));
  }
  await _tap(tester, _key('settleNew.contact.c-k1.uid-hoda'));
  expect(_key('settleNew.step1'), findsOneWidget);
  await _type(tester, _key('settleNew.amount'), amount);
  await _tap(tester, _key('settleNew.reason.fuel'));
  await _type(tester, _key('settleNew.note'), 'Week 1');
  await _tap(tester, _key('settleNew.amountNext'));
  expect(_key('settleNew.summary'), findsOneWidget);
}

void main() {
  group('Settle up home', () {
    testWidgets('says the app moves no money, shows my address, the summary per person, open and finished records', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.home, repo: repo);
      expect(_key('settle.noMoney'), findsOneWidget);
      expect(find.textContaining('does not move money'), findsOneWidget);
      expect(find.textContaining('mona.test@instapay'), findsOneWidget);
      // Summary: I owe Hoda 150 (and 60 waits); Badr owes me 80.
      expect(_key('settle.summary.uid-hoda'), findsOneWidget);
      expect(find.textContaining('You owe: EGP'), findsOneWidget);
      expect(find.textContaining('Owes you: EGP'), findsOneWidget);
      expect(find.textContaining('Waiting to confirm: EGP'), findsOneWidget);
      for (final String id in <String>['s_owe', 's_owed', 's_waiting', 's_done']) {
        expect(_key('settle.row.$id'), findsOneWidget, reason: id);
      }
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Finished'), findsOneWidget);
      expect(_key('settle.openEmpty'), findsNothing);
      expect(repo.calls, containsAll(<String>['watch:uid-1', 'profile']));
      // No one else's address is asked for on the list.
      expect(repo.calls.where((String c) => c.startsWith('addressFor')), isEmpty);
    });

    testWidgets('empty: a short note and the one primary action', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(records: <SettleUp>[], myAddress: null);
      final GoRouter router = await _pump(tester, SettleUpRoutes.home, repo: repo);
      expect(_key('settle.openEmpty'), findsOneWidget);
      expect(find.text('Add yours so others can pay you'), findsOneWidget);
      expect(find.text('Finished'), findsNothing);
      expect(find.text('Summary'), findsNothing);
      await _tap(tester, _key('settle.new'));
      expect(_path(router), '${SettleUpRoutes.home}/${SettleUpRoutes.newSegment}');
    });

    testWidgets('the list is live: the other parent marks it paid and the row changes', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(records: <SettleUp>[settleRecord('s_owed', iPay: false, other: 'Badr', otherUid: 'uid-badr')]);
      await _pump(tester, SettleUpRoutes.home, repo: repo);
      expect(find.textContaining('Not paid'), findsOneWidget);
      repo.replace(settleRecord('s_owed', iPay: false, other: 'Badr', otherUid: 'uid-badr', status: SettleStatus.paid));
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting to confirm'), findsWidgets);
      expect(find.textContaining('Not paid'), findsNothing);
    });

    testWidgets('offline and error states with Retry', (WidgetTester tester) async {
      final FakeSettleUpRepository offline = FakeSettleUpRepository()..watchError = const SettleFailure(SettleFailureKind.offline);
      await _pump(tester, SettleUpRoutes.home, repo: offline);
      expect(find.byType(OfflineStateView), findsOneWidget);
      final FakeSettleUpRepository broken = FakeSettleUpRepository()..watchError = StateError('x');
      await _pump(tester, SettleUpRoutes.home, repo: broken);
      expect(_key('settle.error'), findsOneWidget);
      // Retry reads again.
      broken.watchError = null;
      await _tap(tester, find.byType(AppButton));
      expect(_key('settle.list'), findsOneWidget);
    });

    testWidgets('not verified: explains and offers to verify; nothing is loaded', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.home, repo: repo, session: testUnverifiedSession);
      expect(_key('settle.notVerified'), findsOneWidget);
      expect(repo.calls, isEmpty);
      expect(find.text('Verify account'), findsOneWidget);
      expect(_key('settle.new'), findsNothing);
    });

    testWidgets('opened from a carpool: a new request starts with that carpool', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      final GoRouter router = await _pump(tester, SettleUpRoutes.homeFor('c-k1'), repo: repo);
      await _tap(tester, _key('settle.new'));
      expect(router.routerDelegate.currentConfiguration.uri.queryParameters, <String, String>{'carpool': 'c-k1'});
      expect(repo.calls, contains('contacts:c-k1'));
      expect(_key('settleNew.contact.c-k2.uid-new'), findsNothing);
    });
  });

  group('my InstaPay address', () {
    testWidgets('checks the form as I type, saves the stored form and goes back', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(myAddress: null);
      final GoRouter router = await _pump(tester, SettleUpRoutes.address, repo: repo);
      expect(_button(tester, 'ipa.save').onPressed, isNull);
      expect(_key('ipa.remove'), findsNothing);
      expect(_key('ipa.private'), findsOneWidget);
      await _type(tester, _key('ipa.field'), 'mona@gmail.com');
      expect(find.textContaining('name@instapay ('), findsOneWidget);
      expect(_button(tester, 'ipa.save').onPressed, isNull);
      await _type(tester, _key('ipa.field'), ' Mona.Ali@InstaPay ');
      expect(find.textContaining('name@instapay ('), findsNothing);
      await _tap(tester, _key('ipa.save'));
      expect(repo.calls, contains('saveAddress:mona.ali@instapay'));
      expect(repo.myAddress, 'mona.ali@instapay');
      expect(_path(router), SettleUpRoutes.home);
      expect(find.text('Address saved.'), findsOneWidget);
    });

    testWidgets('a saved address can be changed, and removed after a confirmation', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      final GoRouter router = await _pump(tester, SettleUpRoutes.address, repo: repo);
      expect(find.text('mona.test@instapay'), findsOneWidget);
      // Unchanged: nothing to save.
      expect(_button(tester, 'ipa.save').onPressed, isNull);
      await _tap(tester, _key('ipa.remove'));
      expect(find.text('Remove address?'), findsOneWidget);
      // Cancel keeps it.
      await _tap(tester, find.text('Cancel'));
      expect(repo.myAddress, isNotNull);
      await _tap(tester, _key('ipa.remove'));
      await _tap(tester, find.text('Remove address').last);
      expect(repo.calls, contains('removeAddress'));
      expect(repo.myAddress, isNull);
      expect(_path(router), SettleUpRoutes.home);
    });

    testWidgets('a server refusal is one sentence under the field; the screen stays', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(myAddress: null);
      final GoRouter router = await _pump(tester, SettleUpRoutes.address, repo: repo);
      await _type(tester, _key('ipa.field'), 'mona.ali');
      repo.failure = const SettleFailure(SettleFailureKind.rateLimited);
      await _tap(tester, _key('ipa.save'));
      expect(find.text('Too many tries. Wait a little and try again.'), findsOneWidget);
      expect(_path(router), SettleUpRoutes.address);
      expect(repo.myAddress, isNull);
    });

    testWidgets('offline: the full-screen state with Retry', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository()..failure = const SettleFailure(SettleFailureKind.offline);
      await _pump(tester, SettleUpRoutes.address, repo: repo);
      expect(find.byType(OfflineStateView), findsOneWidget);
      await _tap(tester, find.byType(AppButton));
      expect(_key('ipa.form'), findsOneWidget);
    });
  });

  group('new request', () {
    testWidgets('three steps: who, how much and why, review; then the record opens', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      final GoRouter router = await _pump(tester, SettleUpRoutes.create(), repo: repo);
      expect(_key('settleNew.step0'), findsOneWidget);
      expect(find.byType(AppStepProgress), findsOneWidget);
      await _toReview(tester);
      expect(_key('settleNew.noMoney'), findsOneWidget);
      expect(find.text('You ask Hoda to pay you'), findsOneWidget);
      expect(find.text('Fuel'), findsOneWidget);
      expect(find.text('Week 1'), findsOneWidget);
      await _tap(tester, _key('settleNew.send'));
      final SettleCreate sent = repo.creates.single;
      expect(sent.paid, isFalse);
      expect(sent.otherUid, 'uid-hoda');
      expect(sent.carpoolId, 'c-k1');
      expect(sent.amount, 15000);
      expect(sent.reason, SettleReason.fuel);
      expect(sent.note, 'Week 1');
      expect(sent.requestId, 'req-0000000000000001');
      expect(_path(router), SettleUpRoutes.record('s_new1'));
      expect(find.text('Request sent.'), findsOneWidget);
    });

    testWidgets('"I already paid" records a payment that waits for the other parent', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(myAddress: null);
      await _pump(tester, SettleUpRoutes.create(), repo: repo);
      await _toReview(tester, amount: '75.50', paid: true);
      expect(find.text('You record that you paid Hoda'), findsOneWidget);
      await _tap(tester, _key('settleNew.send'));
      expect(repo.creates.single.paid, isTrue);
      expect(repo.creates.single.amount, 7550);
      expect(repo.records.first.status, SettleStatus.paid);
    });

    testWidgets('asking for a payment needs my InstaPay address first', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(myAddress: null);
      final GoRouter router = await _pump(tester, SettleUpRoutes.create(), repo: repo);
      expect(_key('settleNew.needsAddress'), findsOneWidget);
      // A parent cannot be picked yet.
      await _tap(tester, _key('settleNew.contact.c-k1.uid-hoda'));
      expect(_key('settleNew.step0'), findsOneWidget);
      await _tap(tester, _key('settleNew.addAddress'));
      expect(_path(router), SettleUpRoutes.address);
    });

    testWidgets('the amount is checked as I type: a clear amount, at least EGP 1, at most the server maximum', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository()..maxAmount = 20000;
      await _pump(tester, SettleUpRoutes.create(), repo: repo);
      await _tap(tester, _key('settleNew.contact.c-k1.uid-hoda'));
      expect(_button(tester, 'settleNew.amountNext').onPressed, isNull);
      expect(find.textContaining('Up to EGP'), findsOneWidget);
      for (final String bad in <String>['abc', '0.50', '12.345', '1,2,3']) {
        await _type(tester, _key('settleNew.amount'), bad);
        expect(_button(tester, 'settleNew.amountNext').onPressed, isNull, reason: bad);
      }
      await _type(tester, _key('settleNew.amount'), '201');
      expect(find.textContaining('The most for one request is'), findsOneWidget);
      expect(_button(tester, 'settleNew.amountNext').onPressed, isNull);
      await _type(tester, _key('settleNew.amount'), '200');
      expect(_button(tester, 'settleNew.amountNext').onPressed, isNotNull);
    });

    testWidgets('a double tap or a retry sends the same request ID: one record', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      final GoRouter router = await _pump(tester, SettleUpRoutes.create(), repo: repo);
      await _toReview(tester);
      // The answer of the first try is lost.
      repo.failure = const SettleFailure(SettleFailureKind.offline);
      await _tap(tester, _key('settleNew.send'));
      expect(_key('settleNew.error'), findsOneWidget);
      expect(_path(router), '${SettleUpRoutes.home}/${SettleUpRoutes.newSegment}');
      // Retry after the lost answer, then a double tap while it is sending.
      repo.hold = Completer<void>();
      await tester.ensureVisible(_key('settleNew.send'));
      await tester.tap(_key('settleNew.send'));
      await tester.pump();
      await tester.tap(_key('settleNew.send'), warnIfMissed: false);
      await tester.pump();
      repo.hold!.complete();
      await tester.pumpAndSettle();
      expect(repo.creates.map((SettleCreate c) => c.requestId).toSet(), <String>{'req-0000000000000001'});
      expect(repo.creates, hasLength(2), reason: 'the failed try and one retry; the double tap sent nothing');
      expect(repo.records.where((SettleUp r) => r.id.startsWith('s_new')), hasLength(1));
    });

    testWidgets('changing the request before sending makes a new request ID', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.create(), repo: repo);
      await _toReview(tester);
      repo.failure = const SettleFailure(SettleFailureKind.notAllowed);
      await _tap(tester, _key('settleNew.send'));
      expect(find.textContaining('same carpool'), findsOneWidget);
      await _tap(tester, _key('settleNew.back'));
      await _type(tester, _key('settleNew.amount'), '90');
      await _tap(tester, _key('settleNew.amountNext'));
      await _tap(tester, _key('settleNew.send'));
      expect(repo.creates.map((SettleCreate c) => c.requestId), <String>['req-0000000000000001', 'req-0000000000000002']);
      expect(repo.creates.last.amount, 9000);
    });

    testWidgets('parents: loading error with Retry, none yet, and a parent who is not verified cannot be picked', (WidgetTester tester) async {
      final FakeSettleUpRepository none = FakeSettleUpRepository(contacts: <SettleContact>[]);
      await _pump(tester, SettleUpRoutes.create(), repo: none);
      expect(_key('settleNew.contactsEmpty'), findsOneWidget);

      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.create(), repo: repo);
      expect(find.text('Not verified yet'), findsOneWidget);
      await _tap(tester, _key('settleNew.contact.c-k2.uid-new'));
      expect(_key('settleNew.step0'), findsOneWidget);
    });

    testWidgets('Back goes one step back, then to the list', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, SettleUpRoutes.create(), repo: FakeSettleUpRepository());
      await _tap(tester, _key('settleNew.contact.c-k1.uid-hoda'));
      expect(_key('settleNew.step1'), findsOneWidget);
      await _tap(tester, _key('settleNew.back'));
      expect(_key('settleNew.step0'), findsOneWidget);
      await _tap(tester, _key('settleNew.back'));
      expect(_path(router), SettleUpRoutes.home);
    });
  });

  group('a record', () {
    testWidgets('the payer of an open request sees the address, Copy with feedback, the three steps and "The app does not move money"', (WidgetTester tester) async {
      final List<String> copied = _clipboard(tester);
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: repo);
      expect(find.text('You pay Hoda'), findsOneWidget);
      expect(find.text('Not paid'), findsOneWidget);
      expect(find.text('Week 1'), findsOneWidget);
      expect(_key('settleDetail.address'), findsOneWidget);
      expect(find.text(hodaAddress), findsOneWidget);
      expect(repo.calls, contains('addressFor:s_owe'));
      expect(_key('settleDetail.steps'), findsOneWidget);
      expect(find.textContaining('Open the InstaPay app'), findsOneWidget);
      expect(find.textContaining('tap I paid'), findsWidgets);
      expect(_key('settleDetail.noMoney'), findsOneWidget);
      await _tap(tester, _key('settleDetail.copy'));
      expect(copied, <String>[hodaAddress]);
      expect(find.text('Address copied.'), findsOneWidget);
    });

    testWidgets('I paid: one tap, the record waits for the other parent, the address is gone', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: repo);
      expect(_key('settleDetail.paid'), findsOneWidget);
      expect(_key('settleDetail.decline'), findsOneWidget);
      await _tap(tester, _key('settleDetail.paid'));
      expect(repo.calls, contains('act:s_owe:paid'));
      expect(find.text('Marked as paid.'), findsOneWidget);
      expect(find.text('Waiting to confirm'), findsOneWidget);
      expect(_key('settleDetail.address'), findsNothing);
      expect(_key('settleDetail.paid'), findsNothing);
      expect(find.text('You marked it paid'), findsOneWidget);
    });

    testWidgets('the payee confirms Received after a confirmation; the record is finished', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(
        records: <SettleUp>[settleRecord('s_c', iPay: false, other: 'Badr', otherUid: 'uid-badr', status: SettleStatus.paid)],
      );
      await _pump(tester, SettleUpRoutes.record('s_c'), repo: repo);
      expect(find.text('Badr pays you'), findsOneWidget);
      // The payee never sees an address on the record.
      expect(_key('settleDetail.address'), findsNothing);
      expect(repo.calls.where((String c) => c.startsWith('addressFor')), isEmpty);
      await _tap(tester, _key('settleDetail.received'));
      expect(find.text('Confirm receipt?'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(repo.calls.where((String c) => c.startsWith('act')), isEmpty);
      await _tap(tester, _key('settleDetail.received'));
      await _tap(tester, find.text('Received').last);
      expect(repo.calls, contains('act:s_c:received'));
      expect(_key('settleDetail.received'), findsNothing);
      expect(_key('settleDetail.notReceived'), findsNothing);
      expect(find.text('You confirmed it'), findsOneWidget);
    });

    testWidgets('Not received puts it back to open and counts; after two, either side can report once', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(
        records: <SettleUp>[settleRecord('s_c', iPay: false, other: 'Badr', otherUid: 'uid-badr', status: SettleStatus.paid, notReceived: 1)],
      );
      await _pump(tester, SettleUpRoutes.record('s_c'), repo: repo);
      expect(_key('settleDetail.report'), findsNothing);
      await _tap(tester, _key('settleDetail.notReceived'));
      await _tap(tester, find.text('Not received').last);
      expect(repo.calls, contains('act:s_c:notReceived'));
      expect(repo.records.single.notReceived, 2);
      expect(repo.records.single.status, SettleStatus.open);
      expect(_key('settleDetail.cancel'), findsOneWidget);
      await _tap(tester, _key('settleDetail.report'));
      expect(find.textContaining('cannot get money back'), findsOneWidget);
      await _tap(tester, find.text('Report to admins').last);
      expect(repo.reports, <String>['s_c']);
      expect(find.text('Report sent.'), findsOneWidget);
      expect(_key('settleDetail.report'), findsNothing);
    });

    testWidgets('cancel (payee) and decline (payer) ask first', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.record('s_owed'), repo: repo);
      expect(_key('settleDetail.paid'), findsNothing, reason: 'the payee cannot mark it paid');
      await _tap(tester, _key('settleDetail.cancel'));
      expect(find.text('Cancel request?'), findsOneWidget);
      await _tap(tester, find.text('Cancel request').last);
      expect(repo.calls, contains('act:s_owed:cancel'));
      expect(find.text('Cancelled'), findsOneWidget);

      final FakeSettleUpRepository second = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: second);
      await _tap(tester, _key('settleDetail.decline'));
      await _tap(tester, find.text('Decline request').last);
      expect(second.calls, contains('act:s_owe:decline'));
      expect(find.text('Declined'), findsOneWidget);
    });

    testWidgets('the payee has no address saved: a note to ask, no Copy; I can still mark it paid', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(
        records: <SettleUp>[settleRecord('s_b', iPay: true, other: 'Badr', otherUid: 'uid-badr')],
      );
      await _pump(tester, SettleUpRoutes.record('s_b'), repo: repo);
      expect(_key('settleDetail.noAddress'), findsOneWidget);
      expect(_key('settleDetail.copy'), findsNothing);
      expect(_key('settleDetail.paid'), findsOneWidget);
    });

    testWidgets('a refused action is one sentence above the buttons; the record is unchanged', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: repo);
      repo.failure = const SettleFailure(SettleFailureKind.offline);
      await _tap(tester, _key('settleDetail.paid'));
      expect(_key('settleDetail.actionError'), findsOneWidget);
      expect(find.text('Not paid'), findsOneWidget);
      // Try again works.
      await _tap(tester, _key('settleDetail.paid'));
      expect(_key('settleDetail.actionError'), findsNothing);
      expect(find.text('Waiting to confirm'), findsOneWidget);
    });

    testWidgets('the address could not be loaded: one sentence with Retry', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository();
      // From the list (my profile is loaded), then the record: its address call fails once.
      final GoRouter router = await _pump(tester, SettleUpRoutes.home, repo: repo);
      repo.failure = const SettleFailure(SettleFailureKind.rateLimited);
      router.go(SettleUpRoutes.record('s_owe'));
      await tester.pumpAndSettle();
      expect(_key('settleDetail.addressError'), findsOneWidget);
      expect(_key('settleDetail.copy'), findsNothing);
      await _tap(tester, find.text('Try again'));
      expect(_key('settleDetail.address'), findsOneWidget);
      expect(find.text(hodaAddress), findsOneWidget);
    });

    testWidgets('a record that is not mine or does not exist: a calm empty state', (WidgetTester tester) async {
      await _pump(tester, SettleUpRoutes.record('s_missing'), repo: FakeSettleUpRepository());
      expect(_key('settleDetail.notFound'), findsOneWidget);
      expect(find.byType(ErrorStateView), findsNothing);
    });

    testWidgets('a deleted parent shows as an initial; a finished record has no actions', (WidgetTester tester) async {
      final FakeSettleUpRepository repo = FakeSettleUpRepository(
        records: <SettleUp>[settleRecord('s_gone', iPay: false, other: 'B.', otherUid: 'deleted', status: SettleStatus.cancelled)],
      );
      await _pump(tester, SettleUpRoutes.record('s_gone'), repo: repo);
      expect(find.text('B. pays you'), findsOneWidget);
      expect(find.byType(AppButton), findsNothing);
    });

    testWidgets('offline and error states', (WidgetTester tester) async {
      final FakeSettleUpRepository offline = FakeSettleUpRepository()..watchError = const SettleFailure(SettleFailureKind.offline);
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: offline);
      expect(find.byType(OfflineStateView), findsOneWidget);
      final FakeSettleUpRepository broken = FakeSettleUpRepository()..watchError = StateError('x');
      await _pump(tester, SettleUpRoutes.record('s_owe'), repo: broken);
      expect(_key('settleDetail.error'), findsOneWidget);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('[${locale.languageCode} x$scale] titles, buttons and badges', (WidgetTester tester) async {
          final String where = '(${locale.languageCode}, x$scale)';
          await _pump(tester, SettleUpRoutes.home, repo: FakeSettleUpRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'home app bar $where', requireText: true);
          expectOneLine(_key('settle.new'), 'new request $where', requireText: true);
          expectOneLine(find.byType(AppSectionHeader), 'section headers $where', allowEllipsis: scale > 1, requireText: true);
          for (final String id in <String>['s_owe', 's_owed', 's_waiting', 's_done']) {
            expectOneLine(find.descendant(of: _key('settle.row.$id'), matching: find.byType(OneLineText)).first, 'row $id $where', allowEllipsis: scale > 1, requireText: true);
          }
          expectOneLine(find.descendant(of: _key('settle.address'), matching: find.byType(OneLineText)).first, 'address row $where', allowEllipsis: scale > 1, requireText: true);

          await _pump(tester, SettleUpRoutes.address, repo: FakeSettleUpRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'address app bar $where', requireText: true);
          expectOneLine(_key('ipa.save'), 'save $where', requireText: true);
          expectOneLine(_key('ipa.remove'), 'remove $where', requireText: true);

          await _pump(tester, SettleUpRoutes.create(), repo: FakeSettleUpRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'new app bar $where', requireText: true);
          for (final String k in <String>['settleNew.kindRequest', 'settleNew.kindPaid']) {
            expectOneLine(_key(k), '$k $where', allowEllipsis: scale > 1, requireText: true);
          }
          await _tap(tester, _key('settleNew.contact.c-k1.uid-hoda'));
          for (final SettleReason r in SettleReason.values) {
            expectOneLine(_key('settleNew.reason.${r.name}'), 'reason ${r.name} $where', allowEllipsis: scale > 1, requireText: true);
          }
          expectOneLine(_key('settleNew.amountNext'), 'next $where', requireText: true);
          await _type(tester, _key('settleNew.amount'), '150');
          await _tap(tester, _key('settleNew.amountNext'));
          expectOneLine(_key('settleNew.send'), 'send $where', requireText: true);

          await _pump(tester, SettleUpRoutes.record('s_owe'), repo: FakeSettleUpRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'detail app bar $where', requireText: true);
          for (final String k in <String>['settleDetail.copy', 'settleDetail.paid', 'settleDetail.decline', 'settleDetail.status']) {
            expectOneLine(_key(k), '$k $where', requireText: true);
          }
          final FakeSettleUpRepository confirm = FakeSettleUpRepository(
            records: <SettleUp>[settleRecord('s_c', iPay: false, other: 'Badr', otherUid: 'uid-badr', status: SettleStatus.paid, notReceived: 2)],
          );
          await _pump(tester, SettleUpRoutes.record('s_c'), repo: confirm, locale: locale, width: 320, textScale: scale);
          for (final String k in <String>['settleDetail.received', 'settleDetail.notReceived', 'settleDetail.report', 'settleDetail.status']) {
            expectOneLine(_key(k), '$k $where', requireText: true);
          }
        });
      }
    }
  });
}
