import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/install_id.dart';
import 'package:school_carpool/features/auth/legal_documents.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/firebase/collections.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Answer to a code request.
@immutable
class CodeRequest {
  const CodeRequest({required this.resendAfter, required this.expiresIn});

  final Duration resendAfter;
  final Duration expiresIn;
}

/// Sign-up and sign-in. Every method throws [AuthFailure] on failure.
///
/// The app never writes status, parent ID, email confirmation or consents:
/// Cloud Functions do. It only signs in with the custom token they return
/// and may change the app language on its own record.
abstract interface class AuthRepository {
  /// Asks the server to send a WhatsApp code to [phoneE164].
  Future<CodeRequest> requestCode({required String phoneE164, required String language});

  /// Checks the code and signs in with the returned custom token.
  Future<void> verifyCode({required String phoneE164, required String code, required String language});

  /// Sends a confirmation link to [email] (Firebase Auth). The address is
  /// saved on the account only after the parent opens the link.
  Future<void> sendEmailLink(String email);

  /// True once the parent has opened the link; the server then saves it.
  /// Opening the link revokes the session (email change), so a confirmed
  /// answer carries a fresh token that this method signs in with.
  Future<bool> confirmEmail();

  /// Records acceptance of the terms, privacy policy and code of conduct,
  /// and the optional WhatsApp alerts choice.
  Future<void> acceptConsents({required bool whatsapp});

  Future<void> updateLanguage(String languageCode);

  Future<void> signOut();
}

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository(this._auth, this._functions, this._db, this._installId);

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;
  final String _installId;

  /// Calls a function and returns its result map. Results arrive as
  /// `Map<Object?, Object?>` on iOS, so no typed call is used.
  ///
  /// [limitedUse]: a one-time App Check token that the function consumes
  /// (replay protection on requestCode, which sends a paid WhatsApp
  /// message; Prompt 12).
  Future<Map<Object?, Object?>> _call(String name, Map<String, Object?> payload, {bool limitedUse = false}) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(limitedUseAppCheckToken: limitedUse))
          .call<Object?>(payload);
      final Object? data = result.data;
      return data is Map<Object?, Object?> ? data : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AuthFailure.from(error), stackTrace);
    }
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AuthFailure.from(error), stackTrace);
    }
  }

  static int _seconds(Object? value, int fallback) => value is num ? value.toInt() : fallback;

  User _currentUser() {
    final User? user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure(AuthFailureKind.unknown);
    }
    return user;
  }

  @override
  Future<CodeRequest> requestCode({required String phoneE164, required String language}) async {
    final Map<Object?, Object?> data = await _call('requestCode', <String, Object?>{
      'phone': phoneE164,
      'deviceId': _installId,
      'language': language,
    }, limitedUse: true);
    return CodeRequest(
      resendAfter: Duration(seconds: _seconds(data['resendAfterSeconds'], 60)),
      expiresIn: Duration(seconds: _seconds(data['expiresInSeconds'], 300)),
    );
  }

  @override
  Future<void> verifyCode({
    required String phoneE164,
    required String code,
    required String language,
  }) async {
    final Map<Object?, Object?> data = await _call('verifyCode', <String, Object?>{
      'phone': phoneE164,
      'code': code,
      'deviceId': _installId,
      'language': language,
      // Prompt 12: shown in the parent's list of phones.
      'platform': platformName(),
    });
    final Object? token = data['token'];
    if (token is! String || token.isEmpty) {
      throw const AuthFailure(AuthFailureKind.unknown);
    }
    await _guard(() => _auth.signInWithCustomToken(token));
  }

  @override
  Future<void> sendEmailLink(String email) =>
      _guard(() => _currentUser().verifyBeforeUpdateEmail(email.trim()));

  @override
  Future<bool> confirmEmail() async {
    if (_auth.currentUser == null) {
      throw const AuthFailure(AuthFailureKind.signInAgain);
    }
    // No reload() here: after the link the old session is revoked and
    // reload() would fail. The server reads the truth from Firebase Auth.
    final Map<Object?, Object?> data = await _call('confirmEmail', <String, Object?>{});
    if (data['verified'] != true) {
      return false;
    }
    final Object? token = data['token'];
    if (token is String && token.isNotEmpty) {
      await _guard(() => _auth.signInWithCustomToken(token));
    }
    return true;
  }

  @override
  Future<void> acceptConsents({required bool whatsapp}) async {
    await _call('acceptConsents', <String, Object?>{
      'documents': LegalDocuments.required,
      'whatsapp': whatsapp,
    });
  }

  @override
  Future<void> updateLanguage(String languageCode) => _guard(
    () => _db.collection(Collections.users).doc(_currentUser().uid).update(<String, Object?>{
      'language': languageCode,
    }),
  );

  @override
  Future<void> signOut() => _guard(_auth.signOut);
}

final Provider<AuthRepository> authRepositoryProvider = Provider<AuthRepository>(
  (Ref ref) => FirebaseAuthRepository(
    ref.watch(firebaseAuthProvider),
    functionsClient(),
    ref.watch(firestoreProvider),
    ref.watch(installIdProvider),
  ),
);
