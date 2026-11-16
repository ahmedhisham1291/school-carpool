import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/install_id.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Privacy and security through our Cloud Functions only (Prompt 12). The
/// app reads no privacy record in Firestore (firestore.rules close them).
/// Every method throws [PrivacyFailure].
abstract interface class PrivacyRepository {
  Future<PrivacyOverview> overview();

  /// Gives or withdraws one consent; the answer says what it changed.
  Future<WithdrawEffect> setConsent(ConsentKind kind, {required bool granted});

  /// Logs a correction request (ID details go to an admin).
  Future<void> requestCorrection(CorrectionField field);

  /// Asks the privacy team for a copy of the photos.
  Future<void> requestPhotoCopy();

  /// A link to a JSON file with every data type, valid 1 hour.
  Future<ExportLink> exportData();

  /// R3: the copy of a signed consent (null: given before signed copies).
  Future<ConsentCopy?> consentCopy(ConsentKind kind);

  /// R3: a one-hour link to the copy as a text file.
  Future<ExportLink> downloadConsentCopy(ConsentKind kind);

  /// Deletes the account (after the app's confirmation and Face ID check).
  Future<void> deleteAccount();

  /// This account's phones and recent sign-ins.
  Future<DeviceList> devices();

  /// Signs out one phone ([deviceKey]) or every other phone ([all]).
  /// Returns a fresh custom token for this phone.
  Future<String> signOutDevice({String? deviceKey, bool all = false});

  /// App start and resume: true when this phone was signed out elsewhere.
  Future<bool> touchDevice();

  /// Uploads the fresh selfie after a new-phone sign-in, then checks it.
  /// Returns true when the admins will compare it by hand afterwards.
  Future<bool> confirmNewDevice({required String uid, required Uint8List selfie});
}

class FirebasePrivacyRepository implements PrivacyRepository {
  FirebasePrivacyRepository(this._functions, this._storage, this._installId);

  final FirebaseFunctions _functions;
  final FirebaseStorage _storage;
  final String _installId;

  Future<Map<Object?, Object?>> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> r = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? value = r.data;
      return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(PrivacyFailure.from(error), stackTrace);
    }
  }

  Map<String, Object?> get _device => <String, Object?>{'deviceId': _installId, 'platform': platformName()};

  @override
  Future<PrivacyOverview> overview() async => PrivacyOverview.fromMap(await _call('getPrivacyOverview'));

  @override
  Future<WithdrawEffect> setConsent(ConsentKind kind, {required bool granted}) async =>
      WithdrawEffect.fromName((await _call('setConsent', <String, Object?>{'kind': kind.name, 'granted': granted}))['effect']);

  @override
  Future<void> requestCorrection(CorrectionField field) async {
    await _call('requestCorrection', <String, Object?>{'field': field.name});
  }

  @override
  Future<void> requestPhotoCopy() async {
    await _call('requestPhotoCopy');
  }

  @override
  Future<ExportLink> exportData() async => ExportLink.fromMap(await _call('exportMyData'));

  @override
  Future<ConsentCopy?> consentCopy(ConsentKind kind) async =>
      ConsentCopy.fromMap((await _call('getConsentCopy', <String, Object?>{'kind': kind.name}))['copy']);

  @override
  Future<ExportLink> downloadConsentCopy(ConsentKind kind) async =>
      ExportLink.fromMap(await _call('getConsentCopy', <String, Object?>{'kind': kind.name, 'download': true}));

  @override
  Future<void> deleteAccount() async {
    await _call('deleteMyAccount');
  }

  @override
  Future<DeviceList> devices() async => DeviceList.fromMap(await _call('listDevices', _device));

  @override
  Future<String> signOutDevice({String? deviceKey, bool all = false}) async {
    final Object? token = (await _call('signOutDevice', <String, Object?>{
      ..._device,
      'deviceKey': ?deviceKey,
      if (all) 'all': true,
    }))['token'];
    return token is String ? token : '';
  }

  @override
  Future<bool> touchDevice() async => (await _call('touchDevice', _device))['signedOut'] == true;

  @override
  Future<bool> confirmNewDevice({required String uid, required Uint8List selfie}) async {
    try {
      await _storage.ref('deviceChecks/$uid/selfie.jpg').putData(selfie, SettableMetadata(contentType: 'image/jpeg'));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(PrivacyFailure.from(error), stackTrace);
    }
    return (await _call('confirmNewDevice'))['reviewed'] == true;
  }
}

final Provider<PrivacyRepository> privacyRepositoryProvider = Provider<PrivacyRepository>(
  (Ref ref) => FirebasePrivacyRepository(functionsClient(), FirebaseStorage.instance, ref.watch(installIdProvider)),
);

/// Riverpod 3 retries failing providers by itself; the privacy screens show
/// the error with their own Retry button instead.
Duration? noPrivacyRetry(int retryCount, Object error) => null;

final FutureProvider<PrivacyOverview> privacyOverviewProvider = FutureProvider.autoDispose<PrivacyOverview>(
  retry: noPrivacyRetry,
  (Ref ref) => ref.watch(privacyRepositoryProvider).overview(),
);

final FutureProvider<DeviceList> deviceListProvider = FutureProvider.autoDispose<DeviceList>(
  retry: noPrivacyRetry,
  (Ref ref) => ref.watch(privacyRepositoryProvider).devices(),
);
