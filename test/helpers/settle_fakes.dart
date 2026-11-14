import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_repository.dart';

/// Monday 16 Nov 2026, 10:00 UTC: the fixed "now" of settle-up tests.
final DateTime settleNow = DateTime.utc(2026, 11, 16, 10);

/// The signed-in test parent (test_app.dart: testVerifiedSession).
const String settleMe = 'uid-1';

/// A fake InstaPay address (not a real one).
const String hodaAddress = 'hoda.test@instapay';

SettleUp settleRecord(
  String id, {
  required bool iPay,
  String other = 'Hoda',
  String otherUid = 'uid-hoda',
  int amount = 15000,
  SettleStatus status = SettleStatus.open,
  SettleReason reason = SettleReason.contribution,
  String note = '',
  int notReceived = 0,
  List<SettleRole> reportedBy = const <SettleRole>[],
  List<SettleEvent>? events,
}) => SettleUp(
  id: id,
  payeeUid: iPay ? otherUid : settleMe,
  payerUid: iPay ? settleMe : otherUid,
  payeeFirstName: iPay ? other : 'Mona',
  payerFirstName: iPay ? 'Mona' : other,
  carpoolId: 'c-k1',
  amount: amount,
  reason: reason,
  note: note,
  status: status,
  notReceived: notReceived,
  reportedBy: reportedBy,
  events: events ?? <SettleEvent>[SettleEvent(type: SettleEventType.requested, by: SettleRole.payee, at: settleNow.subtract(const Duration(hours: 3)))],
  createdAt: settleNow.subtract(const Duration(hours: 3)),
  updatedAt: settleNow.subtract(const Duration(hours: 3)),
);

/// Fake data only: I owe Hoda 150, Badr owes me 80, I paid Hoda 60 (waits
/// for her), and one finished record with Badr.
List<SettleUp> sampleSettleUps() => <SettleUp>[
  settleRecord('s_owe', iPay: true, note: 'Week 1'),
  settleRecord('s_owed', iPay: false, other: 'Badr', otherUid: 'uid-badr', amount: 8000, reason: SettleReason.fuel),
  settleRecord('s_waiting', iPay: true, amount: 6000, status: SettleStatus.paid),
  settleRecord('s_done', iPay: false, other: 'Badr', otherUid: 'uid-badr', amount: 5000, status: SettleStatus.closed),
];

const List<SettleContact> sampleSettleContacts = <SettleContact>[
  SettleContact(uid: 'uid-hoda', firstName: 'Hoda', carpoolId: 'c-k1', carpoolNameAr: 'مدرسة النيل', carpoolNameEn: 'Nile School'),
  SettleContact(uid: 'uid-badr', firstName: 'Badr', carpoolId: 'c-k1', carpoolNameAr: 'مدرسة النيل', carpoolNameEn: 'Nile School'),
  SettleContact(uid: 'uid-new', firstName: 'Nour', carpoolId: 'c-k2', verified: false, carpoolNameAr: 'نادي', carpoolNameEn: 'Club'),
];

/// Records calls and answers like the server: one record per request ID,
/// the same state machine, the payee's address only for the payer of an
/// open record.
class FakeSettleUpRepository implements SettleUpRepository {
  FakeSettleUpRepository({List<SettleUp>? records, this.myAddress = 'mona.test@instapay', List<SettleContact>? contacts})
    : records = records ?? sampleSettleUps(),
      contactList = contacts ?? sampleSettleContacts;

  List<SettleUp> records;
  List<SettleContact> contactList;

  /// My own saved address (null: none yet).
  String? myAddress;

  /// Other parents' addresses by uid (null value: not saved).
  Map<String, String?> addresses = <String, String?>{'uid-hoda': hodaAddress, 'uid-badr': null};
  int maxAmount = SettleProfile.defaultMaxAmount;
  final List<String> calls = <String>[];
  final List<SettleCreate> creates = <SettleCreate>[];
  final List<String> reports = <String>[];

  /// Thrown by the next call of any kind (then cleared when [failOnce]).
  SettleFailure? failure;
  bool failOnce = true;

  /// The record stream fails with this (offline, error states).
  Object? watchError;

  /// Keeps creates waiting until completed (double tap tests).
  Completer<void>? hold;

