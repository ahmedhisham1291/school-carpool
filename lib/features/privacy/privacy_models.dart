import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/firebase/callable_error.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Privacy and security (Prompt 12, spec section 7). Same codes as the
/// server (functions/src/privacy/requests.ts, devices.ts, retention.ts).

String _str(Object? v) => v is String ? v : '';
Map<Object?, Object?> _map(Object? v) => v is Map<Object?, Object?> ? v : const <Object?, Object?>{};
List<Object?> _list(Object? v) => v is List<Object?> ? v : const <Object?>[];
DateTime? _time(Object? v) => v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true) : null;

/// Every data type the app keeps, in the server's order
/// (DATA_TYPES in functions/src/privacy/retention.ts).
enum DataType {
  account,
  consents,
  idPhotos,
  children,
  vehicle,
  home,
  carpools,
  schedule,
  trips,
  liveLocation,
  routeArchive,
  chat,
  ratings,
  familyLinks,
  handover,
  emergencyContact,
  notifications,
  devices,
  wallet,

  /// Settle up (F45): my InstaPay address and my payment records.
  settleUp,
  reports,
  analytics,
  crashReports,
}

/// How long a data type is kept (shown on the privacy screen).
enum Keep {
  /// Deleted when the account is deleted.
  untilDeletion,

  /// Kept while the account is open and 1 year after it closes.
  yearAfterClosure,

  /// Deleted within 24 hours of each run.
  oneDay,

  /// 1 year after the run.
  yearAfterRun,

  /// For the life of the chat and 1 year after it ends.
  yearAfterChat,

  /// 60 days.
  sixtyDays,

  /// 90 days.
  ninetyDays,

  /// As long as the law requires: transfer records, 5 years
  /// (TRANSFER_RECORD_YEARS on the server; confirmed by the lawyer and the
  /// owner, DECISIONS.md 14 Nov 2026 13:29).
  law,

  /// Open reports stay until handled; the message copy 1 year after.
  untilHandled,
}

/// The retention of each type (functions/src/privacy/retention.ts RETENTION).
Keep keepOf(DataType t) => switch (t) {
  // Settle up records: same rule as trips (while either parent's account
  // is open, and 1 year after).
  // Owner decision 16 Nov 2026 (App Review 5.1.1(v)): ID photos, selfies
  // and the face reference go with the account (Keep.untilDeletion).
  DataType.consents || DataType.trips || DataType.settleUp => Keep.yearAfterClosure,
  DataType.liveLocation => Keep.oneDay,
  DataType.routeArchive => Keep.yearAfterRun,
  DataType.chat => Keep.yearAfterChat,
  DataType.notifications || DataType.analytics => Keep.sixtyDays,
  DataType.devices || DataType.crashReports => Keep.ninetyDays,
  DataType.wallet => Keep.law,
  DataType.reports => Keep.untilHandled,
  _ => Keep.untilDeletion,
};

/// Consents the parent sees and can withdraw (CONSENT_KINDS on the server).
enum ConsentKind {
  terms,
  privacy,
  conduct,
  whatsapp,
  id,
  face,
  childData,
  walletTerms,
  analytics,
  showOnMap;

  static ConsentKind? fromName(Object? v) {
    for (final ConsentKind k in values) {
      if (k.name == v) {
        return k;
      }
    }
    return null;
  }

  /// A switch on the privacy screen (on and off); the others can only be
  /// withdrawn, and for some that means deleting the account.
  bool get switchable => this == ConsentKind.analytics || this == ConsentKind.showOnMap || this == ConsentKind.whatsapp;
}

/// What withdrawing did (server: withdrawEffect).
enum WithdrawEffect {
  granted,
  whatsappOff,
  analyticsOff,
  hiddenFromMap,
  walletClosed,
  needsDeletion,
  needsChildRemoval;

  static WithdrawEffect fromName(Object? v) =>
      values.firstWhere((WithdrawEffect e) => e.name == v, orElse: () => WithdrawEffect.needsDeletion);
}

@immutable
class ConsentView {
  const ConsentView({required this.kind, required this.active, this.acceptedAt, this.withdrawnAt, this.version});

