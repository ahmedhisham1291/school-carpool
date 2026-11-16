import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';

/// Settle up by InstaPay (F45), the pilot's payment feature.
///
/// The app never moves, holds or sees money and never asks for bank or
/// card details. It shows records of payment requests between two parents
/// of a carpool (requested, paid, received) and the payee's InstaPay
/// address so the payer can pay in the InstaPay app. Every change goes
/// through Cloud Functions; the app only reads its own records.
///
/// Amounts are whole piastres (100 per Egyptian pound), like the wallet's.

/// An InstaPay address (IPA): `name@instapay`. Same rule as the server
/// (functions/src/settle_up/model.ts): Latin letters, digits, dot, hyphen
/// and underscore, starting with a letter or digit, 3 to 50 characters,
/// then `@instapay`; stored in lower case. Only the shape is checked: the
/// InstaPay app shows the receiver's name before the payer confirms.
abstract final class InstaPayAddress {
  static const String suffix = '@instapay';
  static final RegExp _shape = RegExp(r'^[a-z0-9][a-z0-9._-]{2,49}@instapay$');

  /// The stored form, or null when [input] is not an InstaPay address. A
  /// name typed without the ending gets it ("mona.ali" is "mona.ali@instapay").
  static String? normalize(String input) {
    String v = input.trim().toLowerCase();
    if (v.isNotEmpty && !v.contains('@')) {
      v = '$v$suffix';
    }
    return _shape.hasMatch(v) ? v : null;
  }

  static bool isValid(String input) => normalize(input) != null;
}

enum SettleStatus {
  open,
  paid,
  closed,
  cancelled,
  declined;

  /// Nothing more can happen to the record.
  bool get finished => this == closed || this == cancelled || this == declined;

  /// An unknown state is shown as cancelled, never as open.
  static SettleStatus fromWire(Object? v) => values.firstWhere((SettleStatus s) => s.name == v, orElse: () => SettleStatus.cancelled);
}

enum SettleReason {
  contribution,
  fuel,
  other;

  static SettleReason fromWire(Object? v) => values.firstWhere((SettleReason r) => r.name == v, orElse: () => SettleReason.other);
}

/// The side of a record: the payee receives, the payer pays.
enum SettleRole {
  payee,
  payer;

  static SettleRole? fromWire(Object? v) {
    for (final SettleRole r in values) {
      if (r.name == v) {
        return r;
      }
    }
    return null;
  }
}

/// What a party can do (the server checks who and when).
enum SettleAction { paid, received, notReceived, cancel, decline }

enum SettleEventType {
  requested('requested'),
  recorded('recorded'),
  paid('paid'),
  received('received'),
  notReceived('not-received'),
  cancelled('cancelled'),
  declined('declined'),
  reported('reported'),
  accountClosed('account-closed');

  const SettleEventType(this.wire);

  final String wire;

  static SettleEventType? fromWire(Object? v) {
    for (final SettleEventType t in values) {
      if (t.wire == v) {
        return t;
      }
    }
    return null;
  }
}

/// One entry of the record's history (append-only on the server).
@immutable
class SettleEvent {
  const SettleEvent({required this.type, required this.by, required this.at});

  final SettleEventType type;

  /// Null: the system (an account was closed).
  final SettleRole? by;
  final DateTime at;
}

