import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Wallet (Prompt 11B: F43, F44, F25). The app only shows what the wallet
/// functions return and sends requests to them: it never writes a balance
/// or a transfer (MONEY rules).
///
/// Every amount is a whole number of piastres (100 per Egyptian pound),
/// never a floating-point number.
abstract final class Money {
  static const int perPound = 100;

  /// Largest amount the app lets a parent type (the server has its own limits).
  static const int maxTyped = 10000000 * perPound;

  static final RegExp _plain = RegExp(r'^\d{1,8}$');
  static final RegExp _grouped = RegExp(r'^\d{1,3}(,\d{3})+$');
  static final RegExp _cents = RegExp(r'^\d{1,2}$');

  /// Piastres from what the parent typed, or null when it is not a clear
  /// amount. Strict, never a guess:
  /// - Arabic-Indic and Western digits; spaces are ignored;
  /// - one decimal mark: "." or the Arabic mark, or a single comma followed
  ///   by one or two digits ("12,50" is 12.50, as some keypads type it);
  /// - thousands separators (comma or the Arabic one) only in real groups of
  ///   three ("1,250", "1,250.50"); anything else ("1,2,3", "12,5000",
  ///   "1.2.3") is refused;
  /// - at most two decimals: more is refused, never rounded.
  static int? parse(String input) {
    final StringBuffer b = StringBuffer();
    for (final int rune in input.trim().runes) {
      if (rune >= 0x0660 && rune <= 0x0669) {
        b.writeCharCode(0x30 + rune - 0x0660);
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        b.writeCharCode(0x30 + rune - 0x06F0);
      } else if (rune == 0x066B) {
        b.write('.');
      } else if (rune == 0x066C) {
        b.write(',');
      } else if (rune == 0x20 || rune == 0xA0) {
        continue;
      } else {
        b.writeCharCode(rune);
      }
    }
    final String text = b.toString();
    String whole;
    String? cents;
    final List<String> dot = text.split('.');
    if (dot.length > 2) {
      return null;
    }
    if (dot.length == 2) {
      whole = dot[0];
      cents = dot[1];
    } else {
      final List<String> comma = text.split(',');
      if (comma.length == 2 && _cents.hasMatch(comma[1])) {
        // A decimal comma: "12,5" or "12,50".
        whole = comma[0];
        cents = comma[1];
      } else {
        whole = text;
      }
    }
    if (cents != null && !_cents.hasMatch(cents)) {
      return null;
    }
    if (_grouped.hasMatch(whole)) {
      whole = whole.replaceAll(',', '');
    }
    if (!_plain.hasMatch(whole)) {
      return null;
    }
    final int value = int.parse(whole) * perPound + (cents == null ? 0 : int.parse(cents.padRight(2, '0')));
    return value <= maxTyped ? value : null;
  }

  /// "1,250.50" (or "1,250" for whole pounds). Western digits, read left to
  /// right inside Arabic text.
  static String digits(int piastres, {bool alwaysCents = false}) {
    final bool negative = piastres < 0;
    final int abs = piastres.abs();
    final String pounds = _group((abs ~/ perPound).toString());
    final int rest = abs % perPound;
    final String text = rest == 0 && !alwaysCents ? pounds : '$pounds.${rest.toString().padLeft(2, '0')}';
    return ltrIsolate(negative ? '-$text' : text);
  }

  static String _group(String n) {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < n.length; i++) {
      if (i > 0 && (n.length - i) % 3 == 0) {
        b.write(',');
      }
      b.write(n[i]);
    }
    return b.toString();
  }

  /// "EGP 1,250.50" / "1,250.50 ج.م" from the ARB pattern.
  static String format(AppLocalizations l10n, int piastres) => l10n.walletAmount(digits(piastres));

  /// [piastres] for what the parent typed, for the field (no grouping).
  static String typed(int piastres) {
    final int rest = piastres % perPound;
    return rest == 0 ? '${piastres ~/ perPound}' : '${piastres ~/ perPound}.${rest.toString().padLeft(2, '0')}';
  }

  /// A carpool contribution (F25): whole pounds per child times the parent's
  /// children in the carpool, in piastres. Integers only; 0 without children.
  static int contribution({required int poundsPerChild, required int children}) =>
      poundsPerChild * perPound * max(children, 0);
}

