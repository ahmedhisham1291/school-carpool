import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// What Firestore keeps on the phone (review of improvement B, N1).
///
/// Firestore's offline cache holds what the signed-in parent read: chat
/// messages, first names, location pins, pickup points. It is one cache
/// per app, not per account, so it must be emptied when the parent signs
/// out (or another parent signs in on the same phone): nothing of the
/// first parent's data may stay in the app's storage. A message written
/// offline and not yet sent goes with it.
abstract interface class LocalCacheCleaner {
  /// Empties the cache. Never throws.
  Future<void> clear();
}

/// The cache can only be cleared while Firestore is stopped: terminate
/// (every listener ends), clear, and the next use starts Firestore again
/// with an empty cache. On the emulators the new instance is pointed at
/// the emulator again.
class FirestoreCacheCleaner implements LocalCacheCleaner {
  const FirestoreCacheCleaner(this._config);

  final FlavorConfig _config;

  @override
  Future<void> clear() async {
    try {
      final FirebaseFirestore old = FirebaseFirestore.instance;
      await old.terminate();
      await old.clearPersistence();
      if (_config.useEmulators) {
        FirebaseFirestore.instance.useFirestoreEmulator(_config.emulatorHost, EmulatorPorts.firestore);
      }
    } on Object catch (error) {
      // Never the data: the kind of error only.
      debugPrint('local cache: ${error.runtimeType}');
    }
  }
}

final Provider<LocalCacheCleaner> localCacheCleanerProvider = Provider<LocalCacheCleaner>(
  (Ref ref) => FirestoreCacheCleaner(ref.watch(flavorConfigProvider)),
);

/// Who the cache belongs to after [state]: the uid while signed in, '' when
/// signed out, null while that is not known (loading, a failed read).
String? cacheOwnerOf(SessionState state) => switch (state) {
  SessionSignedIn(:final String uid) => uid,
  SessionSignedOut() => '',
  _ => null,
};

/// True when the cache holds [previous]'s data and [next] is somebody else
/// or nobody.
bool mustClearCache({required String? previous, required String? next}) =>
    previous != null && previous.isNotEmpty && next != null && next != previous;

/// Empties Firestore's cache when the parent signs out or another parent
/// signs in, whatever caused it (the Sign out button, a deleted account,
/// "sign out my phones" from another phone). Watched by the app's root.
///
/// Order: the session has already changed, so the screens' listeners are
/// being cancelled; terminate ends any that are left. When the cache is
/// empty the Firestore provider is renewed, so everything that reads
/// Firestore next (the next sign-in) gets the fresh instance.
final Provider<void> localCacheGuardProvider = Provider<void>((Ref ref) {
  String? owner = cacheOwnerOf(ref.read(sessionProvider));
  ref.listen<SessionState>(sessionProvider, (SessionState? before, SessionState state) {
    final String? next = cacheOwnerOf(state);
    if (next == null) {
      return;
    }
    final bool clear = mustClearCache(previous: owner, next: next);
    owner = next;
    if (clear) {
      unawaited(
        ref.read(localCacheCleanerProvider).clear().then((_) {
          ref.invalidate(firestoreProvider);
        }),
      );
    }
  });
});
