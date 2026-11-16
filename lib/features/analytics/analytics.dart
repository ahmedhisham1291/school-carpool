import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/observability/pii_scrubber.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Usage analytics (owner decision, DECISIONS.md "Data retention and
/// collection", 14 Nov 2026): screens and features used, with NO names,
/// phone numbers, IDs, message text or coordinates. Crashes go to Sentry.
/// OFF until the parent says yes (owner decision 16 Nov 2026, App Review
/// guideline 5.1.1(ii)): the Home card asks once (analytics_ask_card.dart)
/// and the switch is in Settings and on the privacy screen. No App
/// Tracking Transparency prompt is needed: nothing is combined with other
/// companies' data, there is no advertising and no IDFA (guideline
/// 5.1.2(i)). The catalog of events is docs/analytics-events.md.
///
/// Everything goes through [Analytics], which keeps only the events and
/// parameter keys of [AnalyticsEvent] and drops any value that could be
/// personal, so a mistake in a screen cannot send data it should not.

/// Every event the app may send, with the only parameter keys it may carry.
enum AnalyticsEvent {
  signInDone('sign_in_done', <String>{'new_device'}),
  verificationSubmitted('verification_submitted', <String>{'scope'}),
  carpoolCreated('carpool_created', <String>{'kind'}),
  carpoolJoinRequested('carpool_join_requested', <String>{}),
  runConfirmed('run_confirmed', <String>{'direction'}),
  runStarted('run_started', <String>{'direction'}),
  runEnded('run_ended', <String>{'direction', 'result'}),
  chatOpened('chat_opened', <String>{'kind'}),
  walletTransfer('wallet_transfer', <String>{'result'}),
  ratingGiven('rating_given', <String>{}),
  privacyExport('privacy_export', <String>{'result'}),
  consentChanged('consent_changed', <String>{'kind', 'granted'}),
  accountDeleted('account_deleted', <String>{}),
  appLockChanged('app_lock_changed', <String>{'enabled'}),
  deviceSignedOut('device_signed_out', <String>{'all'}),
  // Settle up (F45): the kind of record and the step taken. Never an
  // amount, a name, a note or an InstaPay address.
  settleUpCreated('settle_up_created', <String>{'kind', 'purpose'}),
  settleUpAction('settle_up_action', <String>{'step'}),
  settleUpAddress('settle_up_address', <String>{'step'});

  const AnalyticsEvent(this.wire, this.keys);

  final String wire;
  final Set<String> keys;
}

/// Where analytics events go (Firebase in the app; a recorder in tests).
abstract interface class AnalyticsSink {
  Future<void> event(String name, Map<String, Object> parameters);
  Future<void> screen(String name);
  Future<void> setEnabled(bool enabled);
}

/// Nothing is sent: tests, the web before Stage 2, and builds without Firebase.
class NoAnalyticsSink implements AnalyticsSink {
  const NoAnalyticsSink();

  @override
  Future<void> event(String name, Map<String, Object> parameters) async {}

  @override
  Future<void> screen(String name) async {}

  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// Google Analytics for Firebase. No user ID or user properties are ever
/// set; the advertising identifiers are off (Info.plist keys,
/// tool/patch_native.py).
class FirebaseAnalyticsSink implements AnalyticsSink {
  FirebaseAnalyticsSink([FirebaseAnalytics? analytics]) : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  Future<void> event(String name, Map<String, Object> parameters) =>
      _analytics.logEvent(name: name, parameters: parameters.isEmpty ? null : parameters);

  @override
  Future<void> screen(String name) => _analytics.logScreenView(screenName: name, screenClass: name);

  @override
  Future<void> setEnabled(bool enabled) => _analytics.setAnalyticsCollectionEnabled(enabled);
}

abstract final class AnalyticsPrivacy {
  /// A parameter value may be a short lowercase word ("am", "done"), a
  /// bool, or a small whole number. Anything else is dropped.
  static final RegExp _word = RegExp(r'^[a-z][a-z_-]{0,23}$');

  static Object? cleanValue(Object? value) {
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is int) {
      return value >= 0 && value <= 1000 ? value : null;
    }
    if (value is String) {
      return _word.hasMatch(value) && PiiScrubber.scrubString(value) == value ? value : null;
    }
    return null;
  }

  /// Only the event's own keys, only clean values.
  static Map<String, Object> cleanParameters(AnalyticsEvent event, Map<String, Object?> parameters) => <String, Object>{
    for (final MapEntry<String, Object?> e in parameters.entries)
      if (event.keys.contains(e.key) && !PiiScrubber.isSensitiveKey(e.key))
        if (cleanValue(e.value) case final Object v) e.key: v,
  };

  /// A route pattern as a screen name: "/carpools/:carpoolId/trip/:runId"
  /// becomes "carpools/:id/trip/:id". A segment that is not a fixed word
  /// (an ID or code that slipped in) becomes ":x"; never a real value.
  static String screenName(String fullPath) {
    final List<String> segments = fullPath.split('/').where((String s) => s.isNotEmpty).map((String s) {
      if (s.startsWith(':')) {
        return ':id';
      }
      return RegExp(r'^[a-z][a-z-]{0,30}$').hasMatch(s) ? s : ':x';
    }).toList();
    final String name = segments.isEmpty ? 'root' : segments.join('/');
    return name.length > 100 ? name.substring(0, 100) : name;
  }
}

/// The app's analytics: the parent's choice plus the privacy filter.
class Analytics {
  Analytics(this._sink, {required bool enabled}) : _collecting = enabled;

  final AnalyticsSink _sink;
  bool _collecting;
  String? _lastScreen;

  bool get enabled => _collecting;

  Future<void> setEnabled(bool enabled) async {
    _collecting = enabled;
    await _guard(() => _sink.setEnabled(enabled));
  }

  /// Sends [event] when the parent allows it. Never throws.
  void track(AnalyticsEvent event, [Map<String, Object?> parameters = const <String, Object?>{}]) {
    if (!_collecting) {
      return;
    }
    unawaited(_guard(() => _sink.event(event.wire, AnalyticsPrivacy.cleanParameters(event, parameters))));
  }

  /// A screen from the router (route pattern, never the real path).
  void screen(String fullPath) {
    final String name = AnalyticsPrivacy.screenName(fullPath);
    if (!_collecting || name == _lastScreen) {
      return;
    }
    _lastScreen = name;
    unawaited(_guard(() => _sink.screen(name)));
  }

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (error) {
      debugPrint('analytics: ${error.runtimeType}');
    }
  }
}

