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

  /// The verification screen opened because the parent tried [from], a
  /// place that needs a checked account. Its "Later" goes back to the tab
  /// of [from] (laterTarget).
  static String verifyFor(String from) =>
      Uri(path: verifyAccount, queryParameters: <String, String>{'from': from}).toString();

  /// Open to signed-out visitors.
  static const Set<String> signedOut = <String>{welcome, phone, code};

  static const Set<String> onboarding = <String>{starting, welcome, phone, code, email, terms};
}

/// Where the router must send the parent, or null to stay on [location].
///
/// - Loading or failed session: the start screen (loading, error, offline).
/// - Signed out: welcome, phone and code only.
/// - Signed in: email, then terms, until both are done.
/// - Unverified, pending or rejected (owner decision 16 Nov 2026, replaces
///   spec section 3 "Profile only"): the parent may look around (all five
///   tabs, the home address, driving schools, children, settings, privacy,
///   About). Only what involves another family needs the ID check
///   ([needsVerification]): carpools (find, start, join, open), runs and
///   driving, chats, parents nearby, ratings, family links, Settle up and
///   the wallet. Those open the verification screen, which explains why
///   (child safety) and has "Later". The server refuses the same actions
///   ("not-verified"). Document submission is open only while unverified
///   or rejected (not while a review is pending).
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
    if (gate) {
      return AppRoutes.initial;
    }
    // Prompt 12: after a sign-in from a new phone, chats, the wallet and
    // child data wait for the fresh selfie.
    if (account.newDeviceCheck && deviceCheckClosed(location)) {
      return PrivacyRoutes.newDevice;
    }
    return null;
  }
  if (location == AuthRoutes.verifySubmit) {
    final bool canSubmit =
        account.status == AccountStatus.unverified || account.status == AccountStatus.rejected;
    return canSubmit ? null : AuthRoutes.verifyAccount;
  }
  if (location == AuthRoutes.verifyAccount) {
    return null;
  }
  // Right after sign-up: the explanation first (it has "Later").
  if (AuthRoutes.onboarding.contains(location)) {
    return AuthRoutes.verifyAccount;
  }
  return needsVerification(location) ? AuthRoutes.verifyFor(location) : null;
}

/// Profile pages that involve another parent (and that the server refuses
/// before verification): handover adults and the emergency contact are for
/// runs, ratings, family links, the yearly check and phone change are
/// trust features, Settle up and the wallet are between parents.
const Set<String> _profileNeedsVerification = <String>{
  ProfileRoutes.handover,
  ProfileRoutes.emergencyContact,
  ProfileRoutes.ratings,
  ProfileRoutes.family,
  ProfileRoutes.schoolYear,
  ProfileRoutes.phone,
  ProfileRoutes.wallet,
  SettleUpRoutes.home,
};

/// True when [location] needs a verified account (owner decision 16 Nov
/// 2026): carpools and runs, chats, parents nearby, and the Profile pages
/// that reach another parent. The five tab roots, the rest of Profile and
/// invite links (their screen explains) stay open. An unknown place needs
/// verification (closed by default).
bool needsVerification(String location) {
  for (final AppTab tab in AppTab.values) {
    if (location == tab.path) {
      return false;
    }
  }
  if (location.startsWith('/c/') || location.startsWith('/carpools/invite/')) {
    return false;
  }
  if (location.startsWith('${AppTab.profile.path}/')) {
    for (final String gated in _profileNeedsVerification) {
      if (location == gated || location.startsWith('$gated/')) {
        return true;
      }
    }
    return false;
  }
  return true;
}

/// Where "Later" on the verification screen goes: the tab of [from] (the
/// place that asked for verification), or Home.
String laterTarget(String? from) {
  if (from != null) {
    for (final AppTab tab in AppTab.values) {
      if (from == tab.path || from.startsWith('${tab.path}/')) {
        return tab.path;
      }
    }
  }
  return AppRoutes.initial;
}

/// Prompt 12: until the new-phone selfie matched, only the profile page
/// (with its settings and the selfie banner), the selfie screen and About
/// stay open. Everything else reads child, carpool, schedule, trip,
/// location, chat or wallet data, which the server refuses meanwhile
/// (firestore.rules deviceChecked, the gated callables).
bool deviceCheckClosed(String location) => !<String>{
  AppTab.profile.path,
  PrivacyRoutes.newDevice,
  ProfileRoutes.about,
}.contains(location);
