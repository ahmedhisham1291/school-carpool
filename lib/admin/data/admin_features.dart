import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Admin panel: the pilot feature switches (Settings) and one parent's
/// settle-up records (user page, read only, logged reason). Every method
/// throws [AdminFailure].
abstract interface class AdminFeaturesApi {
  /// The switches now (any admin).
  Future<FeatureSwitches> features();

  /// Turns one feature on or off (super admins only; written to the audit
  /// log by the server). Returns the switches after the change.
  Future<FeatureSwitches> setFeature(AppFeature feature, {required bool on});

  /// One parent's settle-up records. The server logs the access with
  /// [reason] first and never returns an InstaPay address or a note.
  Future<List<AdminSettleRecord>> settleUps({required String uid, required AccessReasonCode reason});
}

/// One settle-up record as the admin sees it: no address, no note.
@immutable
class AdminSettleRecord {
  const AdminSettleRecord({
    required this.id,
    required this.payee,
    required this.otherFirstName,
    required this.amount,
    required this.reason,
    required this.status,
    this.notReceived = 0,
    this.reported = false,
    this.createdAt,
  });

  factory AdminSettleRecord.fromJson(Json j) => AdminSettleRecord(
    id: j.str('id'),
    payee: j.str('role') == 'payee',
    otherFirstName: j.str('otherFirstName'),
    amount: j.integer('amount'),
    reason: j.str('reason', 'other'),
    status: j.str('status', 'cancelled'),
    notReceived: j.integer('notReceived'),
    reported: j.flag('reported'),
    createdAt: j.time('createdAtMs'),
  );

  final String id;

  /// The parent on this page receives (true) or pays (false).
  final bool payee;
  final String otherFirstName;

  /// Piastres.
  final int amount;

  /// contribution, fuel or other.
  final String reason;

  /// open, paid, closed, cancelled or declined.
  final String status;
  final int notReceived;
  final bool reported;
  final DateTime? createdAt;
}

class FirebaseAdminFeaturesApi implements AdminFeaturesApi {
  FirebaseAdminFeaturesApi(this._functions);

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

  /// The server always answers with every switch as a boolean.
  static FeatureSwitches _switches(Json j) {
    final Json f = j.child('features');
    return FeatureSwitches(
      wallet: f.flag('wallet'),
      ratingsAndVouching: f.flag('ratingsAndVouching'),
      yearlyChecks: f.flag('yearlyChecks'),
      settleUp: f.flag('settleUp'),
      contributions: f.flag('contributions'),
    );
  }

  @override
  Future<FeatureSwitches> features() async => _switches(await _call('adminGetFeatures'));

  @override
  Future<FeatureSwitches> setFeature(AppFeature feature, {required bool on}) async =>
      _switches(await _call('adminSetFeature', <String, Object?>{'feature': feature.name, 'on': on}));

  @override
  Future<List<AdminSettleRecord>> settleUps({required String uid, required AccessReasonCode reason}) async {
    final Json j = await _call('adminListSettleUps', <String, Object?>{'uid': uid, 'reason': reason.name});
    return j.list('records').map(AdminSettleRecord.fromJson).toList();
  }
}

final Provider<AdminFeaturesApi> adminFeaturesApiProvider = Provider<AdminFeaturesApi>(
  (Ref ref) => FirebaseAdminFeaturesApi(functionsClient()),
);

/// The switches as the panel uses them to hide what is off (the wallet
/// section, a parent's wallet and settle-up records). Read once; the
/// Settings page refreshes it after a change.
final FutureProvider<FeatureSwitches> adminSwitchesProvider = FutureProvider<FeatureSwitches>(
  (Ref ref) => ref.watch(adminFeaturesApiProvider).features(),
);

/// The switches now: the stored values, or the pilot defaults (all money
/// features off) while loading and on any error, so a money section is
/// never shown before the server said it is on.
FeatureSwitches adminSwitchesNow(WidgetRef ref) => ref.watch(adminSwitchesProvider).value ?? FeatureSwitches.pilot;
