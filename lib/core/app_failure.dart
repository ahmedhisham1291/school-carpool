import 'package:school_carpool/l10n/l10n.dart';

/// What every feature's failure type offers a screen
/// (docs/architecture/overview.md, "Errors").
///
/// Each feature keeps its own `XFailure` with its own `XFailureKind` enum,
/// built by `XFailure.from(error)` from the callable's `details.reason`
/// (functions/src/common/callable.ts). Screens that only need to show the
/// error or decide on the offline state can take any [AppFailure].
abstract interface class AppFailure implements Exception {
  /// True when the call failed because there is no connection.
  bool get isOffline;

  /// One short sentence that says what happened and how to fix it.
  String message(AppLocalizations l10n);
}
