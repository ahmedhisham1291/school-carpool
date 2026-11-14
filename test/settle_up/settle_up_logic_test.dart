// Settle up (F45): models, the InstaPay address check, the summary and the
// failure messages. No Firebase. Written, not run here (no Flutter SDK in
// the build workspace). CI runs it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_labels.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/observability/sentry_area.dart';
import 'package:school_carpool/router/app_router.dart';

import '../helpers/privacy_fakes.dart';
import '../helpers/settle_fakes.dart';

void main() {
  final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
  final AppLocalizations ar = lookupAppLocalizations(AppLocales.arabic);

  group('InstaPay address (name@instapay)', () {
    test('accepts the form name@instapay, trims and lower-cases it', () {
      expect(InstaPayAddress.normalize('mona.ali@instapay'), 'mona.ali@instapay');
      expect(InstaPayAddress.normalize('  Mona.Ali_92@InstaPay '), 'mona.ali_92@instapay');
      expect(InstaPayAddress.normalize('m-1.x@instapay'), 'm-1.x@instapay');
    });

    test('a name typed without the ending gets it', () {
      expect(InstaPayAddress.normalize('mona.ali'), 'mona.ali@instapay');
      expect(InstaPayAddress.isValid('Mona92'), isTrue);
    });

    test('refuses anything else (same cases as the server)', () {
      for (final String bad in <String>[
        '',
        'mo',
        'mona@gmail.com',
        'mona@instapay.com',
        'mona ali@instapay',
        'منى@instapay',
        '@instapay',
        'ab@instapay',
        '.mona@instapay',
        'mona@@instapay',
        'mona@insta',
        'EG380019000500000000263180002@bank',
        '${'a' * 51}@instapay',
        '<script>@instapay',
      ]) {
        expect(InstaPayAddress.normalize(bad), isNull, reason: bad);
      }
    });
  });

  group('records', () {
    test('parse the Firestore document (timestamps) and a function answer (milliseconds) alike', () {
      final DateTime t = DateTime.utc(2026, 11, 16, 8);
      final SettleUp fromDoc = SettleUp.fromMap('s_1', <String, dynamic>{
        'createdBy': 'payer',
        'payeeUid': 'uid-hoda',
        'payerUid': 'uid-1',
        'payeeFirstName': 'Hoda',
        'payerFirstName': 'Mona',
        'parties': <String>['uid-hoda', 'uid-1'],
        'carpoolId': 'c-k1',
        'amount': 15050,
        'reason': 'fuel',
        'note': 'Week 1',
        'status': 'paid',
        'notReceived': 1,
        'reportedBy': <String>['payer', 'nobody'],
        'events': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'recorded', 'by': 'payer', 'at': Timestamp.fromDate(t)},
          <String, dynamic>{'type': 'not-received', 'by': 'payee', 'at': Timestamp.fromDate(t)},
          <String, dynamic>{'type': 'unknown-type', 'by': 'payee', 'at': Timestamp.fromDate(t)},
          <String, dynamic>{'type': 'account-closed', 'by': 'system', 'at': Timestamp.fromDate(t)},
        ],
        'createdAt': Timestamp.fromDate(t),
        'updatedAt': Timestamp.fromDate(t),
      });
      expect(fromDoc.createdBy, SettleRole.payer);
      expect(fromDoc.amount, 15050);
      expect(fromDoc.reason, SettleReason.fuel);
      expect(fromDoc.status, SettleStatus.paid);
      expect(fromDoc.notReceived, 1);
      expect(fromDoc.reportedBy, <SettleRole>[SettleRole.payer]);
      expect(fromDoc.events.map((SettleEvent e) => e.type), <SettleEventType>[SettleEventType.recorded, SettleEventType.notReceived, SettleEventType.accountClosed]);
      expect(fromDoc.events.last.by, isNull, reason: 'the system');
      expect(fromDoc.createdAt, t);
      expect(fromDoc.roleOf('uid-1'), SettleRole.payer);
      expect(fromDoc.roleOf('uid-hoda'), SettleRole.payee);
      expect(fromDoc.roleOf('uid-other'), isNull);
      expect(fromDoc.roleOf(''), isNull);
      expect(fromDoc.otherName(SettleRole.payer), 'Hoda');

      final SettleUp fromCall = SettleUp.fromMap('s_2', <Object?, Object?>{
        'payeeUid': 'uid-1',
        'payerUid': 'uid-badr',
        'payeeFirstName': 'Mona',
        'payerFirstName': 'Badr',
        'amount': 8000,
        'reason': 'contribution',
        'status': 'open',
        'events': <Object?>[
          <Object?, Object?>{'type': 'requested', 'by': 'payee', 'atMs': t.millisecondsSinceEpoch},
        ],
        'createdAtMs': t.millisecondsSinceEpoch,
        'updatedAtMs': t.millisecondsSinceEpoch,
      });
      expect(fromCall.createdAt, t);
      expect(fromCall.events.single.at, t);
      expect(fromCall.status, SettleStatus.open);
    });

    test('an unreadable state is never shown as open; an odd amount is zero', () {
      final SettleUp odd = SettleUp.fromMap('s_x', const <Object?, Object?>{'status': 'weird', 'reason': 'loan', 'amount': '5'});
      expect(odd.status, SettleStatus.cancelled);
      expect(odd.status.finished, isTrue);
      expect(odd.reason, SettleReason.other);
      expect(odd.amount, 0);
    });

    test('what each side may do follows the server state machine', () {
      SettleUp r(SettleStatus s) => settleRecord('s', iPay: true, status: s);
      expect(r(SettleStatus.open).actionsFor(SettleRole.payer), <SettleAction>[SettleAction.paid, SettleAction.decline]);
      expect(r(SettleStatus.open).actionsFor(SettleRole.payee), <SettleAction>[SettleAction.cancel]);
      expect(r(SettleStatus.paid).actionsFor(SettleRole.payee), <SettleAction>[SettleAction.received, SettleAction.notReceived]);
      expect(r(SettleStatus.paid).actionsFor(SettleRole.payer), isEmpty);
      for (final SettleStatus s in <SettleStatus>[SettleStatus.closed, SettleStatus.cancelled, SettleStatus.declined]) {
        expect(s.finished, isTrue);
        for (final SettleRole role in SettleRole.values) {
          expect(r(s).actionsFor(role), isEmpty, reason: '${s.name} ${role.name}');
        }
      }
    });

    test('report: after N bounces, once per side', () {
      final SettleUp r = settleRecord('s', iPay: true, notReceived: 2, reportedBy: const <SettleRole>[SettleRole.payee]);
      expect(r.canReport(SettleRole.payer, 2), isTrue);
      expect(r.canReport(SettleRole.payee, 2), isFalse);
      expect(r.canReport(SettleRole.payer, 3), isFalse);
    });

    test('a new record carries its request ID and never an address', () {
      const SettleCreate c = SettleCreate(requestId: 'req-0000000000000001', paid: false, otherUid: 'uid-hoda', carpoolId: 'c-k1', amount: 15000, reason: SettleReason.fuel, note: 'w1');
      expect(c.toJson(), <String, Object?>{'requestId': 'req-0000000000000001', 'kind': 'request', 'otherUid': 'uid-hoda', 'carpoolId': 'c-k1', 'amount': 15000, 'reason': 'fuel', 'note': 'w1'});
      const SettleCreate p = SettleCreate(requestId: 'req-0000000000000002', paid: true, otherUid: 'uid-hoda', carpoolId: 'c-k1', amount: 100, reason: SettleReason.other);
      expect(p.toJson()['kind'], 'paid');
      expect(p.toJson().containsKey('note'), isFalse);
      expect(p.toJson().keys.any((String k) => k.toLowerCase().contains('address')), isFalse);
    });
  });

  group('summary (you owe / owes you)', () {
    test('per person, from records that are not finished', () {
      final List<PersonSummary> s = summarizeSettleUps(sampleSettleUps(), settleMe);
      expect(s.map((PersonSummary p) => p.firstName), <String>['Badr', 'Hoda']);
      final PersonSummary badr = s.first;
      final PersonSummary hoda = s.last;
      expect(badr.owesYou, 8000);
      expect(badr.youOwe, 0);
      expect(badr.waiting, 0, reason: 'the finished record counts for nothing');
      expect(hoda.youOwe, 15000);
      expect(hoda.waiting, 6000);
      expect(hoda.owesYou, 0);
    });

    test('nothing for a stranger, nothing when everything is finished', () {
      expect(summarizeSettleUps(sampleSettleUps(), 'uid-stranger'), isEmpty);
      expect(summarizeSettleUps(<SettleUp>[settleRecord('s', iPay: true, status: SettleStatus.closed)], settleMe), isEmpty);
    });
  });

  group('failures', () {
    test('every kind has a sentence in both languages', () {
      for (final SettleFailureKind k in SettleFailureKind.values) {
        expect(SettleFailure(k, amount: 500000).message(en), isNotEmpty, reason: k.name);
        expect(SettleFailure(k, amount: 500000).message(ar), isNotEmpty, reason: k.name);
      }
      expect(const SettleFailure(SettleFailureKind.amountTooHigh, amount: 20000).message(en), contains('200'));
      expect(const SettleFailure(SettleFailureKind.offline).isOffline, isTrue);
      expect(SettleFailure.from(StateError('x')).kind, SettleFailureKind.unknown);
      expect(SettleFailure.from(const SettleFailure(SettleFailureKind.noAddress)).kind, SettleFailureKind.noAddress);
    });

    test('the profile falls back to the server defaults', () {
      final SettleProfile p = SettleProfile.fromMap(const <Object?, Object?>{});
      expect(p.address, isNull);
      expect(p.maxAmount, 500000);
      expect(p.reportAfter, 2);
      final SettleProfile q = SettleProfile.fromMap(const <Object?, Object?>{'address': 'mona.test@instapay', 'maxAmount': 20000, 'reportAfter': 3});
      expect(q.address, 'mona.test@instapay');
      expect(q.maxAmount, 20000);
      expect(q.reportAfter, 3);
    });
  });

  group('wording', () {
    test('every state, reason and history entry has words in both languages', () {
      for (final AppLocalizations l in <AppLocalizations>[en, ar]) {
        for (final SettleStatus s in SettleStatus.values) {
          expect(settleStatusLabel(l, s), isNotEmpty);
          for (final SettleRole role in SettleRole.values) {
            expect(settleNextStep(l, settleRecord('s', iPay: true, status: s), role), isNotEmpty);
          }
        }
        for (final SettleReason r in SettleReason.values) {
          expect(settleReasonLabel(l, r), isNotEmpty);
        }
        for (final SettleEventType t in SettleEventType.values) {
          for (final SettleRole? by in <SettleRole?>[SettleRole.payee, SettleRole.payer, null]) {
            expect(settleEventLabel(l, SettleEvent(type: t, by: by, at: settleNow), SettleRole.payer), isNotEmpty);
          }
        }
      }
      expect(settleDirection(en, settleRecord('s', iPay: true), SettleRole.payer), contains('You pay'));
      expect(settleDirection(en, settleRecord('s', iPay: false), SettleRole.payee), contains('Pays you'));
    });

    test('the principle is said in plain words', () {
      expect(en.settleNoMoney, contains('does not move money'));
      expect(ar.settleNoMoney, contains('لا ينقل'));
    });
  });

  group('routes, notifications and analytics', () {
    test('routes', () {
      expect(SettleUpRoutes.home, '/profile/settle-up');
      expect(SettleUpRoutes.address, '/profile/settle-up/address');
      expect(SettleUpRoutes.record('s_1'), '/profile/settle-up/r/s_1');
      expect(SettleUpRoutes.create(), '/profile/settle-up/new');
      expect(SettleUpRoutes.create(carpoolId: 'k1'), '/profile/settle-up/new?carpool=k1');
      expect(SettleUpRoutes.homeFor('k1'), '/profile/settle-up?carpool=k1');
    });

    test('a settle-up push opens Settle up; settle-up kinds are push only', () {
      expect(NotificationRoutes.safe('/profile/settle-up'), '/profile/settle-up');
      expect(NotificationRoutes.safe('/profile/settle-up/r/../../x'), NotificationRoutes.fallback);
      for (final NotificationKind k in <NotificationKind>[NotificationKind.settleRequested, NotificationKind.settlePaid, NotificationKind.settleUpdated]) {
        expect(k.group, isNull, reason: 'no WhatsApp group');
        expect(k.critical, isFalse);
      }
      expect(SentryArea.ofPath('/profile/settle-up/r/:id'), 'wallet');
    });

    test('analytics carries the kind and the step only: never an amount, a name or an address', () async {
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      Analytics(sink, enabled: true)
        ..track(AnalyticsEvent.settleUpCreated, <String, Object?>{'kind': 'request', 'purpose': 'fuel', 'amount': 15000, 'address': hodaAddress, 'name': 'Hoda'})
        ..track(AnalyticsEvent.settleUpAction, <String, Object?>{'step': 'not-received', 'amount': 15000})
        ..track(AnalyticsEvent.settleUpAddress, <String, Object?>{'step': hodaAddress});
      await pumpEventQueue();
      expect(sink.events.map(((String, Map<String, Object>) e) => e.$1), <String>['settle_up_created', 'settle_up_action', 'settle_up_address']);
      expect(sink.events.map(((String, Map<String, Object>) e) => e.$2), <Map<String, Object>>[
        <String, Object>{'kind': 'request', 'purpose': 'fuel'},
        <String, Object>{'step': 'not-received'},
        <String, Object>{},
      ]);
      expect(sink.events.toString(), isNot(contains('instapay')));
    });
  });
}