DateTime _time(Object? stamp, Object? millis) {
  if (stamp is Timestamp) {
    return stamp.toDate().toUtc();
  }
  if (millis is num) {
    return DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true);
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

String _text(Object? v) => v is String ? v : '';

int _int(Object? v) => v is int ? v : (v is num && v == v.roundToDouble() ? v.toInt() : 0);

/// One payment record between a payee and a payer.
@immutable
class SettleUp {
  const SettleUp({
    required this.id,
    required this.payeeUid,
    required this.payerUid,
    required this.payeeFirstName,
    required this.payerFirstName,
    required this.amount,
    required this.reason,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = SettleRole.payee,
    this.carpoolId = '',
    this.note = '',
    this.notReceived = 0,
    this.reportedBy = const <SettleRole>[],
    this.events = const <SettleEvent>[],
  });

  /// From the Firestore document (timestamps) or a function's answer
  /// (milliseconds): the same fields either way.
  factory SettleUp.fromMap(String id, Map<Object?, Object?> m) {
    final Object? rawEvents = m['events'];
    final Object? rawReported = m['reportedBy'];
    return SettleUp(
      id: id,
      createdBy: SettleRole.fromWire(m['createdBy']) ?? SettleRole.payee,
      payeeUid: _text(m['payeeUid']),
      payerUid: _text(m['payerUid']),
      payeeFirstName: _text(m['payeeFirstName']),
      payerFirstName: _text(m['payerFirstName']),
      carpoolId: _text(m['carpoolId']),
      amount: _int(m['amount']),
      reason: SettleReason.fromWire(m['reason']),
      note: _text(m['note']),
      status: SettleStatus.fromWire(m['status']),
      notReceived: _int(m['notReceived']),
      reportedBy: <SettleRole>[
        if (rawReported is List<Object?>)
          for (final Object? r in rawReported) ?SettleRole.fromWire(r),
      ],
      events: <SettleEvent>[
        if (rawEvents is List<Object?>)
          for (final Object? e in rawEvents)
            if (e is Map<Object?, Object?> && SettleEventType.fromWire(e['type']) != null)
              SettleEvent(type: SettleEventType.fromWire(e['type'])!, by: SettleRole.fromWire(e['by']), at: _time(e['at'], e['atMs'])),
      ],
      createdAt: _time(m['createdAt'], m['createdAtMs']),
      updatedAt: _time(m['updatedAt'], m['updatedAtMs']),
    );
  }

  final String id;
  final SettleRole createdBy;
  final String payeeUid;
  final String payerUid;
  final String payeeFirstName;
  final String payerFirstName;
  final String carpoolId;

  /// Piastres.
  final int amount;
  final SettleReason reason;
  final String note;
  final SettleStatus status;

  /// "Not received" marks so far.
  final int notReceived;
  final List<SettleRole> reportedBy;
  final List<SettleEvent> events;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// My side of the record, or null when it is not mine.
  SettleRole? roleOf(String uid) {
    if (uid.isEmpty) {
      return null;
    }
    if (payeeUid == uid) {
      return SettleRole.payee;
    }
    if (payerUid == uid) {
      return SettleRole.payer;
    }
    return null;
  }

  /// The other parent's first name (an initial once their account is deleted).
  String otherName(SettleRole mine) => mine == SettleRole.payee ? payerFirstName : payeeFirstName;

  String otherUid(SettleRole mine) => mine == SettleRole.payee ? payerUid : payeeUid;

  /// What [role] may do now (the same table as the server's state machine).
  List<SettleAction> actionsFor(SettleRole role) => switch ((status, role)) {
    (SettleStatus.open, SettleRole.payer) => const <SettleAction>[SettleAction.paid, SettleAction.decline],
    (SettleStatus.open, SettleRole.payee) => const <SettleAction>[SettleAction.cancel],
    (SettleStatus.paid, SettleRole.payee) => const <SettleAction>[SettleAction.received, SettleAction.notReceived],
    _ => const <SettleAction>[],
  };

  /// Either side may report once it bounced [reportAfter] times, once each.
  bool canReport(SettleRole role, int reportAfter) => notReceived >= reportAfter && !reportedBy.contains(role);
}

/// "You owe / owes you" with one parent, from records that are not finished.
@immutable
class PersonSummary {
  const PersonSummary({required this.uid, required this.firstName, this.youOwe = 0, this.owesYou = 0, this.waiting = 0});

  final String uid;
  final String firstName;

  /// Open requests where I am the payer (piastres).
  final int youOwe;

  /// Open requests where I am the payee.
  final int owesYou;

  /// Payments marked paid that wait for a confirmation (either way).
  final int waiting;
}

/// Per person, sorted by first name. Finished records count for nothing.
List<PersonSummary> summarizeSettleUps(List<SettleUp> records, String uid) {
  final Map<String, PersonSummary> out = <String, PersonSummary>{};
  for (final SettleUp r in records) {
    final SettleRole? role = r.roleOf(uid);
    if (role == null || r.status.finished) {
      continue;
    }
    final String other = r.otherUid(role);
    final PersonSummary row = out[other] ?? PersonSummary(uid: other, firstName: r.otherName(role));
    out[other] = PersonSummary(
      uid: other,
      firstName: row.firstName,
      youOwe: row.youOwe + (r.status == SettleStatus.open && role == SettleRole.payer ? r.amount : 0),
      owesYou: row.owesYou + (r.status == SettleStatus.open && role == SettleRole.payee ? r.amount : 0),
      waiting: row.waiting + (r.status == SettleStatus.paid ? r.amount : 0),
    );
  }
  final List<PersonSummary> list = out.values.toList()
    ..sort((PersonSummary a, PersonSummary b) {
      final int byName = a.firstName.compareTo(b.firstName);
      return byName != 0 ? byName : a.uid.compareTo(b.uid);
    });
  return list;
}

/// The caller's own InstaPay address and the limits the form shows.
@immutable
class SettleProfile {
  const SettleProfile({this.address, this.maxAmount = defaultMaxAmount, this.reportAfter = 2});

  factory SettleProfile.fromMap(Map<Object?, Object?> m) {
    final int max = _int(m['maxAmount']);
    final int after = _int(m['reportAfter']);
    final Object? own = m['address'];
    return SettleProfile(
      address: own is String && own.isNotEmpty ? own : null,
      maxAmount: max > 0 ? max : defaultMaxAmount,
      reportAfter: after > 0 ? after : 2,
    );
  }

  /// EGP 5,000 (the server's default).
  static const int defaultMaxAmount = 5000 * Money.perPound;

  /// EGP 1.
  static const int minAmount = Money.perPound;

  final String? address;
  final int maxAmount;
  final int reportAfter;
}

/// A parent of one of my carpools.
@immutable
class SettleContact {
  const SettleContact({
    required this.uid,
    required this.firstName,
    required this.carpoolId,
    this.verified = true,
    this.carpoolNameAr = '',
    this.carpoolNameEn = '',
  });

  factory SettleContact.fromMap(Map<Object?, Object?> m) => SettleContact(
    uid: _text(m['uid']),
    firstName: _text(m['firstName']),
    verified: m['verified'] == true,
    carpoolId: _text(m['carpoolId']),
    carpoolNameAr: _text(m['carpoolNameAr']),
    carpoolNameEn: _text(m['carpoolNameEn']),
  );

  final String uid;
  final String firstName;
  final bool verified;
  final String carpoolId;
  final String carpoolNameAr;
  final String carpoolNameEn;

  String carpoolName(String languageCode) => languageCode == 'ar' || carpoolNameEn.isEmpty ? carpoolNameAr : carpoolNameEn;
}

/// A new record. [paid]: I already paid (I am the payer); otherwise I ask
/// the other parent to pay me. One [requestId] per record: a retry sends
/// the same one and the server creates it once.
@immutable
class SettleCreate {
  const SettleCreate({
    required this.requestId,
    required this.paid,
    required this.otherUid,
    required this.carpoolId,
    required this.amount,
    required this.reason,
    this.note = '',
  });

  final String requestId;
  final bool paid;
  final String otherUid;
  final String carpoolId;
  final int amount;
  final SettleReason reason;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'kind': paid ? 'paid' : 'request',
    'otherUid': otherUid,
    'carpoolId': carpoolId,
    'amount': amount,
    'reason': reason.name,
    if (note.isNotEmpty) 'note': note,
  };
}

