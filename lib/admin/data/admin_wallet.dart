import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Wallet in the admin panel (Prompt 11B: F14, F43). Read-only transfer log,
/// one parent's wallet, freeze and unfreeze with a reason, and alerts
/// (unusual patterns, transfer problem reports). There is no way to move
/// money here: the functions behind it cannot either. Every view and change
/// is in the audit log. Every method throws [AdminFailure].
abstract interface class AdminWalletApi {
  Future<PagedResult<AdminTransfer>> transfers({String? uid, String? afterId});
  Future<AdminWallet> wallet(String uid);
  Future<void> setFrozen({required String uid, required bool frozen, required FreezeReason reason, String? note});
  Future<List<WalletAlert>> alerts({bool handled = false});
  Future<void> resolveAlert(String alertId, AlertOutcome outcome);
}

enum FreezeReason {
  fraudSuspected,
  parentAsked,
  stolenPhone,
  dispute,
  partnerRequest,
  other;

  static FreezeReason? fromName(Object? name) {
    for (final FreezeReason r in values) {
      if (r.name == name) {
        return r;
      }
    }
    return null;
  }
}

enum AlertOutcome { noIssue, frozen, sentToPartner, parentContacted, settledWithPartner }

@immutable
class AdminTransfer {
  const AdminTransfer({
    required this.id,
    required this.kind,
    required this.amount,
    required this.status,
    this.fromUid,
    this.toUid,
    this.fromFirstName = '',
    this.toFirstName = '',
    this.reason,
    this.createdAt,
  });

  factory AdminTransfer.fromJson(Json j) => AdminTransfer(
    id: j.str('id'),
    kind: j.str('kind', 'transfer'),
    amount: j.integer('amount'),
    status: j.str('status', 'pending'),
    fromUid: j.strOrNull('fromUid'),
    toUid: j.strOrNull('toUid'),
    fromFirstName: j.str('fromFirstName'),
    toFirstName: j.str('toFirstName'),
    reason: j.strOrNull('reason'),
    createdAt: j.time('createdAtMs'),
  );

  final String id;

  /// transfer, topup or withdraw.
  final String kind;

  /// Piastres.
  final int amount;

  /// pending, done or failed.
  final String status;
  final String? fromUid;
  final String? toUid;
  final String fromFirstName;
  final String toFirstName;
  final String? reason;
  final DateTime? createdAt;
}

@immutable
class PartnerTransaction {
  const PartnerTransaction({required this.requestId, required this.signedAmount, required this.status, this.at});

  factory PartnerTransaction.fromJson(Json j) => PartnerTransaction(
    requestId: j.str('requestId'),
    signedAmount: j.integer('signedAmount'),
    status: j.str('status'),
    at: j.time('atMs'),
  );

  final String requestId;
  final int signedAmount;
  final String status;
  final DateTime? at;
}

@immutable
class WalletAlert {
  const WalletAlert({required this.id, required this.kind, required this.uid, this.transferId, this.reason, this.note = '', this.count = 0, this.createdAt, this.outcome});

  factory WalletAlert.fromJson(Json j) => WalletAlert(
    id: j.str('id'),
    kind: j.str('kind'),
    uid: j.str('uid'),
    transferId: j.strOrNull('transferId'),
    reason: j.strOrNull('reason'),
    note: j.str('note'),
    count: j.integer('count'),
    createdAt: j.time('createdAtMs'),
    outcome: j.strOrNull('outcome'),
  );

  final String id;

  /// new-receivers, many-transfers or report.
  final String kind;
  final String uid;
  final String? transferId;
  final String? reason;
  final String note;
  final int count;
  final DateTime? createdAt;
  final String? outcome;
}

@immutable
class AdminWallet {
  const AdminWallet({
    required this.uid,
    required this.status,
    this.frozenReason,
    this.balance,
    this.balanceCopy,
    this.partnerTransactions = const <PartnerTransaction>[],
    this.transfers = const <AdminTransfer>[],
    this.alerts = const <WalletAlert>[],
  });

  factory AdminWallet.fromJson(Json j) => AdminWallet(
    uid: j.str('uid'),
    status: j.str('status', 'none'),
    frozenReason: FreezeReason.fromName(j.map['frozenReason']),
    balance: j.map['balance'] is num ? j.integer('balance') : null,
    balanceCopy: j.map['balanceCopy'] is num ? j.integer('balanceCopy') : null,
    partnerTransactions: j.list('partnerTransactions').map(PartnerTransaction.fromJson).toList(),
    transfers: j.list('transfers').map(AdminTransfer.fromJson).toList(),
    alerts: j.list('alerts').map(WalletAlert.fromJson).toList(),
  );

  final String uid;

  /// none, active or frozen.
  final String status;
  final FreezeReason? frozenReason;

  /// From the partner; null when it did not answer.
  final int? balance;
  final int? balanceCopy;
  final List<PartnerTransaction> partnerTransactions;
  final List<AdminTransfer> transfers;
  final List<WalletAlert> alerts;

  bool get frozen => status == 'frozen';
}

class FirebaseAdminWalletApi implements AdminWalletApi {
  FirebaseAdminWalletApi(this._functions);

  final FirebaseFunctions _functions;

  Future<Json> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(seconds: 30)))
          .call<Object?>(data);
      return Json.of(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AdminFailure.from(error), stackTrace);
    }
  }

  @override
  Future<PagedResult<AdminTransfer>> transfers({String? uid, String? afterId}) async {
    final Json j = await _call('adminListTransfers', <String, Object?>{'uid': ?uid, 'afterId': ?afterId});
    return PagedResult<AdminTransfer>(j.list('transfers').map(AdminTransfer.fromJson).toList(), j.strOrNull('nextAfterId'));
  }

  @override
  Future<AdminWallet> wallet(String uid) async => AdminWallet.fromJson(await _call('adminGetWallet', <String, Object?>{'uid': uid}));

  @override
  Future<void> setFrozen({required String uid, required bool frozen, required FreezeReason reason, String? note}) async {
    await _call('adminSetWalletFrozen', <String, Object?>{'uid': uid, 'frozen': frozen, 'reasonCode': reason.name, 'note': ?note});
  }

  @override
  Future<List<WalletAlert>> alerts({bool handled = false}) async =>
      (await _call('adminListWalletAlerts', <String, Object?>{'status': handled ? 'handled' : 'open'})).list('alerts').map(WalletAlert.fromJson).toList();

  @override
  Future<void> resolveAlert(String alertId, AlertOutcome outcome) async {
    await _call('adminResolveWalletAlert', <String, Object?>{'alertId': alertId, 'outcome': outcome.name});
  }
}

final Provider<AdminWalletApi> adminWalletApiProvider = Provider<AdminWalletApi>((Ref ref) => FirebaseAdminWalletApi(functionsClient()));
