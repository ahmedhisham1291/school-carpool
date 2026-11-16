import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/firebase/collections.dart';

/// Who is using the app right now. Drives the router's redirects.
sealed class SessionState {
  const SessionState();
}

/// Firebase has not said yet whether someone is signed in.
final class SessionLoading extends SessionState {
  const SessionLoading();
}

final class SessionSignedOut extends SessionState {
  const SessionSignedOut();
}

/// The session could not be loaded (for example no connection and nothing
/// cached yet).
final class SessionFailed extends SessionState {
  const SessionFailed({required this.offline});

  final bool offline;
}

final class SessionSignedIn extends SessionState {
  const SessionSignedIn({required this.uid, required this.account});

  final String uid;

  /// Null only while the server is still creating the record.
  final Account? account;
}

final Provider<FirebaseAuth> firebaseAuthProvider = Provider<FirebaseAuth>(
  (Ref ref) => FirebaseAuth.instance,
);

final Provider<FirebaseFirestore> firestoreProvider = Provider<FirebaseFirestore>(
  (Ref ref) => FirebaseFirestore.instance,
);

/// Follows sign-in and, while signed in, the parent's own users/{uid}
/// record. Switching user cancels the previous record's listener.
Stream<SessionState> sessionStates(FirebaseAuth auth, FirebaseFirestore db) {
  late final StreamController<SessionState> controller;
  StreamSubscription<User?>? authSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? accountSubscription;

  void fail(Object error) => controller.add(SessionFailed(offline: isOfflineError(error)));

  controller = StreamController<SessionState>(
    onListen: () {
      authSubscription = auth.authStateChanges().listen((User? user) {
        unawaited(accountSubscription?.cancel());
        accountSubscription = null;
        if (user == null) {
          controller.add(const SessionSignedOut());
          return;
        }
        controller.add(const SessionLoading());
        bool first = true;
        int? lastMarker;
        accountSubscription = db
            .collection(Collections.users)
            .doc(user.uid)
            .snapshots()
            .listen((DocumentSnapshot<Map<String, dynamic>> snapshot) {
              final Map<String, dynamic>? data = snapshot.data();
              final Account? account = data == null ? null : Account.fromMap(data);
              switch (tokenRefreshFor(first: first, previousMarker: lastMarker, account: account)) {
                case TokenRefresh.force:
                  unawaited(refreshIdToken(user));
                case TokenRefresh.ifClaimMissing:
                  unawaited(refreshIfNotVerifiedClaim(user));
                case TokenRefresh.none:
                  break;
              }
              if (account != null) {
                first = false;
                lastMarker = account.claimsUpdatedAtMs;
              }
              controller.add(SessionSignedIn(uid: user.uid, account: account));
            }, onError: fail);
      }, onError: fail);
    },
    onCancel: () async {
      await accountSubscription?.cancel();
      await authSubscription?.cancel();
      await controller.close();
    },
  );
  return controller.stream;
}

enum TokenRefresh { none, force, ifClaimMissing }

/// When the app must fetch a fresh ID token so rules and functions see the
/// latest custom claims. Cloud Functions set the claim first and then write
/// `claimsUpdatedAt`, so a refresh triggered by that marker always gets the
/// new claim. On the first record of a session, a verified account whose
/// cached token lacks the claim refreshes too.
TokenRefresh tokenRefreshFor({required bool first, required int? previousMarker, required Account? account}) {
  if (account == null) {
    return TokenRefresh.none;
  }
  if (first) {
    return account.status == AccountStatus.verified ? TokenRefresh.ifClaimMissing : TokenRefresh.none;
  }
  final int? marker = account.claimsUpdatedAtMs;
  return marker != null && marker != previousMarker ? TokenRefresh.force : TokenRefresh.none;
}

/// Refreshes the token only when the cached one lacks the "verified" claim.
Future<void> refreshIfNotVerifiedClaim(User user) async {
  try {
    final IdTokenResult result = await user.getIdTokenResult();
    if (result.claims?['verified'] != true) {
      await user.getIdToken(true);
    }
  } on Object catch (error) {
    debugPrint('session: token check failed ($error)');
  }
}

/// Forces a new ID token with the latest custom claims. Failures are
/// harmless: the token refreshes by itself within the hour.
Future<void> refreshIdToken(User user) async {
  try {
    await user.getIdToken(true);
  } on Object catch (error) {
    debugPrint('session: token refresh failed ($error)');
  }
}

final StreamProvider<SessionState> sessionStreamProvider = StreamProvider<SessionState>(
  (Ref ref) => sessionStates(ref.watch(firebaseAuthProvider), ref.watch(firestoreProvider)),
);

/// The current session. Tests override this with a fixed value.
final Provider<SessionState> sessionProvider = Provider<SessionState>((Ref ref) {
  return switch (ref.watch(sessionStreamProvider)) {
    AsyncData<SessionState>(:final SessionState value) => value,
    AsyncError<SessionState>(:final Object error) => SessionFailed(offline: isOfflineError(error)),
    _ => const SessionLoading(),
  };
});

/// The signed-in parent's account, or null.
Account? accountOf(SessionState session) => switch (session) {
  SessionSignedIn(:final Account? account) => account,
  _ => null,
};