enum SettleFailureKind {
  offline,
  featureOff,
  invalidAddress,
  invalidAmount,
  amountTooHigh,
  notVerified,
  suspended,
  notAllowed,
  noAddress,
  notFound,
  invalidState,
  tooManyOpen,
  reportTooEarly,
  alreadyReported,
  rateLimited,
  deviceCheck,
  unavailable,
  unknown,
}

/// A settle-up problem with one sentence that says what to do. Built from
/// `details.reason` of our functions.
class SettleFailure implements Exception {
  const SettleFailure(this.kind, {this.demo, this.amount});

  factory SettleFailure.from(Object error) {
    if (error is SettleFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return SettleFailure(SettleFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Map<Object?, Object?> d = details is Map<Object?, Object?> ? details : const <Object?, Object?>{};
      final SettleFailureKind kind = switch (d['reason']) {
        'feature-off' => SettleFailureKind.featureOff,
        'invalid-address' => SettleFailureKind.invalidAddress,
        'invalid-amount' => SettleFailureKind.invalidAmount,
        'amount-too-high' => SettleFailureKind.amountTooHigh,
        'not-verified' || 'no-account' => SettleFailureKind.notVerified,
        'suspended' => SettleFailureKind.suspended,
        'not-allowed' || 'self' => SettleFailureKind.notAllowed,
        'no-address' => SettleFailureKind.noAddress,
        'not-found' => SettleFailureKind.notFound,
        'invalid-state' || 'request-reused' => SettleFailureKind.invalidState,
        'too-many-open' => SettleFailureKind.tooManyOpen,
        'report-too-early' => SettleFailureKind.reportTooEarly,
        'already-reported' => SettleFailureKind.alreadyReported,
        'rate-limited' => SettleFailureKind.rateLimited,
        'device-check' => SettleFailureKind.deviceCheck,
        'settle-up-unavailable' => SettleFailureKind.unavailable,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => SettleFailureKind.offline,
          _ => SettleFailureKind.unknown,
        },
      };
      final int max = _int(d['maxAmount']);
      return SettleFailure(kind, amount: max > 0 ? max : null);
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const SettleFailure(SettleFailureKind.offline);
    }
    return const SettleFailure(SettleFailureKind.unknown);
  }

