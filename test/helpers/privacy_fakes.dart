import 'dart:typed_data';

import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';

/// Privacy fakes (Prompt 12). Fake data only.

final DateTime privacyNow = DateTime.utc(2026, 11, 14, 8);

PrivacyOverview sampleOverview() => PrivacyOverview(
  consents: <ConsentView>[
    for (final ConsentKind k in ConsentKind.values)
      ConsentView(
        kind: k,
        active: k != ConsentKind.walletTerms,
        acceptedAt: k == ConsentKind.walletTerms ? null : privacyNow,
      ),
  ],
  requests: <PrivacyRequest>[
    PrivacyRequest(id: 'r1', kind: RequestKind.exportData, status: RequestStatus.done, createdAt: privacyNow),
    PrivacyRequest(id: 'r2', kind: RequestKind.correct, status: RequestStatus.open, createdAt: privacyNow, subject: 'name'),
  ],
);

DeviceList sampleDevices() => DeviceList(
  current: 's_${'a' * 40}',
  devices: <DeviceEntry>[
    DeviceEntry(key: 's_${'a' * 40}', platform: DevicePlatform.ios, lastSeen: privacyNow, firstSignIn: privacyNow),
    DeviceEntry(key: 's_${'b' * 40}', platform: DevicePlatform.android, lastSeen: privacyNow, firstSignIn: privacyNow),
  ],
  logins: <LoginEntry>[
    LoginEntry(at: privacyNow, platform: DevicePlatform.ios, newDevice: false),
    LoginEntry(at: privacyNow, platform: DevicePlatform.android, newDevice: true),
  ],
);

/// Records calls; [failure] is thrown by every call when set, [failOnce] by the next call of that name.
class FakePrivacyRepository implements PrivacyRepository {
  PrivacyOverview overviewValue = sampleOverview();
  DeviceList devicesValue = sampleDevices();
  final List<String> calls = <String>[];
  PrivacyFailure? failure;
  final Map<String, PrivacyFailure> failOnce = <String, PrivacyFailure>{};
  WithdrawEffect effect = WithdrawEffect.analyticsOff;
  bool signedOutHere = false;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final PrivacyFailure? once = failOnce.remove(call.split(':').first);
    if (once != null) {
      throw once;
    }
    final PrivacyFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<PrivacyOverview> overview() async {
    await _maybeFail('overview');
    return overviewValue;
  }

  @override
  Future<WithdrawEffect> setConsent(ConsentKind kind, {required bool granted}) async {
    await _maybeFail('setConsent:${kind.name}:$granted');
    return granted ? WithdrawEffect.granted : effect;
  }

  @override
  Future<void> requestCorrection(CorrectionField field) => _maybeFail('requestCorrection:${field.name}');

  @override
  Future<void> requestPhotoCopy() => _maybeFail('requestPhotoCopy');

  @override
  Future<ExportLink> exportData() async {
    await _maybeFail('exportData');
    return ExportLink(url: 'https://storage.example/export.json', expiresAt: privacyNow.add(const Duration(hours: 1)));
  }

  @override
  Future<void> deleteAccount() => _maybeFail('deleteAccount');

  @override
  Future<DeviceList> devices() async {
    await _maybeFail('devices');
    return devicesValue;
  }

  @override
  Future<String> signOutDevice({String? deviceKey, bool all = false}) async {
    await _maybeFail('signOutDevice:${all ? 'all' : deviceKey}');
    return 'fresh-token';
  }

  @override
  Future<bool> touchDevice() async {
    await _maybeFail('touchDevice');
    return signedOutHere;
  }

  @override
  Future<bool> confirmNewDevice({required String uid, required Uint8List selfie}) async {
    await _maybeFail('confirmNewDevice:$uid');
    return false;
  }
}

/// Records what analytics would send.
class RecordingAnalyticsSink implements AnalyticsSink {
  final List<(String, Map<String, Object>)> events = <(String, Map<String, Object>)>[];
  final List<String> screens = <String>[];
  bool? enabled;

  @override
  Future<void> event(String name, Map<String, Object> parameters) async {
    events.add((name, parameters));
  }

  @override
  Future<void> screen(String name) async {
    screens.add(name);
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    this.enabled = enabled;
  }
}
