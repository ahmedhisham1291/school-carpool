import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_models.dart' show GeoPin;
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/l10n/l10n.dart';

enum OtherSchoolFailureKind { invalidName, invalidPin, tooMany, suspended, offline, unknown }

/// Why "Other" could not be saved, from `details.reason`
/// (functions/src/schools/other.ts).
class OtherSchoolFailure implements Exception {
  const OtherSchoolFailure(this.kind);

  factory OtherSchoolFailure.from(Object error) {
    if (error is OtherSchoolFailure) {
      return error;
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Object? reason = details is Map<Object?, Object?> ? details['reason'] : null;
      return OtherSchoolFailure(switch (reason) {
        'invalid-name' || 'invalid-governorate' => OtherSchoolFailureKind.invalidName,
        'invalid-location' => OtherSchoolFailureKind.invalidPin,
        'too-many-pending' => OtherSchoolFailureKind.tooMany,
        'suspended' => OtherSchoolFailureKind.suspended,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => OtherSchoolFailureKind.offline,
          _ => OtherSchoolFailureKind.unknown,
        },
      });
    }
    return const OtherSchoolFailure(OtherSchoolFailureKind.unknown);
  }

  final OtherSchoolFailureKind kind;

  bool get isOffline => kind == OtherSchoolFailureKind.offline;

  String message(AppLocalizations l10n) => switch (kind) {
    OtherSchoolFailureKind.invalidName => l10n.otherSchoolNameError,
    OtherSchoolFailureKind.invalidPin => l10n.otherSchoolPinErrorOutside,
    OtherSchoolFailureKind.tooMany => l10n.otherSchoolTooMany,
    OtherSchoolFailureKind.suspended => l10n.errorSuspended,
    OtherSchoolFailureKind.offline => l10n.errorOfflineShort,
    OtherSchoolFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'OtherSchoolFailure(${kind.name})';
}

/// The parent's "Other" schools (F4). The app never writes a school:
/// addOtherSchool does, and only the parent can read theirs while it
/// awaits review (firestore.rules).
abstract interface class SchoolRepository {
  /// Throws [OtherSchoolFailure].
  Future<SchoolOption> addOther({required String name, required String governorate, GeoPin? pin});

  /// The parent's own schools awaiting review.
  Stream<List<SchoolOption>> pending(String uid);
}

class FirebaseSchoolRepository implements SchoolRepository {
  FirebaseSchoolRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  @override
  Future<SchoolOption> addOther({required String name, required String governorate, GeoPin? pin}) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable('addOtherSchool').call<Object?>(
        <String, Object?>{'name': name.trim(), 'governorate': governorate, 'location': pin?.toJson()},
      );
      final Object? data = result.data;
      final Map<String, Object?> map = data is Map<Object?, Object?>
          ? <String, Object?>{for (final MapEntry<Object?, Object?> e in data.entries) '${e.key}': e.value}
          : <String, Object?>{};
      final Object? id = map['id'];
      if (id is! String) {
        throw const OtherSchoolFailure(OtherSchoolFailureKind.unknown);
      }
      return SchoolOption.fromMap(id, map);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(OtherSchoolFailure.from(error), stackTrace);
    }
  }

  @override
  Stream<List<SchoolOption>> pending(String uid) => _db
      .collection('schools')
      .where('addedBy', isEqualTo: uid)
      .where('status', isEqualTo: 'awaiting_review')
      .limit(20)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> snap) => <SchoolOption>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) SchoolOption.fromMap(doc.id, doc.data()),
        ],
      );
}

final Provider<SchoolRepository> schoolRepositoryProvider = Provider<SchoolRepository>(
  (Ref ref) => FirebaseSchoolRepository(functionsClient(), ref.watch(firestoreProvider)),
);

/// The signed-in parent's schools awaiting review (shown first in the picker).
final StreamProvider<List<SchoolOption>> myPendingSchoolsProvider = StreamProvider<List<SchoolOption>>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<List<SchoolOption>>.value(const <SchoolOption>[]);
  }
  return ref.watch(schoolRepositoryProvider).pending(session.uid);
});
