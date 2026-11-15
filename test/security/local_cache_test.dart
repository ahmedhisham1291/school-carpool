// Firestore's cache is emptied when the parent signs out or another parent
// signs in (review of improvement B, N1). The guard is tested through its
// seam (LocalCacheCleaner): no Firebase here. Written, not run here (no
// Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/security/local_cache.dart';

import '../helpers/test_app.dart';

final NotifierProvider<_Session, SessionState> _sessionHolder = NotifierProvider<_Session, SessionState>(_Session.new);

class _Session extends Notifier<SessionState> {
  @override
  SessionState build() => testVerifiedSession;

  void set(SessionState s) => state = s;
}

class _CountingCleaner implements LocalCacheCleaner {
  int cleared = 0;

  @override
  Future<void> clear() async {
    cleared += 1;
  }
}

const SessionState _otherParent = SessionSignedIn(
  uid: 'uid-2',
  account: Account(
    parentId: 'WXYZ6789',
    status: AccountStatus.verified,
    phone: '+201000000002',
    email: 'other@example.com',
    emailVerified: true,
    termsAccepted: true,
    language: 'ar',
  ),
);

void main() {
  test('who the cache belongs to, and when it must be emptied', () {
    expect(cacheOwnerOf(testVerifiedSession), 'uid-1');
    expect(cacheOwnerOf(const SessionSignedOut()), '');
    expect(cacheOwnerOf(const SessionLoading()), isNull);
    // Signed out, or another parent: empty it.
    expect(mustClearCache(previous: 'uid-1', next: ''), isTrue);
    expect(mustClearCache(previous: 'uid-1', next: 'uid-2'), isTrue);
    // The same parent, a first sign-in, or not known yet: keep it.
    expect(mustClearCache(previous: 'uid-1', next: 'uid-1'), isFalse);
    expect(mustClearCache(previous: '', next: 'uid-1'), isFalse);
    expect(mustClearCache(previous: null, next: 'uid-1'), isFalse);
    expect(mustClearCache(previous: 'uid-1', next: null), isFalse);
  });

  test('sign-out and a change of parent empty the cache once each; a record change or a loading moment does not', () async {
    final _CountingCleaner cleaner = _CountingCleaner();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        sessionProvider.overrideWith((Ref ref) => ref.watch(_sessionHolder)),
        localCacheCleanerProvider.overrideWithValue(cleaner),
      ],
    );
    addTearDown(container.dispose);
    // Kept alive for the whole test, as the app's root does.
    container.listen<void>(localCacheGuardProvider, (_, _) {});
    final _Session session = container.read(_sessionHolder.notifier);
    await pumpEventQueue();
    expect(cleaner.cleared, 0);

    // A loading moment in between (the record is read again): nothing.
    session.set(const SessionLoading());
    await pumpEventQueue();
    session.set(testVerifiedSession);
    await pumpEventQueue();
    expect(cleaner.cleared, 0);

    // Signed out: emptied.
    session.set(const SessionSignedOut());
    await pumpEventQueue();
    expect(cleaner.cleared, 1);

    // Another parent signs in on the same phone: nothing more to empty.
    session.set(_otherParent);
    await pumpEventQueue();
    expect(cleaner.cleared, 1);

    // Straight from one parent to another (no signed-out state seen): emptied.
    session.set(testVerifiedSession);
    await pumpEventQueue();
    expect(cleaner.cleared, 2);

    // Signed out through a loading moment: still emptied.
    session.set(const SessionLoading());
    await pumpEventQueue();
    session.set(const SessionSignedOut());
    await pumpEventQueue();
    expect(cleaner.cleared, 3);
  });
}
