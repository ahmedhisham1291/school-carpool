import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/firebase/collections.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Schedule (Prompt 7). Every change goes through Cloud Functions, in a
/// transaction on the server; the app reads runs, exceptions and the
/// balance of carpools it is an approved member of (firestore.rules).
abstract interface class ScheduleRepository {
  /// The runs of the week that starts on [weekStart] (a Saturday).
  Stream<List<ScheduleRun>> watchWeek(String carpoolId, DateTime weekStart);
  Stream<List<ScheduleException>> watchExceptions(String carpoolId);
  Stream<DriveBalance?> watchBalance(String carpoolId, String termId);

  /// Every method below throws [CarpoolFailure].
  Future<PlanResult> planWeek(String carpoolId, DateTime weekStart);
  Future<void> confirmRun(String carpoolId, String runId);
  Future<void> requestSwap(String carpoolId, String runId);
  Future<void> cancelSwap(String carpoolId, String runId);
  Future<void> takeRun(String carpoolId, String runId);

  /// Morning and afternoon of [date].
  Future<void> setChildAbsent({required String carpoolId, required DateTime date, required String childId, required bool absent});
  Future<void> setDrivingDays(String carpoolId, List<Weekday> days);
  Future<void> saveException(String carpoolId, ExceptionDraft draft);
  Future<void> deleteException(String carpoolId, String exceptionId);
}

class FirebaseScheduleRepository implements ScheduleRepository {
  FirebaseScheduleRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  Future<Object?> _call(String name, Map<String, Object?> data) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable(name).call<Object?>(data);
      return result.data;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(CarpoolFailure.from(error), stackTrace);
    }
  }

  CollectionReference<Map<String, dynamic>> _sub(String carpoolId, String name) =>
      _db.collection(Collections.carpools).doc(carpoolId).collection(name);

  @override
  Stream<List<ScheduleRun>> watchWeek(String carpoolId, DateTime weekStart) => _sub(carpoolId, Collections.schedule)
      .where('date', isGreaterThanOrEqualTo: ScheduleDates.key(weekStart))
      .where('date', isLessThanOrEqualTo: ScheduleDates.key(ScheduleDates.addDays(weekStart, 6)))
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> s) => <ScheduleRun>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) ScheduleRun.fromDoc(d.id, d.data()),
        ],
      );

  @override
  Stream<List<ScheduleException>> watchExceptions(String carpoolId) => _sub(carpoolId, Collections.exceptions).snapshots().map(
    (QuerySnapshot<Map<String, dynamic>> s) =>
        <ScheduleException>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) ScheduleException.fromDoc(d.id, d.data()),
        ]..sort((ScheduleException a, ScheduleException b) => a.from.compareTo(b.from)),
  );

  @override
  Stream<DriveBalance?> watchBalance(String carpoolId, String termId) =>
      _sub(carpoolId, Collections.balances).doc(termId).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
        final Map<String, dynamic>? data = s.data();
        return data == null ? null : DriveBalance.fromDoc(termId, data);
      });

  Map<String, Object?> _run(String carpoolId, String runId) => <String, Object?>{'carpoolId': carpoolId, 'runId': runId};

  @override
  Future<PlanResult> planWeek(String carpoolId, DateTime weekStart) async => PlanResult.fromMap(
    await _call('planScheduleWeek', <String, Object?>{'carpoolId': carpoolId, 'weekStart': ScheduleDates.key(weekStart)}),
  );

  @override
  Future<void> confirmRun(String carpoolId, String runId) => _call('confirmRun', _run(carpoolId, runId));

  @override
  Future<void> requestSwap(String carpoolId, String runId) => _call('requestSwap', _run(carpoolId, runId));

  @override
  Future<void> cancelSwap(String carpoolId, String runId) => _call('cancelSwap', _run(carpoolId, runId));

  @override
  Future<void> takeRun(String carpoolId, String runId) => _call('takeRun', _run(carpoolId, runId));

  @override
  Future<void> setChildAbsent({required String carpoolId, required DateTime date, required String childId, required bool absent}) =>
      _call('setChildAbsent', <String, Object?>{
        'carpoolId': carpoolId,
        'date': ScheduleDates.key(date),
        'childId': childId,
        'absent': absent,
      });

  @override
  Future<void> setDrivingDays(String carpoolId, List<Weekday> days) =>
      _call('setDrivingDays', <String, Object?>{'carpoolId': carpoolId, 'days': <String>[for (final Weekday d in days) d.name]});

  @override
  Future<void> saveException(String carpoolId, ExceptionDraft draft) => _call('saveScheduleException', draft.toJson(carpoolId));

  @override
  Future<void> deleteException(String carpoolId, String exceptionId) =>
      _call('deleteScheduleException', <String, Object?>{'carpoolId': carpoolId, 'exceptionId': exceptionId});
}

final Provider<ScheduleRepository> scheduleRepositoryProvider = Provider<ScheduleRepository>(
  (Ref ref) => FirebaseScheduleRepository(functionsClient(), ref.watch(firestoreProvider)),
);

/// "Now" for the schedule screens (tests fix it).
final Provider<DateTime Function()> scheduleClockProvider = Provider<DateTime Function()>((Ref ref) => DateTime.now);
