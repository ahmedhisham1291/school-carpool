// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/tracker_guard.dart';

import '../helpers/test_app.dart';

final NotifierProvider<_Session, SessionState> _sessionHolder = NotifierProvider<_Session, SessionState>(_Session.new);

class _Session extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionLoading();

  void set(SessionState s) => state = s;
}

const SessionState _accountLoading = SessionSignedIn(uid: 'uid-1', account: null);

const SessionState _suspended = SessionSignedIn(
  uid: 'uid-1',
  account: Account(
    parentId: 'ABCD2345',
    status: AccountStatus.suspended,
    phone: '+201000000001',
    email: 'parent@example.com',
    emailVerified: true,
    termsAccepted: true,
    language: 'ar',
  ),
);

const SessionState _otherParent = SessionSignedIn(uid: 'uid-2', account: null);

const TrackerSession _run = TrackerSession(tripId: 't1', uploadUrl: 'https://x.test', token: 'tok');

/// A phone in the middle of a run (the tracker survived a relaunch), with
/// the guard watching a session the test moves through its states.
Future<(ProviderContainer, FakeLocationTracker)> _midRun() async {
  final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
  await tracker.start(_run);
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      sessionProvider.overrideWith((Ref ref) => ref.watch(_sessionHolder)),
      locationTrackerProvider.overrideWithValue(tracker),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(tracker.dispose);
  // Listened like the app does (app.dart watches it).
  container.listen<void>(trackerGuardProvider, (_, _) {});
  return (container, tracker);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('decision', () {
    test('loading, failed and account not loaded yet decide nothing', () {
      expect(trackerGuardDecision(const SessionLoading(), null), isNull);
      expect(trackerGuardDecision(const SessionLoading(), 'uid-1'), isNull);
      expect(trackerGuardDecision(const SessionFailed(offline: true), 'uid-1'), isNull);
      expect(trackerGuardDecision(_accountLoading, null), isNull);
      expect(trackerGuardDecision(_accountLoading, 'uid-1'), isNull);
      expect(trackerGuardDecision(testVerifiedSession, null), isNull);
    });

    test('sign-out, another parent and a loaded unverified account stop', () {
      expect(trackerGuardDecision(const SessionSignedOut(), 'uid-1'), TrackerGuardStop.signedOut);
      expect(trackerGuardDecision(_otherParent, 'uid-1'), TrackerGuardStop.otherParent);
      expect(trackerGuardDecision(_suspended, 'uid-1'), TrackerGuardStop.notVerified);
      expect(trackerGuardDecision(testUnverifiedSession, null), TrackerGuardStop.notVerified);
    });
  });

  group('relaunch mid-run', () {
    test('loading, then account loading, then verified: keeps tracking', () async {
      final (ProviderContainer container, FakeLocationTracker tracker) = await _midRun();
      await _settle();
      container.read(_sessionHolder.notifier).set(const SessionFailed(offline: true));
      await _settle();
      container.read(_sessionHolder.notifier).set(_accountLoading);
      await _settle();
      container.read(_sessionHolder.notifier).set(testVerifiedSession);
      await _settle();
      expect(tracker.stops, 0);
      expect(await tracker.activeTrip(), 't1');
    });

    test('account loads suspended: stops and keeps unsent points', () async {
      final (ProviderContainer container, FakeLocationTracker tracker) = await _midRun();
      container.read(_sessionHolder.notifier).set(_accountLoading);
      await _settle();
      container.read(_sessionHolder.notifier).set(_suspended);
      await _settle();
      expect(tracker.stops, 1);
      expect(tracker.lastStopKeptUnsent, isTrue);
    });

    test('another parent signs in: stops', () async {
      final (ProviderContainer container, FakeLocationTracker tracker) = await _midRun();
      container.read(_sessionHolder.notifier).set(testVerifiedSession);
      await _settle();
      container.read(_sessionHolder.notifier).set(_otherParent);
      await _settle();
      expect(tracker.stops, 1);
      expect(tracker.lastStopKeptUnsent, isTrue);
    });

    test('signed out: stops', () async {
      final (ProviderContainer container, FakeLocationTracker tracker) = await _midRun();
      container.read(_sessionHolder.notifier).set(testVerifiedSession);
      await _settle();
      container.read(_sessionHolder.notifier).set(const SessionSignedOut());
      await _settle();
      expect(tracker.stops, 1);
    });
  });
}
