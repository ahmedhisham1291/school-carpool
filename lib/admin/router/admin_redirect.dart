import 'package:school_carpool/admin/auth/admin_session.dart';

/// Routes of the admin panel (F14).
abstract final class AdminRoutes {
  static const String starting = '/starting';
  static const String signIn = '/sign-in';
  static const String twoStepSetup = '/two-step-setup';

  static const String queue = '/queue';
  static const String users = '/users';
  static const String schools = '/schools';
  static const String newSchool = '/schools/new';
  static const String otherSchools = '/other-schools';
  static const String reports = '/reports';
  static const String audit = '/audit';
  static const String admins = '/admins';

  /// Prompt 11B: the wallet log, alerts and one parent's wallet.
  static const String wallets = '/wallets';

  /// Prompt 11: guardian links to review and rating flags.
  static const String trust = '/trust';

  /// Dev flavor only: the admin components gallery.
  static const String gallery = '/dev/admin-gallery';

  static const String home = queue;

  static String caseDetail(String caseId) => '$queue/$caseId';
  static String user(String uid) => '$users/$uid';
  static String school(String id) => '$schools/$id';
  static String otherSchool(String id) => '$otherSchools/$id';
  static String wallet(String uid) => '$wallets/$uid';

  /// Screens shown without a signed-in admin.
  static const Set<String> outside = <String>{starting, signIn, twoStepSetup};
}

/// Where the panel's router must go, or null to stay on [location].
///
/// - Loading: the start screen.
/// - Signed out or not an admin (a parent): the sign-in screen only. A
///   parent never reaches any panel screen; the functions refuse them too.
/// - Admin without a second factor: adding the authenticator app only.
/// - Admin signed in with two steps: the panel; the Admins page only for
///   super admins.
String? adminRedirect(AdminSessionState session, String location) {
  if (location == AdminRoutes.gallery) {
    return null;
  }
  final String? target = switch (session) {
    AdminSessionLoading() => AdminRoutes.starting,
    AdminSignedOut() || AdminNotAllowed() => AdminRoutes.signIn,
    AdminNeedsSecondFactor() => AdminRoutes.twoStepSetup,
    AdminSignedIn(:final user) =>
      AdminRoutes.outside.contains(location) || location == '/'
          ? AdminRoutes.home
          : (location.startsWith(AdminRoutes.admins) && !user.isSuperAdmin ? AdminRoutes.home : null),
  };
  return target == location ? null : target;
}
