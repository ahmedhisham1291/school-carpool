import 'package:school_carpool/observability/pii_scrubber.dart';
import 'package:school_carpool/observability/sentry_area.dart';
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
    // Prompt 12 (Prompt 1 item 11): the mechanism's data and description
    // can carry values from the failing call.
    final Mechanism? mechanism = exception.mechanism;
    if (mechanism != null) {
      exception.mechanism = scrubMechanism(mechanism);
    }
  }

  // Prompt 12: contexts set by the app or a plugin (anything that is not
  // one of Sentry's own typed contexts) are cleaned like extra data. The
  // device name is never collected (sendDefaultPii is off).
  final Contexts contexts = event.contexts;
  for (final String key in contexts.keys.toList()) {
    if (!_sentryContextKeys.contains(key)) {
      contexts[key] = PiiScrubber.scrubValue(contexts[key]);
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

  // Prompt 12: the feature area for the owner's alert rules (a fixed word).
  event.tags = PiiScrubber.scrubStringMap(<String, String>{...?event.tags, 'area': SentryArea.current});

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

/// Sentry's own typed contexts: device model, OS, app version and the like.
const Set<String> _sentryContextKeys = <String>{
  'device', 'os', 'app', 'browser', 'runtime', 'gpu', 'culture', 'trace', 'response', 'feedback', 'flutter',
};

/// The mechanism, rebuilt only when its data or description held something
/// personal (otherwise the original is kept as it is).
Mechanism scrubMechanism(Mechanism mechanism) {
  final Map<String, dynamic> data = mechanism.data;
  final Map<String, dynamic> cleanData = PiiScrubber.scrubMap(data);
  final String? description = mechanism.description;
  final String? cleanDescription = description == null ? null : PiiScrubber.scrubString(description);
  final bool dataChanged = !_sameJson(data, cleanData);
  if (!dataChanged && description == cleanDescription) {
    return mechanism;
  }
  return Mechanism(
    type: mechanism.type,
    description: cleanDescription,
    handled: mechanism.handled,
    synthetic: mechanism.synthetic,
    data: cleanData,
  );
}

bool _sameJson(Map<String, dynamic> a, Map<String, dynamic> b) => a.toString() == b.toString();

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
