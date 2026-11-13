import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';

/// Shows short feedback after an action ("Saved", "Request sent").
///
/// The message stays on one line, so keep it to a few words. Replaces any
/// snackbar that is still showing.
void showAppSnackBar(BuildContext context, String message) =>
    showAppSnackBarOn(ScaffoldMessenger.of(context), message);

/// Same as [showAppSnackBar], for code that looked up the messenger before
/// an `await` (so it does not use a BuildContext across the async gap).
void showAppSnackBarOn(ScaffoldMessengerState messenger, String message) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: OneLineText(message)));
}
