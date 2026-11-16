import 'package:cloud_functions/cloud_functions.dart';
import 'package:school_carpool/firebase/callable_error.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Why the server refused an App Review demo parent
/// (functions/src/privacy/device_gate.ts):
/// - [account]: inside the review window, the action reaches real parents
///   or leaves the demo school and carpool ("demo-account");
/// - [closed]: the review window is over ("demo-closed").
enum DemoRefusal { account, closed }

/// The demo refusal in [error] (a callable's `details.reason`), or null.
DemoRefusal? demoRefusalOf(Object? error) {
  if (error is! FirebaseFunctionsException) {
    return null;
  }
  return switch (callableReason(error) ?? error.message) {
    'demo-account' => DemoRefusal.account,
    'demo-closed' => DemoRefusal.closed,
    _ => null,
  };
}

/// A friendly sentence instead of the generic error ("This demo account
/// can't do that"), or null when [demo] is null. Every failure type's
/// `message` asks this first, so each screen shows it without its own code.
String? demoRefusalText(AppLocalizations l10n, DemoRefusal? demo) => switch (demo) {
  DemoRefusal.account => l10n.demoAccountRefused,
  DemoRefusal.closed => l10n.demoAccountClosed,
  null => null,
};
