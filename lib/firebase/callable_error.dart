import 'package:cloud_functions/cloud_functions.dart';

// Reading the answer of a refused callable.
//
// Every Cloud Function answers a known refusal with an HttpsError whose
// `details` is `{ reason, ...extras }` (functions/src/common/callable.ts).
// The feature failure types map [callableReason] to their own kinds.

/// `details.reason` of [error], or null.
String? callableReason(FirebaseFunctionsException error) {
  final Object? reason = callableDetail(error, 'reason');
  return reason is String ? reason : null;
}

/// `details[key]` of [error], or null when the details are not a map.
Object? callableDetail(FirebaseFunctionsException error, String key) {
  final Object? details = error.details;
  return details is Map<Object?, Object?> ? details[key] : null;
}