  static ConsentView? fromMap(Map<Object?, Object?> m) {
    final ConsentKind? kind = ConsentKind.fromName(m['kind']);
    if (kind == null) {
      return null;
    }
    return ConsentView(
      kind: kind,
      active: m['active'] == true,
      acceptedAt: _time(m['acceptedAtMs']),
      withdrawnAt: _time(m['withdrawnAtMs']),
      version: m['version'] is String ? m['version']! as String : null,
    );
  }

  final ConsentKind kind;
  final bool active;
  final DateTime? acceptedAt;
  final DateTime? withdrawnAt;
  final String? version;
}

/// What a logged privacy request was (server: REQUEST_KINDS).
enum RequestKind {
  exportData('export'),
  delete('delete'),
  correct('correct'),
  withdraw('withdraw'),
  consent('consent'),
  photoCopy('photoCopy');

  const RequestKind(this.wire);

  final String wire;
}

enum RequestStatus { done, open, refused, failed }

/// One logged privacy request (privacyRequests on the server).
@immutable
class PrivacyRequest {
  const PrivacyRequest({required this.id, required this.kind, required this.status, required this.createdAt, this.subject});

  factory PrivacyRequest.fromMap(Map<Object?, Object?> m) => PrivacyRequest(
    id: _str(m['id']),
    kind: RequestKind.values.firstWhere((RequestKind k) => k.wire == m['kind'], orElse: () => RequestKind.correct),
    status: RequestStatus.values.firstWhere((RequestStatus s) => s.name == m['status'], orElse: () => RequestStatus.open),
    createdAt: _time(m['createdAtMs']) ?? DateTime.utc(2026),
    subject: m['subject'] is String ? m['subject']! as String : null,
  );

  final String id;
  final RequestKind kind;
  final RequestStatus status;
  final DateTime createdAt;
  final String? subject;
}

@immutable
class PrivacyOverview {
  const PrivacyOverview({this.consents = const <ConsentView>[], this.requests = const <PrivacyRequest>[]});

  factory PrivacyOverview.fromMap(Map<Object?, Object?> m) => PrivacyOverview(
    consents: <ConsentView>[
      for (final Object? c in _list(m['consents']))
        if (ConsentView.fromMap(_map(c)) case final ConsentView v) v,
    ],
    requests: <PrivacyRequest>[for (final Object? r in _list(m['requests'])) PrivacyRequest.fromMap(_map(r))],
  );

  final List<ConsentView> consents;
  final List<PrivacyRequest> requests;

  ConsentView? consent(ConsentKind kind) {
    for (final ConsentView c in consents) {
      if (c.kind == kind) {
        return c;
      }
    }
    return null;
  }
}

enum DevicePlatform { ios, android, web }

/// One phone of the account (users/{uid}/devices on the server).
@immutable
class DeviceEntry {
  const DeviceEntry({required this.key, required this.platform, required this.lastSeen, required this.firstSignIn, this.signedOutAt});

  factory DeviceEntry.fromMap(Map<Object?, Object?> m) => DeviceEntry(
    key: _str(m['key']),
    platform: DevicePlatform.values.firstWhere((DevicePlatform p) => p.name == m['platform'], orElse: () => DevicePlatform.ios),
    lastSeen: _time(m['lastSeenAtMs']) ?? DateTime.utc(2026),
    firstSignIn: _time(m['firstSignInAtMs']) ?? DateTime.utc(2026),
    signedOutAt: _time(m['signedOutAtMs']),
  );

  final String key;
  final DevicePlatform platform;
  final DateTime lastSeen;
  final DateTime firstSignIn;
  final DateTime? signedOutAt;

  bool get active => signedOutAt == null;
}

@immutable
class LoginEntry {
  const LoginEntry({required this.at, required this.platform, required this.newDevice});

  factory LoginEntry.fromMap(Map<Object?, Object?> m) => LoginEntry(
    at: _time(m['atMs']) ?? DateTime.utc(2026),
    platform: DevicePlatform.values.firstWhere((DevicePlatform p) => p.name == m['platform'], orElse: () => DevicePlatform.ios),
    newDevice: m['newDevice'] == true,
  );

  final DateTime at;
  final DevicePlatform platform;
  final bool newDevice;
}

@immutable
class DeviceList {
  const DeviceList({required this.current, this.devices = const <DeviceEntry>[], this.logins = const <LoginEntry>[]});