/// A new random request ID (UUID v4) for each money request. Kept while
/// the app retries the same request, so the server never runs it twice.
String newRequestId([Random? random]) {
  final Random r = random ?? Random.secure();
  final List<int> b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final String hex = b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

enum WalletStatus { none, active, frozen }

@immutable
class WalletLimits {
  const WalletLimits({this.minAmount = 100, this.perTransferMax = 200000, this.perDayMax = 500000, this.topUpMax = 500000});

  factory WalletLimits.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    const WalletLimits d = WalletLimits();
    return WalletLimits(
      minAmount: _int(m['minAmount']) ?? d.minAmount,
      perTransferMax: _int(m['perTransferMax']) ?? d.perTransferMax,
      perDayMax: _int(m['perDayMax']) ?? d.perDayMax,
      topUpMax: _int(m['topUpMax']) ?? d.topUpMax,
    );
  }

  final int minAmount;
  final int perTransferMax;
  final int perDayMax;
  final int topUpMax;
}

/// getWallet / openWallet.
@immutable
class WalletInfo {
  const WalletInfo({
    required this.available,
    required this.status,
    required this.termsVersion,
    this.balance,
    this.limits = const WalletLimits(),
    this.todayOut = 0,
  });

  factory WalletInfo.fromMap(Map<Object?, Object?> m) => WalletInfo(
    available: m['available'] != false,
    status: switch (m['status']) {
      'active' => WalletStatus.active,
      'frozen' => WalletStatus.frozen,
      _ => WalletStatus.none,
    },
    termsVersion: m['termsVersion'] is String ? m['termsVersion']! as String : '',
    balance: _int(m['balance']),
    limits: WalletLimits.fromMap(m['limits']),
    todayOut: _int(m['todayOut']) ?? 0,
  );

  /// False while the wallet partner is not switched on here.
  final bool available;
  final WalletStatus status;
  final String termsVersion;

  /// From the partner, in piastres.
  final int? balance;
  final WalletLimits limits;
  final int todayOut;

  bool get opened => status != WalletStatus.none;

  /// What may still go out today.
  int get leftToday => max(0, limits.perDayMax - todayOut);
}

enum TransferKind { transfer, topup, withdraw }

enum TransferStatus { pending, done, failed }

enum TransferFailReason { insufficientFunds, declined, senderFrozen, receiverFrozen, notReceived, partnerError }

/// One line of the history (listWalletHistory, getTransfer, a money result).
@immutable
class WalletTransfer {
  const WalletTransfer({
    required this.id,
    required this.kind,
    required this.outgoing,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.otherName = '',
    this.note = '',
    this.carpoolId,
    this.reason,
    this.settledAt,
  });

  factory WalletTransfer.fromMap(Map<Object?, Object?> m) => WalletTransfer(
    id: m['id'] is String ? m['id']! as String : '',
    kind: switch (m['kind']) {
      'topup' => TransferKind.topup,
      'withdraw' => TransferKind.withdraw,
      _ => TransferKind.transfer,
    },
    outgoing: m['direction'] == 'out',
    amount: _int(m['amount']) ?? 0,
    status: switch (m['status']) {
      'done' => TransferStatus.done,
      'failed' => TransferStatus.failed,
      _ => TransferStatus.pending,
    },
    createdAt: DateTime.fromMillisecondsSinceEpoch(_int(m['createdAtMs']) ?? 0, isUtc: true),
    otherName: m['otherName'] is String ? m['otherName']! as String : '',
    note: m['note'] is String ? m['note']! as String : '',
    carpoolId: m['carpoolId'] is String ? m['carpoolId']! as String : null,
    reason: switch (m['reason']) {
      'insufficient-funds' => TransferFailReason.insufficientFunds,
      'declined' => TransferFailReason.declined,
      'sender-frozen' => TransferFailReason.senderFrozen,
      'receiver-frozen' => TransferFailReason.receiverFrozen,
      'not-received' => TransferFailReason.notReceived,
      'partner-error' => TransferFailReason.partnerError,
      _ => null,
    },
    settledAt: _int(m['settledAtMs']) == null ? null : DateTime.fromMillisecondsSinceEpoch(_int(m['settledAtMs'])!, isUtc: true),
  );

  final String id;
  final TransferKind kind;

  /// Sent or withdrawn by me (else received or added).
  final bool outgoing;
  final int amount;
  final TransferStatus status;
  final DateTime createdAt;