  final Map<String, SettleUp> _byRequest = <String, SettleUp>{};
  final StreamController<List<SettleUp>> _changes = StreamController<List<SettleUp>>.broadcast();

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final SettleFailure? f = failure;
    if (f != null) {
      if (failOnce) {
        failure = null;
      }
      throw f;
    }
  }

  void _emit() => _changes.add(List<SettleUp>.of(records));

  Future<void> dispose() => _changes.close();

  /// The other parent changed a record (the live list shows it).
  void replace(SettleUp next) {
    records = <SettleUp>[
      for (final SettleUp r in records)
        if (r.id == next.id) next else r,
    ];
    _emit();
  }

  @override
  Stream<List<SettleUp>> watch(String uid) async* {
    calls.add('watch:$uid');
    final Object? error = watchError;
    if (error != null) {
      throw error;
    }
    yield List<SettleUp>.of(records);
    yield* _changes.stream;
  }

  @override
  Future<SettleProfile> profile() async {
    await _maybeFail('profile');
    return SettleProfile(address: myAddress, maxAmount: maxAmount);
  }

  @override
  Future<String> saveAddress(String address) async {
    await _maybeFail('saveAddress:$address');
    myAddress = address;
    return address;
  }

  @override
  Future<void> removeAddress() async {
    await _maybeFail('removeAddress');
    myAddress = null;
  }

  @override
  Future<List<SettleContact>> contacts({String? carpoolId}) async {
    await _maybeFail('contacts:${carpoolId ?? ''}');
    return <SettleContact>[
      for (final SettleContact c in contactList)
        if (carpoolId == null || c.carpoolId == carpoolId) c,
    ];
  }

  @override
  Future<SettleUp> create(SettleCreate request) async {
    creates.add(request);
    await hold?.future;
    await _maybeFail('create');
    final SettleUp? before = _byRequest[request.requestId];
    if (before != null) {
      return before;
    }
    final SettleContact other = contactList.firstWhere((SettleContact c) => c.uid == request.otherUid);
    final SettleUp record = SettleUp(
      id: 's_new${_byRequest.length + 1}',
      createdBy: request.paid ? SettleRole.payer : SettleRole.payee,
      payeeUid: request.paid ? other.uid : settleMe,
      payerUid: request.paid ? settleMe : other.uid,
      payeeFirstName: request.paid ? other.firstName : 'Mona',
      payerFirstName: request.paid ? 'Mona' : other.firstName,
      carpoolId: request.carpoolId,
      amount: request.amount,
      reason: request.reason,
      note: request.note,
      status: request.paid ? SettleStatus.paid : SettleStatus.open,
      events: <SettleEvent>[
        SettleEvent(type: request.paid ? SettleEventType.recorded : SettleEventType.requested, by: request.paid ? SettleRole.payer : SettleRole.payee, at: settleNow),
      ],
      createdAt: settleNow,
      updatedAt: settleNow,
    );
    _byRequest[request.requestId] = record;
    records = <SettleUp>[record, ...records];
    _emit();
    return record;
  }

  @override
  Future<SettleUp> act(String id, SettleAction action) async {
    await _maybeFail('act:$id:${action.name}');
    final SettleUp r = records.firstWhere((SettleUp x) => x.id == id, orElse: () => throw const SettleFailure(SettleFailureKind.notFound));
    final SettleRole? mine = r.roleOf(settleMe);
    if (mine == null || !r.actionsFor(mine).contains(action)) {
      throw const SettleFailure(SettleFailureKind.invalidState);
    }
    final (SettleStatus status, SettleEventType type) = switch (action) {
      SettleAction.paid => (SettleStatus.paid, SettleEventType.paid),
      SettleAction.received => (SettleStatus.closed, SettleEventType.received),
      SettleAction.notReceived => (SettleStatus.open, SettleEventType.notReceived),
      SettleAction.cancel => (SettleStatus.cancelled, SettleEventType.cancelled),
      SettleAction.decline => (SettleStatus.declined, SettleEventType.declined),
    };
    final SettleUp next = SettleUp(
      id: r.id,
      createdBy: r.createdBy,
      payeeUid: r.payeeUid,
      payerUid: r.payerUid,
      payeeFirstName: r.payeeFirstName,
      payerFirstName: r.payerFirstName,
      carpoolId: r.carpoolId,
      amount: r.amount,
      reason: r.reason,
      note: r.note,
      status: status,
      notReceived: r.notReceived + (action == SettleAction.notReceived ? 1 : 0),
      reportedBy: r.reportedBy,
      events: <SettleEvent>[...r.events, SettleEvent(type: type, by: mine, at: settleNow)],
      createdAt: r.createdAt,
      updatedAt: settleNow,
    );
    replace(next);
    return next;
  }

  @override
  Future<String?> addressFor(String id) async {
    await _maybeFail('addressFor:$id');
    final SettleUp r = records.firstWhere((SettleUp x) => x.id == id, orElse: () => throw const SettleFailure(SettleFailureKind.notFound));
    if (r.roleOf(settleMe) != SettleRole.payer) {
      throw const SettleFailure(SettleFailureKind.notAllowed);
    }
    if (r.status != SettleStatus.open) {
      throw const SettleFailure(SettleFailureKind.invalidState);
    }
    return addresses[r.payeeUid];
  }

  @override
  Future<void> report(String id, {String note = ''}) async {
    await _maybeFail('report:$id');
    reports.add(id);
    final SettleUp r = records.firstWhere((SettleUp x) => x.id == id);
    final SettleRole mine = r.roleOf(settleMe) ?? SettleRole.payee;
    replace(
      SettleUp(
        id: r.id,
        createdBy: r.createdBy,
        payeeUid: r.payeeUid,
        payerUid: r.payerUid,
        payeeFirstName: r.payeeFirstName,
        payerFirstName: r.payerFirstName,
        carpoolId: r.carpoolId,
        amount: r.amount,
        reason: r.reason,
        note: r.note,
        status: r.status,
        notReceived: r.notReceived,
        reportedBy: <SettleRole>[...r.reportedBy, mine],
        events: <SettleEvent>[...r.events, SettleEvent(type: SettleEventType.reported, by: mine, at: settleNow)],
        createdAt: r.createdAt,
        updatedAt: settleNow,
      ),
    );
  }
}

/// Settle-up overrides for widget tests: always the same two.
List<Override> settleOverrides({FakeSettleUpRepository? repository}) {
  int n = 0;
  return <Override>[
    settleUpRepositoryProvider.overrideWithValue(repository ?? FakeSettleUpRepository()),
    settleRequestIdProvider.overrideWithValue(() => 'req-${(++n).toString().padLeft(16, '0')}'),
  ];
}
