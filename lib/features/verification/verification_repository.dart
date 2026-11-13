import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Uploads, submission and the parent's own children and car. Every method
/// throws [VerificationFailure] on failure.
///
/// The app never writes status, children or vehicles: Cloud Functions do.
abstract interface class VerificationRepository {
  /// Uploads one compressed JPEG to verification/{uid}/pending/{name}.
  /// [onProgress] gets 0 to 1.
  Future<void> upload(String uid, String name, Uint8List bytes, {ValueChanged<double>? onProgress});

  /// Calls submitVerification and returns the case ID.
  Future<String> submit(Map<String, Object?> payload);

  Future<void> removeChild(String childId);

  Stream<List<ChildRecord>> children(String uid);

  Stream<VehicleRecord?> vehicle(String uid);
}

class FirebaseVerificationRepository implements VerificationRepository {
  FirebaseVerificationRepository(this._storage, this._functions, this._db);

  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  /// The Storage SDK retries a dropped connection and resumes the upload
  /// where it stopped, for up to this long, before failing.
  static const Duration uploadRetryTime = Duration(minutes: 2);

  @override
  Future<void> upload(String uid, String name, Uint8List bytes, {ValueChanged<double>? onProgress}) async {
    _storage.setMaxUploadRetryTime(uploadRetryTime);
    final UploadTask task = _storage
        .ref('verification/$uid/pending/$name')
        .putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    final StreamSubscription<TaskSnapshot> progress = task.snapshotEvents.listen(
      (TaskSnapshot s) {
        if (s.totalBytes > 0) {
          onProgress?.call(s.bytesTransferred / s.totalBytes);
        }
      },
      onError: (Object _) {},
    );
    try {
      await task;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(VerificationFailure.from(error), stackTrace);
    } finally {
      await progress.cancel();
    }
  }

  @override
  Future<String> submit(Map<String, Object?> payload) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable('submitVerification', options: HttpsCallableOptions(timeout: const Duration(minutes: 2)))
          .call<Object?>(payload);
      final Object? data = result.data;
      final Object? caseId = data is Map<Object?, Object?> ? data['caseId'] : null;
      return caseId is String ? caseId : '';
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(VerificationFailure.from(error), stackTrace);
    }
  }

  @override
  Future<void> removeChild(String childId) async {
    try {
      await _functions.httpsCallable('removeChild').call<Object?>(<String, Object?>{'childId': childId});
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(VerificationFailure.from(error), stackTrace);
    }
  }

  @override
  Stream<List<ChildRecord>> children(String uid) => _db
      .collection('children')
      .where('ownerUid', isEqualTo: uid)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> snap) => <ChildRecord>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs)
            ChildRecord.fromDoc(doc.id, doc.data()),
        ]..sort((ChildRecord a, ChildRecord b) => a.firstName.compareTo(b.firstName)),
      );

  @override
  Stream<VehicleRecord?> vehicle(String uid) => _db.collection('vehicles').doc(uid).snapshots().map((
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    final Map<String, dynamic>? data = snap.data();
    return data == null ? null : VehicleRecord.fromMap(data);
  });
}

final Provider<VerificationRepository> verificationRepositoryProvider = Provider<VerificationRepository>(
  (Ref ref) => FirebaseVerificationRepository(
    FirebaseStorage.instance,
    functionsClient(),
    ref.watch(firestoreProvider),
  ),
);

/// The signed-in parent's children (F3).
final StreamProvider<List<ChildRecord>> childrenProvider = StreamProvider<List<ChildRecord>>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<List<ChildRecord>>.value(const <ChildRecord>[]);
  }
  return ref.watch(verificationRepositoryProvider).children(session.uid);
});

/// The signed-in parent's car, or null.
final StreamProvider<VehicleRecord?> vehicleProvider = StreamProvider<VehicleRecord?>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<VehicleRecord?>.value(null);
  }
  return ref.watch(verificationRepositoryProvider).vehicle(session.uid);
});

/// Uploads what is not uploaded yet, then submits. Each image is its own
/// upload, so a broken connection costs only the image in flight: the next
/// try sends only what is missing (and the Storage SDK resumes a dropped
/// upload by itself first). [isUploaded] and [markUploaded] keep track of
/// what is done; a retake forgets its name.
Future<String> uploadAndSubmit({
  required VerificationRepository repository,
  required String uid,
  required Map<String, Uint8List> files,
  required Map<String, Object?> payload,
  required bool Function(String name) isUploaded,
  required void Function(String name) markUploaded,
  required void Function(Iterable<String> names) forgetUploads,
  ValueChanged<double>? onProgress,
}) async {
  Future<void> uploadMissing() async {
    final List<String> todo = <String>[
      for (final String name in files.keys)
        if (!isUploaded(name)) name,
    ];
    final int total = files.length;
    int done = total - todo.length;
    onProgress?.call(total == 0 ? 1 : done / total);
    for (final String name in todo) {
      await repository.upload(
        uid,
        name,
        files[name]!,
        onProgress: (double p) => onProgress?.call((done + p) / total),
      );
      markUploaded(name);
      done += 1;
      onProgress?.call(done / total);
    }
  }

  await uploadMissing();
  try {
    return await repository.submit(payload);
  } on VerificationFailure catch (failure) {
    // The pending folder lost something (for example cleaned after 3 days):
    // upload those again once.
    if (failure.kind != VerificationFailureKind.missingUpload || failure.missing.isEmpty) {
      rethrow;
    }
    forgetUploads(failure.missing);
    await uploadMissing();
    return repository.submit(payload);
  }
}
