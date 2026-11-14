// Wallet logic (Prompt 11B: F43, F44, F25). Written, not run here (no
// Flutter SDK in the build workspace). CI runs it.
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

void main() {
  group('Money: whole piastres, never floating point', () {
    test('parses what a parent types', () {
      expect(Money.parse('150'), 15000);
      expect(Money.parse('150.5'), 15050);
      expect(Money.parse('150.50'), 15050);
      expect(Money.parse('0.05'), 5);
      expect(Money.parse(' 1,250.75 '), 125075);
      // Arabic-Indic digits and the Arabic decimal mark.
      expect(Money.parse('١٢٫٥'), 1250);
      expect(Money.parse('۱۰'), 1000);
    });

    test('refuses odd input instead of rounding', () {
      for (final String bad in <String>['', '.', 'abc', '1.234', '-5', '1e3', '12.3.4', '999999999']) {
        expect(Money.parse(bad), isNull, reason: bad);
      }
    });

    test('0.1 + 0.2 never happens: sums stay exact', () {
      final int sum = Money.parse('0.10')! + Money.parse('0.20')!;
      expect(sum, 30);
      expect(Money.digits(sum, alwaysCents: true), contains('0.30'));
    });

    test('formats with grouping, cents only when needed', () {
      String plain(String s) => s.replaceAll(RegExp('[\u2066\u2069]'), '');
      expect(plain(Money.digits(125050)), '1,250.50');
      expect(plain(Money.digits(100000)), '1,000');
      expect(plain(Money.digits(5)), '0.05');
      expect(plain(Money.digits(123456789)), '1,234,567.89');
      expect(Money.typed(15050), '150.50');
      expect(Money.typed(15000), '150');
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(plain(Money.format(en, 30000)), 'EGP 300');
      final AppLocalizations ar = lookupAppLocalizations(AppLocales.arabic);
      expect(plain(Money.format(ar, 30000)), contains('300'));
    });

    test('contribution: pounds per child times my children, in piastres', () {
      expect(Money.contribution(poundsPerChild: 150, children: 2), 30000);
      expect(Money.contribution(poundsPerChild: 99, children: 0), 9900, reason: 'at least one child');
    });
  });

  test('request IDs are UUIDs, new each time', () {
    final String a = newRequestId(Random(1));
    final String b = newRequestId(Random(2));
    expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(a, isNot(b));
    // Accepted by the server's request ID check.
    expect(a, matches(RegExp(r'^[A-Za-z0-9-]{16,64}$')));
  });

  test('parent IDs: normalized and checked like the server', () {
    expect(ParentIds.normalize(' abcd-2345 '), 'ABCD2345');
    expect(ParentIds.isValid('abcd2345'), isTrue);
    for (final String bad in <String>['ABCD0345', 'ABCDO345', 'ABCD1345', 'ABCDI345', 'ABC']) {
      expect(ParentIds.isValid(bad), isFalse, reason: bad);
    }
  });

  test('a send carries the request ID, the receiver and the carpool', () {
    const WalletContact c = WalletContact(uid: 'uid-hoda', firstName: 'Hoda', verified: true, carpoolId: 'c-k1');
    final Map<String, Object?> byContact = SendRequest(requestId: 'req-1', receiver: Receiver.contact(c), amount: 100).toJson();
    expect(byContact, <String, Object?>{'requestId': 'req-1', 'amount': 100, 'toUid': 'uid-hoda', 'carpoolId': 'c-k1'});
    final Map<String, Object?> byId = SendRequest(
      requestId: 'req-2',
      receiver: Receiver.byParentId('HUDA2345', const ReceiverPreview(firstName: 'Hoda', verified: true)),
      amount: 5,
      note: 'Week 1',
    ).toJson();
    expect(byId, <String, Object?>{'requestId': 'req-2', 'amount': 5, 'toParentId': 'HUDA2345', 'note': 'Week 1'});
  });

  test('server answers map to one short sentence; unknown outcomes keep the request', () {
    WalletFailure f(String reason, [Map<String, Object?> extra = const <String, Object?>{}]) =>
        WalletFailure.from(FirebaseFunctionsException(message: reason, code: 'failed-precondition', details: <String, Object?>{'reason': reason, ...extra}));
    expect(f('frozen').kind, WalletFailureKind.frozen);
    expect(f('over-daily-limit', <String, Object?>{'left': 2500}).amount, 2500);
    expect(f('receiver-cannot-receive').kind, WalletFailureKind.receiverCannotReceive);
    expect(WalletFailure.from(FirebaseFunctionsException(message: 'x', code: 'deadline-exceeded')).outcomeUnknown, isTrue);
    expect(f('frozen').outcomeUnknown, isFalse);
    final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
    for (final WalletFailureKind k in WalletFailureKind.values) {
      expect(WalletFailure(k).message(en), isNotEmpty);
    }
  });

  test('wallet info from the server', () {
    final WalletInfo info = WalletInfo.fromMap(const <Object?, Object?>{
      'available': true,
      'status': 'frozen',
      'termsVersion': '2026-11-14',
      'balance': 1250,
      'limits': <Object?, Object?>{'perDayMax': 5000},
      'todayOut': 4000,
    });
    expect(info.status, WalletStatus.frozen);
    expect(info.opened, isTrue);
    expect(info.leftToday, 1000);
    expect(WalletInfo.fromMap(const <Object?, Object?>{'available': false}).available, isFalse);
  });
}