/// Overridden in bootstrap.dart with [FirebaseAnalyticsSink] on the phone.
final Provider<AnalyticsSink> analyticsSinkProvider = Provider<AnalyticsSink>((Ref ref) => const NoAnalyticsSink());

/// The parent's choice on this phone. Off until the parent said yes.
abstract final class AnalyticsConsent {
  static const String storageKey = 'analytics.enabled';

  /// True only after an explicit yes.
  static bool read(SettingsStore store) => store.read(storageKey) == 'true';

  /// The parent answered (yes or no): the Home card is not shown again.
  static bool answered(SettingsStore store) => store.read(storageKey) != null;
}

final Provider<Analytics> analyticsProvider = Provider<Analytics>((Ref ref) {
  final bool enabled = AnalyticsConsent.read(ref.watch(settingsStoreProvider));
  final Analytics analytics = Analytics(ref.watch(analyticsSinkProvider), enabled: enabled);
  // Collection follows the saved choice from the first moment.
  unawaited(analytics.setEnabled(enabled));
  return analytics;
});

/// Settings and the privacy screen: switch analytics on or off on this phone.
Future<void> saveAnalyticsChoice(SettingsStore store, Analytics analytics, {required bool enabled}) async {
  await store.write(AnalyticsConsent.storageKey, enabled ? 'true' : 'false');
  await analytics.setEnabled(enabled);
}
