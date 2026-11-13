import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';

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
        accountSubscription = db
            .collection('users')
            .doc(user.uid)
            .snapshots()
            .listen((DocumentSnapshot<Map<String, dynamic>> snapshot) {
              final Map<String, dynamic>? data = snapshot.data();
              controller.add(
                SessionSignedIn(uid: user.uid, account: data == null ? null : Account.fromMap(data)),
              );
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