  factory DeviceList.fromMap(Map<Object?, Object?> m) => DeviceList(
    current: _str(m['current']),
    devices: <DeviceEntry>[for (final Object? d in _list(m['devices'])) DeviceEntry.fromMap(_map(d))],
    logins: <LoginEntry>[for (final Object? l in _list(m['logins'])) LoginEntry.fromMap(_map(l))],
  );

  /// The key of this phone.
  final String current;
  final List<DeviceEntry> devices;
  final List<LoginEntry> logins;
}

@immutable
class ExportLink {
  const ExportLink({required this.url, required this.expiresAt});

  factory ExportLink.fromMap(Map<Object?, Object?> m) =>
      ExportLink(url: _str(m['url']), expiresAt: _time(m['expiresAtMs']) ?? DateTime.utc(2026));

  final String url;
  final DateTime expiresAt;
}

/// Fields a parent asks to correct (server: SELF_CORRECTED and ADMIN_CORRECTED).
enum CorrectionField { email, children, home, vehicle, emergencyContact, handover, name, nationalId, birthDate, other }

enum PrivacyFailureKind {
  walletNotEmpty,
  walletPending,
  drivingNow,
  rateLimited,
  deviceCheck,
  noSelfie,
  noReference,
  selfieMismatch,
  selfieUnchecked,
  ownDevice,
  exportFailed,
  offline,
  unknown,
}

class PrivacyFailure implements AppFailure {
  const PrivacyFailure(this.kind, {this.demo});

  factory PrivacyFailure.from(Object error) {
    if (error is PrivacyFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return PrivacyFailure(PrivacyFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final String? reason = callableReason(error);
      return PrivacyFailure(switch (reason) {
        'wallet-not-empty' => PrivacyFailureKind.walletNotEmpty,
        'wallet-pending' => PrivacyFailureKind.walletPending,
        // The payment partner did not answer: nothing was deleted; try later.
        'wallet-unavailable' => PrivacyFailureKind.unknown,
        'driving-now' => PrivacyFailureKind.drivingNow,
        'rate-limited' => PrivacyFailureKind.rateLimited,
        'device-check' => PrivacyFailureKind.deviceCheck,
        'no-selfie' => PrivacyFailureKind.noSelfie,
        'no-reference' => PrivacyFailureKind.noReference,
        'selfie-mismatch' => PrivacyFailureKind.selfieMismatch,
        'selfie-unchecked' => PrivacyFailureKind.selfieUnchecked,
        'own-device' => PrivacyFailureKind.ownDevice,
        'export-failed' => PrivacyFailureKind.exportFailed,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => PrivacyFailureKind.offline,
          _ => PrivacyFailureKind.unknown,
        },
      });
    }
    if (error is FirebaseException && (error.code == 'unavailable' || error.code == 'retry-limit-exceeded')) {
      return const PrivacyFailure(PrivacyFailureKind.offline);
    }
    return const PrivacyFailure(PrivacyFailureKind.unknown);
  }

  final PrivacyFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  @override
  bool get isOffline => kind == PrivacyFailureKind.offline;

  /// One short sentence that says what happened and what to do.
  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    PrivacyFailureKind.walletNotEmpty => l10n.privacyErrorWalletNotEmpty,
    PrivacyFailureKind.walletPending => l10n.privacyErrorWalletPending,
    PrivacyFailureKind.drivingNow => l10n.privacyErrorDriving,
    PrivacyFailureKind.rateLimited => l10n.privacyErrorRateLimited,
    PrivacyFailureKind.deviceCheck => l10n.newDeviceBody,
    PrivacyFailureKind.noSelfie => l10n.phoneChangeErrorSelfie,
    PrivacyFailureKind.noReference => l10n.phoneChangeErrorNoReference,
    PrivacyFailureKind.selfieMismatch => l10n.privacyErrorMismatch,
    PrivacyFailureKind.selfieUnchecked => l10n.privacyErrorUnchecked,
    PrivacyFailureKind.ownDevice => l10n.privacyErrorOwnDevice,
    PrivacyFailureKind.exportFailed => l10n.privacyErrorExport,
    PrivacyFailureKind.offline => l10n.errorOfflineShort,
    PrivacyFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'PrivacyFailure(${kind.name})';
}
