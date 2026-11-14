import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/router/app_router.dart';

/// Routes of sign-up and the account gate (spec section 10, "Onboarding
/// and registration", screens 1 to 4 and 9).
abstract final class AuthRoutes {
  static const String starting = '/starting';
  static const String welcome = '/welcome';
  static const String phone = '/signup/phone';
  static const String code = '/signup/code';
  static const String email = '/signup/email';
  static const String terms = '/signup/terms';
  static const String verifyAccount = '/verify-account';

  /// Document capture and submission (Prompt 3). Only while unverified or
  /// rejected.
  static const String verifySubmit = '/verify-account/submit';

  /// Open to signed-out visitors.
  static const Set<String> signedOut = <String>{welcome, phone, code};

  static const Set<String> onboarding = <String>{starting, welcome, phone, code, email, terms};
}

/// Where the router must send the parent, or null to stay on [location].
///
/// - Loading or failed session: the start screen (loading, error, offline).
/// - Signed out: welcome, phone and code only.
/// - Signed in: email, then terms, until both are done.
/// - Unverified, pending or rejected: the verification screen and Profile
///   only (spec section 3, "Profile only"). Document submission is open
///   only while unverified or rejected (not while a review is pending).
/// - Suspended: the verification screen only (it explains the suspension).
/// - Verified: the full app.
///
/// The dev gallery is always reachable (the route exists only in dev).
String? sessionRedirect(SessionState session, String location) {
  if (location == AppRoutes.gallery) {
    return null;
  }
  final String? target = switch (session) {
    SessionLoading() || SessionFailed() => AuthRoutes.starting,
    SessionSignedOut() => AuthRoutes.signedOut.contains(location) ? null : AuthRoutes.welcome,
    SessionSignedIn(:final Account? account) =>
      account == null ? AuthRoutes.starting : _signedInTarget(account, location),
  };
  return target == location ? null : target;
}

String? _signedInTarget(Account account, String location) {
  if (account.status == AccountStatus.suspended) {
    return AuthRoutes.verifyAccount;
  }
  switch (account.stage) {
    case RegistrationStage.email:
      return AuthRoutes.email;
    case RegistrationStage.terms:
      return AuthRoutes.terms;
    case RegistrationStage.complete:
      break;
  }
  // Invite links (F31): the screen itself says to verify first, and keeps
  // the code until then.
  if (location.startsWith('/c/') || location.startsWith('/carpools/invite/')) {
    return null;
  }
  if (account.status == AccountStatus.verified) {
    final bool gate =
        AuthRoutes.onboarding.contains(location) ||
        location == AuthRoutes.verifyAccount ||
        location == AuthRoutes.verifySubmit;
    return gate ? AppRoutes.initial : null;
  }
  if (location == AuthRoutes.verifySubmit) {
    final bool canSubmit =
        account.status == AccountStatus.unverified || account.status == AccountStatus.rejected;
    return canSubmit ? null : AuthRoutes.verifyAccount;
  }
  // Prompt 8: the Notifications tab too, where the verification result is.
  final bool allowed =
      location == AuthRoutes.verifyAccount ||
      location == AppTab.notifications.path ||
      location == AppTab.profile.path ||
      location.startsWith('${AppTab.profile.path}/');
  return allowed ? null : AuthRoutes.verifyAccount;
}
