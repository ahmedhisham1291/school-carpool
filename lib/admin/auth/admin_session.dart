import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/session.dart';

/// Who is using the admin panel (F14). Drives the panel's router.
sealed class AdminSessionState {
  const AdminSessionState();
}

final class AdminSessionLoading extends AdminSessionState {
  const AdminSessionLoading();
}

final class AdminSignedOut extends AdminSessionState {
  const AdminSignedOut({this.reason});

  /// Why the panel signed out, shown on the sign-in screen.
  final AdminSignOutReason? reason;
}

enum AdminSignOutReason { idle, expired, notAllowed }

/// Signed in, but the account is not an admin (a parent account cannot
/// get here: the blocking function refuses it; kept as a safety net).
final class AdminNotAllowed extends AdminSessionState {
  const AdminNotAllowed();
}

/// An admin who signed in with the password only and has no second factor
/// yet. Must add the authenticator app before using the panel.
final class AdminNeedsSecondFactor extends AdminSessionState {
  const AdminNeedsSecondFactor(this.user);

  final AdminUser user;
}

final class AdminSignedIn extends AdminSessionState {
  const AdminSignedIn(this.user);

  final AdminUser user;
}

/// The panel's session limit. Keep in sync with
/// ADMIN_SESSION_MAX_SECONDS (functions/src/admin_panel/guard.ts) and
/// isAdmin() in firestore.rules.
const Duration kAdminSessionMax = Duration(hours: 8);

/// Signs out after this long without a click, key press or scroll.
const Duration kAdminIdleTimeout = Duration(minutes: 15);

/// The session for an ID token's facts. Pure, unit-tested.
AdminSessionState adminSessionFor({
  required String uid,
  required String? email,
  required String? displayName,
  required Map<String, dynamic>? claims,
  required String? secondFactor,
  required DateTime? authTime,
  required DateTime now,
  required bool mfaRequired,
}) {
  final Map<String, dynamic> c = claims ?? const <String, dynamic>{};
  if (c['admin'] != true) {
    return const AdminNotAllowed();
  }
  if (authTime == null || now.difference(authTime) > kAdminSessionMax) {
    return const AdminSignedOut(reason: AdminSignOutReason.expired);
  }
  final AdminUser user = AdminUser(
    uid: uid,
    email: email ?? '',
    displayName: (displayName == null || displayName.isEmpty) ? (email ?? uid) : displayName,
    role: c['superAdmin'] == true ? AdminRole.superAdmin : AdminRole.admin,
  );
  if (mfaRequired && (secondFactor == null || secondFactor.isEmpty)) {
    return AdminNeedsSecondFactor(user);
  }
  return AdminSignedIn(user);
}

/// The second factor this token was signed in with. On the web the plugin
/// leaves `IdTokenResult.signInSecondFactor` empty, so the token's own
/// `firebase.sign_in_second_factor` claim is read too. Pure, unit-tested.
String? secondFactorOf(String? fromResult, Map<String, dynamic>? claims) {
  if (fromResult != null && fromResult.isNotEmpty) {
    return fromResult;
  }
  final Object? firebase = claims?['firebase'];
  if (firebase is Map) {
    final Object? factor = firebase['sign_in_second_factor'];
    if (factor is String && factor.isNotEmpty) {
      return factor;
    }
  }
  return null;
}

/// The result of the password step.
sealed class AdminSignInStep {
  const AdminSignInStep();
}

/// Signed in (no second factor enrolled yet, or emulators).
final class AdminSignInDone extends AdminSignInStep {
  const AdminSignInDone();
}

/// The password was right; now the authenticator code.
final class AdminSignInNeedsCode extends AdminSignInStep {
  const AdminSignInNeedsCode();
}

/// Secret for adding the panel to an authenticator app.
@immutable
class TotpSetup {
  const TotpSetup({required this.secretKey, required this.uri});

  /// Typed into the authenticator app by hand (no QR code package yet).
  final String secretKey;

  /// otpauth:// link with the same secret.
  final String uri;
}

/// Admin sign-in with two steps. Every method throws [AdminFailure].
abstract interface class AdminAuthRepository {
  Future<AdminSignInStep> signIn({required String email, required String password});

  /// Second step: the 6-digit code from the authenticator app.
  Future<void> verifyCode(String code);

  /// First sign-in: creates the secret for the authenticator app.
  Future<TotpSetup> startTotpSetup();

  /// Confirms the app shows the right code, enrolls it, then signs out so
  /// the admin signs in again with both steps.
  Future<void> finishTotpSetup(String code);

  Future<void> signOut();
}

class FirebaseAdminAuthRepository implements AdminAuthRepository {
  FirebaseAdminAuthRepository(this._auth);

  final FirebaseAuth _auth;
  MultiFactorResolver? _resolver;
  TotpSecret? _secret;

