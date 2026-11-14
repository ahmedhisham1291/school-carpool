import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/features/wallet/wallet_repository.dart';

/// Monday 16 Nov 2026, 10:00 UTC: the fixed "now" of wallet tests.
final DateTime walletNow = DateTime.utc(2026, 11, 16, 10);

/// An open wallet with 500 EGP of test money (fake data only).
const WalletInfo openWallet = WalletInfo(available: true, status: WalletStatus.active, termsVersion: '2026-11-14', balance: 50000);

const WalletInfo closedWallet = WalletInfo(available: true, status: WalletStatus.none, termsVersion: '2026-11-14');

List<WalletTransfer> sampleTransfers() => <WalletTransfer>[
  WalletTransfer(
    id: 't_1',
    kind: TransferKind.transfer,
    outgoing: false,
    amount: 30000,
    status: TransferStatus.done,
    createdAt: walletNow.subtract(const Duration(hours: 2)),
    otherName: 'Hoda',
    note: 'Week 1',
  ),
  WalletTransfer(
    id: 't_2',
    kind: TransferKind.transfer,
    outgoing: true,
    amount: 12550,
    status: TransferStatus.pending,
    createdAt: walletNow.subtract(const Duration(days: 1)),
    otherName: 'Badr',
  ),
  WalletTransfer(
    id: 't_3',
    kind: TransferKind.withdraw,
    outgoing: true,
    amount: 5000,
    status: TransferStatus.failed,
    reason: TransferFailReason.insufficientFunds,
    createdAt: walletNow.subtract(const Duration(days: 2)),
  ),
];

const List<WalletContact> sampleContacts = <WalletContact>[
  WalletContact(uid: 'uid-hoda', firstName: 'Hoda', verified: true, carpoolId: 'c-k1', carpoolNameAr: 'مدرسة النيل', carpoolNameEn: 'Nile School', isAdmin: true),
  WalletContact(uid: 'uid-badr', firstName: 'Badr', verified: true, carpoolId: 'c-k1', carpoolNameAr: 'مدرسة النيل', carpoolNameEn: 'Nile School'),
];

/// Records calls and answers like the server: one transfer per request ID.
class FakeWalletRepository implements WalletRepository {
  FakeWalletRepository({this._info = openWallet, List<WalletTransfer>? transfers, List<WalletContact>? contacts})
    : transfers = transfers ?? sampleTransfers(),
      contactList = contacts ?? sampleContacts;

  WalletInfo _info;
  List<WalletTransfer> transfers;
  List<WalletContact> contactList;
  final List<String> calls = <String>[];

  /// Thrown by the next call of any kind (then cleared when [failOnce]).
  WalletFailure? failure;
  bool failOnce = true;

  /// Parent IDs the lookup knows.
  Map<String, ReceiverPreview> parents = <String, ReceiverPreview>{'HUDA2345': const ReceiverPreview(firstName: 'Hoda', verified: true)};

  /// What a new send ends as.
  TransferStatus nextStatus = TransferStatus.done;

  /// Keeps sends waiting until completed (double tap tests).
  Completer<void>? hold;

  /// Results by request ID: a retry gets the first result.
  final Map<String, MoneyResult> byRequest = <String, MoneyResult>{};
  final List<SendRequest> sends = <SendRequest>[];
  final List<(WalletReportReason, String)> reports = <(WalletReportReason, String)>[];
  String? openedWith;