  /// The other parent's first name (transfers only).
  final String otherName;
  final String note;
  final String? carpoolId;
  final TransferFailReason? reason;
  final DateTime? settledAt;
}

@immutable
class WalletPage {
  const WalletPage({required this.transfers, this.nextAfterId});

  final List<WalletTransfer> transfers;
  final String? nextAfterId;
}

/// What a parent ID lookup shows: the first name and the badge only (F44).
@immutable
class ReceiverPreview {
  const ReceiverPreview({required this.firstName, required this.verified});

  final String firstName;
  final bool verified;
}

/// A parent of one of my carpools (walletContacts).
@immutable
class WalletContact {
  const WalletContact({
    required this.uid,
    required this.firstName,
    required this.verified,
    required this.carpoolId,
    this.carpoolNameAr = '',
    this.carpoolNameEn = '',
    this.isAdmin = false,
  });

  factory WalletContact.fromMap(Map<Object?, Object?> m) => WalletContact(
    uid: m['uid'] is String ? m['uid']! as String : '',
    firstName: m['firstName'] is String ? m['firstName']! as String : '',
    verified: m['verified'] == true,
    carpoolId: m['carpoolId'] is String ? m['carpoolId']! as String : '',
    carpoolNameAr: m['carpoolNameAr'] is String ? m['carpoolNameAr']! as String : '',
    carpoolNameEn: m['carpoolNameEn'] is String ? m['carpoolNameEn']! as String : '',
    isAdmin: m['isAdmin'] == true,
  );

  final String uid;
  final String firstName;
  final bool verified;
  final String carpoolId;
  final String carpoolNameAr;
  final String carpoolNameEn;
  final bool isAdmin;

  String carpoolName(String language) => language == 'en' && carpoolNameEn.isNotEmpty ? carpoolNameEn : carpoolNameAr;
}

/// Who gets the money: chosen from a carpool (uid) or typed (parent ID).
class Receiver {
  Receiver.contact(WalletContact c)
    : uid = c.uid,
      parentId = null,
      firstName = c.firstName,
      verified = c.verified,
      carpoolId = c.carpoolId;

  Receiver.byParentId(String id, ReceiverPreview preview)
    : uid = null,
      parentId = id,
      firstName = preview.firstName,
      verified = preview.verified,
      carpoolId = null;

  final String? uid;
  final String? parentId;
  final String firstName;
  final bool verified;
  final String? carpoolId;
}

/// One Send, as the server gets it.
@immutable
class SendRequest {
  const SendRequest({required this.requestId, required this.receiver, required this.amount, this.note = '', this.carpoolId});

  final String requestId;
  final Receiver receiver;
  final int amount;
  final String note;

  /// Paying a carpool contribution (F25).
  final String? carpoolId;

  Map<String, Object?> toJson() {
    final String? carpool = carpoolId ?? receiver.carpoolId;
    return <String, Object?>{
      'requestId': requestId,
      'amount': amount,
      'toUid': ?receiver.uid,
      'toParentId': ?receiver.parentId,
      if (note.isNotEmpty) 'note': note,
      'carpoolId': ?carpool,
    };
  }
}

@immutable
class MoneyResult {
  const MoneyResult({required this.transfer, this.checkoutUrl});

  final WalletTransfer transfer;

  /// Top-up with the real partner: the page where the parent pays.
  final String? checkoutUrl;
}

enum WalletReportReason { notReceived, wrongAmount, wrongPerson, unauthorized, other }

/// Parent ID shape (F44): 8 characters without 0, O, 1 or I.
abstract final class ParentIds {
  static final RegExp _pattern = RegExp(r'^[2-9A-HJ-NP-Z]{8}$');

  /// Upper case, spaces and dashes removed.
  static String normalize(String input) => input.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  static bool isValid(String input) => _pattern.hasMatch(normalize(input));
}

enum WalletFailureKind {
  offline,
  notVerified,
  suspended,
  noWallet,
  termsRequired,
  frozen,
  receiverNotFound,
  receiverCannotReceive,
  self,
  notInCarpool,
  amountTooSmall,
  overTransferLimit,
  overDailyLimit,
  tooManyToday,
  requestReused,
  notFound,
  rateLimited,
  walletOff,
  unavailable,
  noPasscode,
  unknown,
}

