/// Firestore collection names the app reads (docs/architecture/overview.md).
///
/// One place for the names, so a typo is a compile error and a rename is a
/// one-line change. The values must match firestore.rules and the Cloud
/// Functions stores (functions/test/architecture.test.ts checks every value
/// here against `match /<name>/` in firestore.rules).
///
/// Only repositories (`*_repository.dart`, `session.dart` and the other data
/// classes under lib/features) use these; screens never touch Firestore.
abstract final class Collections {
  // Top-level collections.
  static const String areas = 'areas';
  static const String carpools = 'carpools';
  static const String chatBlocks = 'chatBlocks';
  static const String chatRequests = 'chatRequests';
  static const String chatSettings = 'chatSettings';
  static const String children = 'children';
  static const String config = 'config';
  static const String emergencyContacts = 'emergencyContacts';
  static const String homes = 'homes';
  static const String memberships = 'memberships';
  static const String notificationSettings = 'notificationSettings';
  static const String placeAreas = 'placeAreas';
  static const String placeDistricts = 'placeDistricts';
  static const String schools = 'schools';
  static const String settleUps = 'settleUps';
  static const String trips = 'trips';
  static const String users = 'users';
  static const String vehicles = 'vehicles';

  // Subcollections (the parent collection in the comment).
  /// carpools/{id}/balances
  static const String balances = 'balances';
  /// carpools/{id}/driverConsents
  static const String driverConsents = 'driverConsents';
  /// carpools/{id}/emergencies
  static const String emergencies = 'emergencies';
  /// trips/{id}/eta
  static const String eta = 'eta';
  /// carpools/{id}/exceptions
  static const String exceptions = 'exceptions';
  /// carpools/{id}/members
  static const String members = 'members';
  /// users/{uid}/notifications
  static const String notifications = 'notifications';
  /// carpools/{id}/requests
  static const String requests = 'requests';
  /// carpools/{id}/schedule
  static const String schedule = 'schedule';
}

/// Fixed document ids the app reads.
abstract final class Docs {
  /// config/features: the pilot feature switches.
  static const String features = 'features';
}
