import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/install_id.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Trust through our Cloud Functions only (Prompt 11, F17). The app reads
/// and writes no trust record in Firestore (firestore.rules close them).
/// Every method throws [TrustFailure].
abstract interface class TrustRepository {
  Future<TrustOverview> overview();

  Future<List<RateableParent>> rateable();

  /// Returns true when the rating went to the admins (low stars or a concern).
  Future<bool> rate(RatingDraft draft);

  Future<void> confirmSchoolYear({required int year, required List<YearAnswer> answers});

  Future<FamilyView> family();

  /// Asks the parent with [parentId] to link their children. Returns their first name.
  Future<String> requestLink({required String parentId, required GuardianRelation relation});

  Future<void> cancelLinkRequest(String requestId);

  /// Accept with the children to share, or decline (empty [childIds]).
  Future<void> answerLinkRequest({required String requestId, required bool accept, List<String> childIds = const <String>[]});

  Future<void> removeLink(String linkId);

  /// Sends a WhatsApp code to the new number (E.164).
  Future<void> requestPhoneChange({required String phoneE164, required String language});

  /// Uploads the live selfie, then checks the code and the face.
  Future<void> confirmPhoneChange({required String uid, required String phoneE164, required String code, required Uint8List selfie});
}

class FirebaseTrustRepository implements TrustRepository {
  FirebaseTrustRepository(this._functions, this._storage, this._installId);

  final FirebaseFunctions _functions;
  final FirebaseStorage _storage;
  final String _installId;

  Future<Map<Object?, Object?>> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> r = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? value = r.data;
      return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(TrustFailure.from(error), stackTrace);
    }
  }

  @override
  Future<TrustOverview> overview() async => TrustOverview.fromMap(await _call('getTrustOverview'));

  @override
  Future<List<RateableParent>> rateable() async {
    final Object? list = (await _call('listRateable'))['parents'];
    return <RateableParent>[
      if (list is List<Object?>)
        for (final Object? p in list)
          if (p is Map<Object?, Object?>) RateableParent.fromMap(p),
    ];
  }

  @override
  Future<bool> rate(RatingDraft draft) async => (await _call('rateParent', draft.toJson()))['flagged'] == true;

  @override
  Future<void> confirmSchoolYear({required int year, required List<YearAnswer> answers}) async {
    await _call('confirmSchoolYear', <String, Object?>{
      'year': year,
      'children': <Map<String, Object?>>[for (final YearAnswer a in answers) a.toJson()],
    });
  }

  @override
  Future<FamilyView> family() async => FamilyView.fromMap(await _call('getFamily'));

  @override
  Future<String> requestLink({required String parentId, required GuardianRelation relation}) async {
    final Object? name = (await _call('requestGuardianLink', <String, Object?>{'parentId': parentId, 'relation': relation.name}))['firstName'];
    return name is String ? name : '';
  }

  @override
  Future<void> cancelLinkRequest(String requestId) async {
    await _call('cancelGuardianRequest', <String, Object?>{'requestId': requestId});
  }

  @override
  Future<void> answerLinkRequest({required String requestId, required bool accept, List<String> childIds = const <String>[]}) async {
    await _call('answerGuardianRequest', <String, Object?>{'requestId': requestId, 'accept': accept, if (accept) 'childIds': childIds});
  }

  @override
  Future<void> removeLink(String linkId) async {
    await _call('removeGuardianLink', <String, Object?>{'linkId': linkId});
  }

  @override
  Future<void> requestPhoneChange({required String phoneE164, required String language}) async {
    await _call('requestPhoneChange', <String, Object?>{'phone': phoneE164, 'deviceId': _installId, 'language': language});
  }

  @override
  Future<void> confirmPhoneChange({required String uid, required String phoneE164, required String code, required Uint8List selfie}) async {
    try {
      await _storage.ref('phoneChecks/$uid/selfie.jpg').putData(selfie, SettableMetadata(contentType: 'image/jpeg'));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(TrustFailure.from(error), stackTrace);
    }
    await _call('confirmPhoneChange', <String, Object?>{'phone': phoneE164, 'code': code, 'deviceId': _installId});
  }
}

final Provider<TrustRepository> trustRepositoryProvider = Provider<TrustRepository>(
  (Ref ref) => FirebaseTrustRepository(functionsClient(), FirebaseStorage.instance, ref.watch(installIdProvider)),
);

/// Riverpod 3 retries failing providers by itself; trust screens show the
/// error with their own Retry button instead.
Duration? noTrustRetry(int retryCount, Object error) => null;

/// Profile's trust overview (year check banner, parents to rate, link requests).
final FutureProvider<TrustOverview> trustOverviewProvider = FutureProvider.autoDispose<TrustOverview>(
  retry: noTrustRetry,
  (Ref ref) => ref.watch(trustRepositoryProvider).overview(),
);

final FutureProvider<List<RateableParent>> rateableProvider = FutureProvider.autoDispose<List<RateableParent>>(
  retry: noTrustRetry,
  (Ref ref) => ref.watch(trustRepositoryProvider).rateable(),
);

final FutureProvider<FamilyView> familyProvider = FutureProvider.autoDispose<FamilyView>(
  retry: noTrustRetry,
  (Ref ref) => ref.watch(trustRepositoryProvider).family(),
);

/// Children another parent linked to me (active links), for the carpool
/// join picker: the server lets me bring them (Prompt 11). Empty while
/// loading or on an error.
final FutureProvider<List<ChildRecord>> linkedChildrenProvider = FutureProvider.autoDispose<List<ChildRecord>>(
  retry: noTrustRetry,
  (Ref ref) async => <ChildRecord>[
    for (final GuardianLink l in (await ref.watch(familyProvider.future)).linked)
      if (l.asChild case final ChildRecord c) c,
  ],
);
