/// Prompt 12: the feature area of the screen the parent is on, as a Sentry
/// tag ("area"), so the owner gets an alert on NEW errors in sign-in,
/// trips and the wallet (alert rules, SETUP.md 23.6). Set by the router's
/// screen tracking from the route PATTERN (never an ID).
abstract final class SentryArea {
  static String current = 'other';

  static String ofPath(String fullPath) {
    if (fullPath.startsWith('/signup') || fullPath.startsWith('/welcome') || fullPath.startsWith('/starting')) {
      return 'signin';
    }
    if (fullPath.contains('/trip') || fullPath.contains('/emergency')) {
      return 'trips';
    }
    if (fullPath.startsWith('/profile/wallet')) {
      return 'wallet';
    }
    if (fullPath.startsWith('/profile/privacy')) {
      return 'privacy';
    }
    return 'other';
  }
}
