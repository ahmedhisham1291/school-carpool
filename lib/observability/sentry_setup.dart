import 'dart:async';

import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/observability/sentry_scrubber.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Starts Sentry (if this build has a DSN) and then runs the app.
///
/// COST MODE: Sentry free Developer plan. Errors only: no tracing, no
/// profiling, no session replay, no screenshots. The error sample rate comes
/// from the `SENTRY_SAMPLE_RATE` define (1.0 in dev/staging, lower in prod
/// if the monthly error quota gets tight; see docs/COSTS.md).
Future<void> runWithSentry({
  required FlavorConfig config,
  required FutureOr<void> Function() appRunner,
}) async {
  if (!config.sentryEnabled) {
    await appRunner();
    return;
  }
  await SentryFlutter.init((SentryFlutterOptions options) {
    options
      ..dsn = config.sentryDsn
      ..environment = config.flavor.name
      ..sampleRate = config.sentrySampleRate
      // Privacy: nothing that can identify or locate a parent.
      ..sendDefaultPii = false
      ..attachScreenshot = false
      ..attachViewHierarchy = false
      ..enablePrintBreadcrumbs = false
      ..enableUserInteractionBreadcrumbs = false
      // Cost: errors only.
      ..enableUserInteractionTracing = false
      ..enableAutoPerformanceTracing = false
      ..beforeSend = scrubSentryEvent
      ..beforeBreadcrumb = scrubBreadcrumbHook;
    options.replay
      ..sessionSampleRate = 0
      ..onErrorSampleRate = 0;
  }, appRunner: appRunner);
}

/// Dev-only "send test error" button.
Future<bool> sendTestError(FlavorConfig config) async {
  if (!config.sentryEnabled) {
    return false;
  }
  try {
    throw StateError('Sentry test error from the ${config.flavor.name} app (Prompt 1)');
  } on StateError catch (error, stackTrace) {
    await Sentry.captureException(error, stackTrace: stackTrace);
  }
  return true;
}