class WalletFailure implements AppFailure {
  const WalletFailure(this.kind, {this.demo, this.amount});

  factory WalletFailure.from(Object error) {
    if (error is WalletFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return WalletFailure(WalletFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Map<Object?, Object?> d = details is Map<Object?, Object?> ? details : const <Object?, Object?>{};
      final WalletFailureKind kind = switch (d['reason']) {
        'not-verified' => WalletFailureKind.notVerified,
        'suspended' => WalletFailureKind.suspended,
        'no-wallet' => WalletFailureKind.noWallet,
        'terms-required' => WalletFailureKind.termsRequired,
        'frozen' => WalletFailureKind.frozen,
        'receiver-not-found' => WalletFailureKind.receiverNotFound,
        'receiver-cannot-receive' => WalletFailureKind.receiverCannotReceive,
        'self' => WalletFailureKind.self,
        'not-in-carpool' => WalletFailureKind.notInCarpool,
        'amount-too-small' => WalletFailureKind.amountTooSmall,
        'over-transfer-limit' => WalletFailureKind.overTransferLimit,
        'over-daily-limit' => WalletFailureKind.overDailyLimit,
        'too-many-today' => WalletFailureKind.tooManyToday,
        'request-reused' => WalletFailureKind.requestReused,
        'not-found' => WalletFailureKind.notFound,
        'rate-limited' => WalletFailureKind.rateLimited,
        'wallet-off' => WalletFailureKind.walletOff,
        'wallet-unavailable' => WalletFailureKind.unavailable,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => WalletFailureKind.offline,
          _ => WalletFailureKind.unknown,
        },
      };
      return WalletFailure(kind, amount: _int(d['left']) ?? _int(d['limit']) ?? _int(d['min']));
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const WalletFailure(WalletFailureKind.offline);
    }
    return const WalletFailure(WalletFailureKind.unknown);
  }

  final WalletFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  /// The limit, what is left today, or the smallest amount (piastres).
  final int? amount;

  @override
  bool get isOffline => kind == WalletFailureKind.offline;

  /// The request may or may not have reached the server: the same request
  /// ID must be sent again (never a new one) to learn what happened.
  bool get outcomeUnknown => kind == WalletFailureKind.offline || kind == WalletFailureKind.unavailable || kind == WalletFailureKind.unknown;

  /// One short sentence that says what happened and what to do.
  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    WalletFailureKind.offline => l10n.errorOfflineShort,
    WalletFailureKind.notVerified => l10n.walletErrorNotVerified,
    WalletFailureKind.suspended => l10n.walletErrorSuspended,
    WalletFailureKind.noWallet => l10n.walletErrorNoWallet,
    WalletFailureKind.termsRequired => l10n.walletErrorTerms,
    WalletFailureKind.frozen => l10n.walletErrorFrozen,
    WalletFailureKind.receiverNotFound => l10n.walletErrorReceiverNotFound,
    WalletFailureKind.receiverCannotReceive => l10n.walletErrorReceiverCannot,
    WalletFailureKind.self => l10n.walletErrorSelf,
    WalletFailureKind.notInCarpool => l10n.walletErrorNotInCarpool,
    WalletFailureKind.amountTooSmall => l10n.walletErrorTooSmall(Money.format(l10n, amount ?? 100)),
    WalletFailureKind.overTransferLimit => l10n.walletErrorOverLimit(Money.format(l10n, amount ?? 0)),
    WalletFailureKind.overDailyLimit => l10n.walletErrorOverDaily(Money.format(l10n, amount ?? 0)),
    WalletFailureKind.tooManyToday => l10n.walletErrorTooMany,
    WalletFailureKind.requestReused => l10n.walletErrorUnknown,
    WalletFailureKind.notFound => l10n.walletErrorNotFound,
    WalletFailureKind.rateLimited => l10n.walletErrorRateLimited,
    WalletFailureKind.walletOff => l10n.walletErrorOff,
    WalletFailureKind.unavailable => l10n.walletErrorUnavailable,
    WalletFailureKind.noPasscode => l10n.walletErrorNoPasscode,
    WalletFailureKind.unknown => l10n.walletErrorUnknown,
  };

  @override
  String toString() => 'WalletFailure(${kind.name})';
}

Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const <Object?, Object?>{};

int? _int(Object? value) => value is int ? value : (value is num && value == value.roundToDouble() ? value.toInt() : null);