  WalletInfo get info => _info;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final WalletFailure? f = failure;
    if (f != null) {
      if (failOnce) {
        failure = null;
      }
      throw f;
    }
  }

  @override
  Future<WalletInfo> wallet() async {
    await _maybeFail('wallet');
    return _info;
  }

  @override
  Future<WalletInfo> open({required String termsVersion}) async {
    await _maybeFail('open');
    openedWith = termsVersion;
    _info = WalletInfo(available: true, status: WalletStatus.active, termsVersion: termsVersion, balance: 0);
    return _info;
  }

  @override
  Future<WalletPage> history({String? afterId}) async {
    await _maybeFail('history');
    return WalletPage(transfers: List<WalletTransfer>.of(transfers));
  }

  @override
  Future<WalletTransfer> transfer(String id) async {
    await _maybeFail('transfer:$id');
    return transfers.firstWhere((WalletTransfer t) => t.id == id, orElse: () => throw const WalletFailure(WalletFailureKind.notFound));
  }

  @override
  Future<ReceiverPreview> lookup(String parentId) async {
    await _maybeFail('lookup:$parentId');
    final ReceiverPreview? p = parents[parentId];
    if (p == null) {
      throw const WalletFailure(WalletFailureKind.receiverNotFound);
    }
    return p;
  }

  @override
  Future<List<WalletContact>> contacts({String? carpoolId}) async {
    await _maybeFail('contacts:${carpoolId ?? ''}');
    return <WalletContact>[
      for (final WalletContact c in contactList)
        if (carpoolId == null || c.carpoolId == carpoolId) c,
    ];
  }

  MoneyResult _record(String requestId, WalletTransfer t) {
    final MoneyResult r = MoneyResult(transfer: t);
    byRequest[requestId] = r;
    transfers = <WalletTransfer>[t, ...transfers];
    return r;
  }

  @override
  Future<MoneyResult> send(SendRequest request) async {
    sends.add(request);
    await _maybeFail('send:${request.requestId}');
    final Completer<void>? h = hold;
    if (h != null) {
      await h.future;
    }
    final MoneyResult? earlier = byRequest[request.requestId];
    if (earlier != null) {
      return earlier;
    }
    final WalletTransfer t = WalletTransfer(
      id: 't_new${byRequest.length}',
      kind: TransferKind.transfer,
      outgoing: true,
      amount: request.amount,
      status: nextStatus,
      createdAt: walletNow,
      otherName: request.receiver.firstName,
      note: request.note,
      carpoolId: request.carpoolId ?? request.receiver.carpoolId,
      reason: nextStatus == TransferStatus.failed ? TransferFailReason.insufficientFunds : null,
    );
    return _record(request.requestId, t);
  }

  @override
  Future<MoneyResult> addMoney({required String requestId, required int amount}) async {
    await _maybeFail('add:$requestId:$amount');
    return byRequest[requestId] ??
        _record(
          requestId,
          WalletTransfer(id: 't_add${byRequest.length}', kind: TransferKind.topup, outgoing: false, amount: amount, status: TransferStatus.done, createdAt: walletNow),
        );
  }

  @override
  Future<MoneyResult> withdraw({required String requestId, required int amount}) async {
    await _maybeFail('withdraw:$requestId:$amount');
    return byRequest[requestId] ??
        _record(
          requestId,
          WalletTransfer(id: 't_wd${byRequest.length}', kind: TransferKind.withdraw, outgoing: true, amount: amount, status: TransferStatus.done, createdAt: walletNow),
        );
  }

  @override
  Future<bool> report({required String transferId, required WalletReportReason reason, String note = ''}) async {
    await _maybeFail('report:$transferId:${reason.name}');
    reports.add((reason, note));
    return reason == WalletReportReason.unauthorized;
  }
}

/// Answers every check with [result] and counts the checks.
class FakeDeviceAuth implements DeviceAuth {
  FakeDeviceAuth([this.result = DeviceAuthResult.ok]);

  DeviceAuthResult result;
  final List<String> reasons = <String>[];

  @override
  Future<DeviceAuthResult> confirm(String reason) async {
    reasons.add(reason);
    return result;
  }
}

/// Wallet overrides for widget tests: always the same four.
List<Override> walletOverrides({FakeWalletRepository? repository, FakeDeviceAuth? auth}) {
  int n = 0;
  return <Override>[
    walletRepositoryProvider.overrideWithValue(repository ?? FakeWalletRepository()),
    deviceAuthProvider.overrideWithValue(auth ?? FakeDeviceAuth()),
    walletClockProvider.overrideWithValue(() => walletNow),
    requestIdFactoryProvider.overrideWithValue(() => 'req-${(++n).toString().padLeft(16, '0')}'),
  ];
}
