import 'package:school_carpool/observability/pii_scrubber.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// `beforeSend` hook: strips personal data from every event.
///
/// Pure functions with no widget dependencies, so they are easy to unit test.
SentryEvent scrubSentryEvent(SentryEvent event, Hint hint) {
  final SentryMessage? message = event.message;
  if (message != null) {
    message
      ..formatted = PiiScrubber.scrubString(message.formatted)
      ..template = message.template == null ? null : PiiScrubber.scrubString(message.template!)
      ..params = null;
  }

  for (final SentryException exception in event.exceptions ?? const <SentryException>[]) {
    final String? value = exception.value;
    if (value != null) {
      exception.value = PiiScrubber.scrubString(value);
    }
  }

  final List<Breadcrumb>? breadcrumbs = event.breadcrumbs;
  if (breadcrumbs != null) {
    event.breadcrumbs = <Breadcrumb>[
      for (final Breadcrumb crumb in breadcrumbs) scrubBreadcrumb(crumb),
    ];
  }

  // Keep only the opaque account id. Never email, IP, name or location.
  final String? userId = event.user?.id;
  event.user = userId == null ? null : SentryUser(id: userId);

  final Map<String, String>? tags = event.tags;
  if (tags != null) {
    event.tags = PiiScrubber.scrubStringMap(tags);
  }

  // ignore: deprecated_member_use
  final Map<String, dynamic>? extra = event.extra;
  if (extra != null) {
    // ignore: deprecated_member_use
    event.extra = PiiScrubber.scrubMap(extra);
  }

  final String? transaction = event.transaction;
  if (transaction != null) {
    event.transaction = PiiScrubber.scrubString(transaction);
  }

  event
    ..request = null
    ..serverName = null
    ..culprit = event.culprit == null ? null : PiiScrubber.scrubString(event.culprit!);

  return event;
}

/// Cleans one breadcrumb (also used as `beforeBreadcrumb`).
Breadcrumb scrubBreadcrumb(Breadcrumb crumb) {
  final String? message = crumb.message;
  if (message != null) {
    crumb.message = PiiScrubber.scrubString(message);
  }
  final Map<String, dynamic>? data = crumb.data;
  if (data != null) {
    crumb.data = PiiScrubber.scrubMap(data);
  }
  return crumb;
}

/// `beforeBreadcrumb` signature adapter.
Breadcrumb? scrubBreadcrumbHook(Breadcrumb? crumb, Hint hint) =>
    crumb == null ? null : scrubBreadcrumb(crumb);