  static const String _issuer = 'School Carpool Admin';

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AdminFailure.from(error), stackTrace);
    }
  }

  @override
  Future<AdminSignInStep> signIn({required String email, required String password}) => _guard(() async {
    _resolver = null;
    try {
      await _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
      return const AdminSignInDone();
    } on FirebaseAuthMultiFactorException catch (e) {
      _resolver = e.resolver;
      return const AdminSignInNeedsCode();
    }
  });

  @override
  Future<void> verifyCode(String code) => _guard(() async {
    final MultiFactorResolver? resolver = _resolver;
    if (resolver == null) {
      throw const AdminFailure(AdminFailureKind.sessionExpired);
    }
    final MultiFactorInfo hint = resolver.hints.firstWhere(
      (MultiFactorInfo h) => h.factorId == 'totp',
      orElse: () => resolver.hints.first,
    );
    final MultiFactorAssertion assertion = await TotpMultiFactorGenerator.getAssertionForSignIn(hint.uid, code);
    await resolver.resolveSignIn(assertion);
    _resolver = null;
  });

  @override
  Future<TotpSetup> startTotpSetup() => _guard(() async {
    final User? user = _auth.currentUser;
    if (user == null) {
      throw const AdminFailure(AdminFailureKind.sessionExpired);
    }
    // Already set up (an earlier attempt went through even though the page
    // showed an error): sign out, so the next sign-in asks for the code.
    if (await _hasSecondFactor(user)) {
      await _signOutQuietly();
      throw const AdminFailure(AdminFailureKind.sessionExpired);
    }
    final MultiFactorSession session = await user.multiFactor.getSession();
    final TotpSecret secret = await TotpMultiFactorGenerator.generateSecret(session);
    _secret = secret;
    final String uri = await secret.generateQrCodeUrl(accountName: user.email, issuer: _issuer);
    return TotpSetup(secretKey: secret.secretKey, uri: uri);
  });

  @override
  Future<void> finishTotpSetup(String code) => _guard(() async {
    final User? user = _auth.currentUser;
    final TotpSecret? secret = _secret;
    if (user == null || secret == null) {
      throw const AdminFailure(AdminFailureKind.sessionExpired);
    }
    final MultiFactorAssertion assertion = await TotpMultiFactorGenerator.getAssertionForEnrollment(secret, code);
    try {
      await user.multiFactor.enroll(assertion, displayName: 'Authenticator');
    } on Object {
      // On the web the call can report an error after the server has already
      // linked the authenticator. Ask the server before calling it a failure.
      if (!await _hasSecondFactor(user)) {
        rethrow;
      }
    }
    _secret = null;
    await _signOutQuietly();
  });

  /// Whether the server lists a second factor for [user]. Any error: no.
  Future<bool> _hasSecondFactor(User user) async {
    try {
      await user.reload();
      final User current = _auth.currentUser ?? user;
      return (await current.multiFactor.getEnrolledFactors()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<void> _signOutQuietly() async {
    try {
      await _auth.signOut();
    } on Object {
      // The session listener sends the admin to sign-in anyway.
    }
  }

  @override
  Future<void> signOut() => _guard(() async {
    _resolver = null;
    _secret = null;
    await _auth.signOut();
  });
}

final Provider<AdminAuthRepository> adminAuthRepositoryProvider = Provider<AdminAuthRepository>(
  (Ref ref) => FirebaseAdminAuthRepository(ref.watch(firebaseAuthProvider)),
);

/// The second factor is required except on the local emulators (the Auth
/// emulator has no TOTP). Cloud Functions apply the same rule.
final Provider<bool> adminMfaRequiredProvider = Provider<bool>(
  (Ref ref) => !ref.watch(flavorConfigProvider).useEmulators,
);

/// Why the panel signed the admin out last (idle timer, expired session,
/// not an admin). Shown once on the sign-in screen.
class AdminSignOutReasonController extends Notifier<AdminSignOutReason?> {
  @override
  AdminSignOutReason? build() => null;

  void set(AdminSignOutReason? reason) => state = reason;
}

final NotifierProvider<AdminSignOutReasonController, AdminSignOutReason?> adminSignOutReasonProvider =
    NotifierProvider<AdminSignOutReasonController, AdminSignOutReason?>(AdminSignOutReasonController.new);

Stream<AdminSessionState> adminSessionStates(
  FirebaseAuth auth, {
  required bool mfaRequired,
  ValueChanged<AdminSignOutReason>? onForcedSignOut,
}) {
  return auth.idTokenChanges().asyncMap((User? user) async {
    if (user == null) {
      return const AdminSignedOut();
    }
    final IdTokenResult token = await user.getIdTokenResult();
    final AdminSessionState state = adminSessionFor(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
      claims: token.claims,
      secondFactor: secondFactorOf(token.signInSecondFactor, token.claims),
      authTime: token.authTime,
      now: DateTime.now(),
      mfaRequired: mfaRequired,
    );
    if (state is AdminSignedOut || state is AdminNotAllowed) {
      // Expired or not an admin: end the Firebase session too.
      onForcedSignOut?.call(state is AdminSignedOut ? AdminSignOutReason.expired : AdminSignOutReason.notAllowed);
      unawaited(auth.signOut());
    }
    return state;
  });
}

final StreamProvider<AdminSessionState> adminSessionStreamProvider = StreamProvider<AdminSessionState>(
  (Ref ref) => adminSessionStates(
    ref.watch(firebaseAuthProvider),
    mfaRequired: ref.watch(adminMfaRequiredProvider),
    onForcedSignOut: (AdminSignOutReason reason) => ref.read(adminSignOutReasonProvider.notifier).set(reason),
  ),
);

/// The current admin session. Tests override this with a fixed value.
final Provider<AdminSessionState> adminSessionProvider = Provider<AdminSessionState>((Ref ref) {
  return switch (ref.watch(adminSessionStreamProvider)) {
    AsyncData<AdminSessionState>(:final AdminSessionState value) => value,
    AsyncError<AdminSessionState>() => const AdminSignedOut(),
    _ => const AdminSessionLoading(),
  };
});

/// The signed-in admin, or null.
AdminUser? adminUserOf(AdminSessionState state) => switch (state) {
  AdminSignedIn(:final AdminUser user) || AdminNeedsSecondFactor(:final AdminUser user) => user,
  _ => null,
};