  final SettleFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  /// The largest amount allowed (piastres), when the server said.
  final int? amount;

  bool get isOffline => kind == SettleFailureKind.offline;

  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    SettleFailureKind.offline => l10n.errorOfflineShort,
    SettleFailureKind.featureOff => l10n.featureOffBody,
    SettleFailureKind.invalidAddress => l10n.settleAddressInvalid,
    SettleFailureKind.invalidAmount => l10n.settleAmountInvalid,
    SettleFailureKind.amountTooHigh => l10n.settleAmountTooHigh(Money.format(l10n, amount ?? SettleProfile.defaultMaxAmount)),
    SettleFailureKind.notVerified => l10n.settleErrorNotVerified,
    SettleFailureKind.suspended => l10n.settleErrorSuspended,
    SettleFailureKind.notAllowed => l10n.settleErrorNotAllowed,
    SettleFailureKind.noAddress => l10n.settleErrorNoAddress,
    SettleFailureKind.notFound => l10n.settleErrorNotFound,
    SettleFailureKind.invalidState => l10n.settleErrorState,
    SettleFailureKind.tooManyOpen => l10n.settleErrorTooManyOpen,
    SettleFailureKind.reportTooEarly => l10n.settleErrorState,
    SettleFailureKind.alreadyReported => l10n.settleErrorReported,
    SettleFailureKind.rateLimited => l10n.settleErrorRateLimited,
    SettleFailureKind.deviceCheck => l10n.settleErrorDeviceCheck,
    SettleFailureKind.unavailable || SettleFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'SettleFailure(${kind.name})';
}
