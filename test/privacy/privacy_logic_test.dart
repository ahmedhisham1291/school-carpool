// Privacy and security logic (Prompt 12): analytics never receives personal
// data, screen names are route patterns, the app lock rules, the offline
// confirmation queue, image sizing, the new-phone gate, and the models.
// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/privacy/device_guard.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/schedule/offline_confirmations.dart';
import 'package:school_carpool/features/security/app_lock.dart';
import 'package:school_carpool/features/verification/image_compressor.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/observability/sentry_area.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/privacy_fakes.dart';
import '../helpers/wallet_fakes.dart';

/// Values that must never reach analytics.
const List<Object> _pii = <Object>[
  '+201001234567',
  '01012345678',
  '29001011234567',
  '30.0444,31.2357',
  'parent@example.com',
  'Omar Ali',
  'pick up at the gate',
  'ABCD2345',
  'uid-1234567890',
  123456789,
  30.0444,
];

Account _account({bool newDevice = false}) => Account(
  parentId: 'ABCD2345',
  status: AccountStatus.verified,
  phone: '+201000000001',
  email: 'parent@example.com',
  emailVerified: true,
  termsAccepted: true,
  language: 'ar',
  newDeviceCheck: newDevice,
);

void main() {
  group('analytics never receives personal data', () {
    test('every event carries only its own keys and clean values', () async {
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      final Analytics analytics = Analytics(sink, enabled: true);
      for (final AnalyticsEvent e in AnalyticsEvent.values) {
        analytics.track(e, <String, Object?>{
          for (final String k in e.keys) k: 'done',
          'phone': '+201001234567',
          'text': 'my message',
          'lat': 30.0444,
          'firstName': 'Omar',
          'uid': 'uid-1',
        });
      }
      await pumpEventQueue();
      expect(sink.events, hasLength(AnalyticsEvent.values.length));
      for (final (String name, Map<String, Object> params) in sink.events) {
        final AnalyticsEvent e = AnalyticsEvent.values.firstWhere((AnalyticsEvent x) => x.wire == name);
        expect(params.keys.toSet().difference(e.keys), isEmpty, reason: name);
        expect(params.values.every((Object v) => v == 'done'), isTrue, reason: name);
      }
    });

    test('values that could be personal are dropped, even under an allowed key', () async {
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      final Analytics analytics = Analytics(sink, enabled: true);
      for (final Object v in _pii) {
        analytics.track(AnalyticsEvent.runEnded, <String, Object?>{'direction': v, 'result': v});
      }
      analytics.track(AnalyticsEvent.appLockChanged, <String, Object?>{'enabled': true});
      await pumpEventQueue();
      for (final (String _, Map<String, Object> params) in sink.events.take(_pii.length)) {
        expect(params, isEmpty);
      }
      expect(sink.events.last.$2, <String, Object>{'enabled': 1});
      final String all = sink.events.toString();
      for (final Object v in _pii) {
        expect(all.contains(v.toString()), isFalse, reason: '$v leaked');
      }
    });

    test('event names are short lowercase words (Firebase limits) and unique', () {
      final Set<String> names = <String>{};
      for (final AnalyticsEvent e in AnalyticsEvent.values) {
        expect(RegExp(r'^[a-z][a-z_]{0,39}$').hasMatch(e.wire), isTrue, reason: e.wire);
        expect(names.add(e.wire), isTrue, reason: 'duplicate ${e.wire}');
        for (final String k in e.keys) {
          expect(RegExp(r'^[a-z][a-z_]{0,39}$').hasMatch(k), isTrue, reason: k);
        }
      }
    });

    test('screen names are route patterns, never IDs or codes', () {
      expect(AnalyticsPrivacy.screenName('/carpools/:carpoolId/trip/:runId/drive'), 'carpools/:id/trip/:id/drive');
      expect(AnalyticsPrivacy.screenName('/profile/privacy/devices'), 'profile/privacy/devices');
      expect(AnalyticsPrivacy.screenName('/carpools/invite/ABCDEFGH22'), 'carpools/invite/:x');
      expect(AnalyticsPrivacy.screenName('/chats/cp_private/dm-0123abcd'), 'chats/:x/:x');
      expect(AnalyticsPrivacy.screenName('/'), 'root');
    });

    test('nothing is sent once the parent switches statistics off', () async {
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      final InMemorySettingsStore store = InMemorySettingsStore();
      final Analytics analytics = Analytics(sink, enabled: AnalyticsConsent.read(store));
      expect(analytics.enabled, isTrue, reason: 'on by default (owner decision)');
      await saveAnalyticsChoice(store, analytics, enabled: false);
      expect(sink.enabled, isFalse);
      expect(AnalyticsConsent.read(store), isFalse);
      analytics
        ..track(AnalyticsEvent.chatOpened, <String, Object?>{'kind': 'private'})
        ..screen('/chats');
      await pumpEventQueue();
      expect(sink.events, isEmpty);
      expect(sink.screens, isEmpty);
    });
  });

  group('app lock', () {
    test('locked again after 30 seconds away, not before', () {
      final DateTime t = DateTime.utc(2026, 11, 14, 8);
      expect(lockAfterBackground(enabled: true, leftAt: t, now: t.add(const Duration(seconds: 29))), isFalse);
      expect(lockAfterBackground(enabled: true, leftAt: t, now: t.add(const Duration(seconds: 30))), isTrue);
      expect(lockAfterBackground(enabled: false, leftAt: t, now: t.add(const Duration(hours: 1))), isFalse);
      expect(lockAfterBackground(enabled: true, leftAt: null, now: t), isTrue);
    });

    test('switching on needs one successful check; it opens locked; leaving covers it', () async {
      final FakeDeviceAuth auth = FakeDeviceAuth(DeviceAuthResult.cancelled);
      final InMemorySettingsStore store = InMemorySettingsStore();
      final ProviderContainer c = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store), deviceAuthProvider.overrideWithValue(auth)],
      );
      addTearDown(c.dispose);
      final AppLockController lock = c.read(appLockProvider.notifier);
      expect(c.read(appLockProvider).enabled, isFalse);
      expect(await lock.setEnabled(true, 'reason'), DeviceAuthResult.cancelled);
      expect(c.read(appLockProvider).enabled, isFalse);
      auth.result = DeviceAuthResult.ok;
      expect(await lock.setEnabled(true, 'reason'), DeviceAuthResult.ok);
      expect(store.read(AppLockController.storageKey), 'true');

      DateTime now = DateTime.utc(2026, 11, 14, 8);
      lock.now = () => now;
      lock.left();
      expect(c.read(appLockProvider).showLock, isTrue, reason: 'covered in the app switcher');
      expect(c.read(appLockProvider).locked, isFalse);
      now = now.add(const Duration(seconds: 10));
      lock.resumed();
      expect(c.read(appLockProvider).showLock, isFalse, reason: 'back within the grace time');
      lock.left();
      now = now.add(const Duration(minutes: 5));
      lock.resumed();
      expect(c.read(appLockProvider).locked, isTrue);
      expect(await lock.unlock('reason'), isTrue);
      expect(c.read(appLockProvider).showLock, isFalse);

      // A new start of the app opens locked.
      final ProviderContainer next = ProviderContainer(
        overrides: [settingsStoreProvider.overrideWithValue(store), deviceAuthProvider.overrideWithValue(auth)],
      );
      addTearDown(next.dispose);
      expect(next.read(appLockProvider).locked, isTrue);
    });
  });

  group('offline confirmations', () {
    test('queued once per run, kept as IDs only, at most 20', () {
      List<PendingConfirm> list = <PendingConfirm>[];
      list = PendingConfirms.add(list, const PendingConfirm('k1', 'r1'));
      list = PendingConfirms.add(list, const PendingConfirm('k1', 'r1'));
      list = PendingConfirms.add(list, const PendingConfirm('k1', 'r2'));
      expect(list, hasLength(2));
      final String? stored = PendingConfirms.encode(list);
      expect(stored, 'k1|r1,k1|r2');
      expect(PendingConfirms.decode(stored), list);
      expect(PendingConfirms.decode('bad,,k|'), isEmpty);
      expect(PendingConfirms.encode(<PendingConfirm>[]), isNull);
      for (int i = 0; i < 30; i++) {
        list = PendingConfirms.add(list, PendingConfirm('k2', 'r$i'));
      }
      expect(list, hasLength(PendingConfirms.max));
      expect(list.last, const PendingConfirm('k2', 'r29'));
    });
  });

  group('photo sizing (long edge about 1600)', () {
    Uint8List jpeg(int width, int height) => Uint8List.fromList(<int>[
      0xFF, 0xD8, //
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, 2 bytes of data
      0xFF, 0xC0, 0x00, 0x11, 0x08, height >> 8, height & 0xFF, width >> 8, width & 0xFF, 0x03, //
      ...List<int>.filled(12, 0),
    ]);

    test('reads the size of a JPEG and a PNG', () {
      expect(ImageSizing.size(jpeg(4032, 3024)), (4032, 3024));
      final Uint8List png = Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, //
        0, 0, 0x07, 0xD0, 0, 0, 0x03, 0xE8,
      ]);
      expect(ImageSizing.size(png), (2000, 1000));
      expect(ImageSizing.size(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    });

    test('the short side is scaled so the long edge ends at 1600; never enlarged', () {
      expect(ImageSizing.shortSideTarget((4032, 3024)), 1200);
      expect(ImageSizing.shortSideTarget((1920, 1080)), 900);
      expect(ImageSizing.shortSideTarget((1080, 1920)), 900, reason: 'portrait too');
      expect(ImageSizing.shortSideTarget((1280, 720)), 720, reason: 'already small');
      expect(ImageSizing.shortSideTarget(null), 1600);
    });

    test('recognises WebP', () {
      expect(ImageSizing.isWebp(Uint8List.fromList('RIFF\u0000\u0000\u0000\u0000WEBPVP8 '.codeUnits)), isTrue);
      expect(ImageSizing.isWebp(jpeg(10, 10)), isFalse);
    });
  });

  group('new phone', () {
    test('chats, the wallet and child data wait for the selfie; the rest stays open', () {
      final SessionState session = SessionSignedIn(uid: 'uid-1', account: _account(newDevice: true));
      for (final String closed in <String>['/chats', '/chats/cp_private/x', '/carpools/k1', ProfileRoutes.wallet, ProfileRoutes.children, ProfileRoutes.family]) {
        expect(sessionRedirect(session, closed), PrivacyRoutes.newDevice, reason: closed);
      }
      for (final String open in <String>['/home', '/carpools', '/profile', PrivacyRoutes.privacy, PrivacyRoutes.newDevice, '/carpools/invite/ABC']) {
        expect(sessionRedirect(session, open), isNull, reason: open);
      }
      expect(sessionRedirect(SessionSignedIn(uid: 'uid-1', account: _account()), '/chats'), isNull);
    });

    test('the account reads the check from the record', () {
      expect(Account.fromMap(<String, dynamic>{'newDeviceCheck': <String, dynamic>{'required': true}}).newDeviceCheck, isTrue);
      expect(Account.fromMap(<String, dynamic>{'newDeviceCheck': null}).newDeviceCheck, isFalse);
      expect(Account.fromMap(<String, dynamic>{}).newDeviceCheck, isFalse);
    });

    test('the phone reports itself on a new session and every 15 minutes', () {
      final DateTime t = DateTime.utc(2026, 11, 14, 8);
      expect(shouldTouch(uid: 'a', lastUid: null, lastAt: null, now: t), isTrue);
      expect(shouldTouch(uid: 'a', lastUid: 'a', lastAt: t, now: t.add(const Duration(minutes: 14))), isFalse);
      expect(shouldTouch(uid: 'a', lastUid: 'a', lastAt: t, now: t.add(const Duration(minutes: 15))), isTrue);
      expect(shouldTouch(uid: 'b', lastUid: 'a', lastAt: t, now: t), isTrue);
    });
  });

  group('models', () {
    test('the data types follow the server list (functions/src/privacy/retention.ts)', () {
      expect(DataType.values.map((DataType t) => t.name).toList(), <String>[
        'account', 'consents', 'idPhotos', 'children', 'vehicle', 'home', 'carpools', 'schedule', 'trips', //
        'liveLocation', 'routeArchive', 'chat', 'ratings', 'familyLinks', 'handover', 'emergencyContact',
        'notifications', 'devices', 'wallet', 'reports', 'analytics', 'crashReports',
      ]);
      expect(keepOf(DataType.idPhotos), Keep.yearAfterClosure);
      expect(keepOf(DataType.trips), Keep.yearAfterClosure);
      expect(keepOf(DataType.routeArchive), Keep.yearAfterRun);
      expect(keepOf(DataType.chat), Keep.yearAfterChat);
      expect(keepOf(DataType.liveLocation), Keep.oneDay);
      expect(keepOf(DataType.wallet), Keep.law);
      expect(keepOf(DataType.home), Keep.untilDeletion);
    });

    test('overview, devices and requests parse the server answers', () {
      final PrivacyOverview o = PrivacyOverview.fromMap(<Object?, Object?>{
        'consents': <Object?>[
          <Object?, Object?>{'kind': 'analytics', 'active': true},
          <Object?, Object?>{'kind': 'face', 'active': true, 'acceptedAtMs': 1763100000000, 'version': '2026-11-14'},
          <Object?, Object?>{'kind': 'unknown-kind', 'active': true},
        ],
        'requests': <Object?>[
          <Object?, Object?>{'id': 'r1', 'kind': 'export', 'status': 'done', 'createdAtMs': 1763100000000},
        ],
      });
      expect(o.consents.map((ConsentView c) => c.kind), <ConsentKind>[ConsentKind.analytics, ConsentKind.face]);
      expect(o.consent(ConsentKind.face)?.version, '2026-11-14');
      expect(o.requests.single.kind, RequestKind.exportData);
      final DeviceList d = DeviceList.fromMap(<Object?, Object?>{
        'current': 's_1',
        'devices': <Object?>[
          <Object?, Object?>{'key': 's_1', 'platform': 'ios', 'lastSeenAtMs': 1, 'firstSignInAtMs': 1},
          <Object?, Object?>{'key': 's_2', 'platform': 'android', 'lastSeenAtMs': 1, 'firstSignInAtMs': 1, 'signedOutAtMs': 5},
        ],
        'logins': <Object?>[
          <Object?, Object?>{'atMs': 1, 'platform': 'web', 'newDevice': true},
        ],
      });
      expect(d.devices.where((DeviceEntry e) => e.active).single.key, 's_1');
      expect(d.logins.single.newDevice, isTrue);
      expect(d.logins.single.platform, DevicePlatform.web);
    });

    test('failures map the server reasons', () {
      PrivacyFailure f(String reason, [String code = 'failed-precondition']) =>
          PrivacyFailure.from(FirebaseFunctionsException(code: code, message: reason, details: <String, Object?>{'reason': reason}));
      expect(f('wallet-not-empty').kind, PrivacyFailureKind.walletNotEmpty);
      expect(f('wallet-pending').kind, PrivacyFailureKind.walletPending);
      expect(f('driving-now').kind, PrivacyFailureKind.drivingNow);
      expect(f('device-check').kind, PrivacyFailureKind.deviceCheck);
      expect(f('selfie-mismatch', 'permission-denied').kind, PrivacyFailureKind.selfieMismatch);
      expect(f('x', 'unavailable').kind, PrivacyFailureKind.offline);
      expect(PrivacyFailure.from(StateError('x')).kind, PrivacyFailureKind.unknown);
    });

    test('Sentry areas come from route patterns', () {
      expect(SentryArea.ofPath('/signup/code'), 'signin');
      expect(SentryArea.ofPath('/carpools/:carpoolId/trip/:runId/drive'), 'trips');
      expect(SentryArea.ofPath('/profile/wallet/send'), 'wallet');
      expect(SentryArea.ofPath('/profile/privacy/delete'), 'privacy');
      expect(SentryArea.ofPath('/home'), 'other');
    });
  });
}
