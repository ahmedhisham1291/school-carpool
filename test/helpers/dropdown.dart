import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Opens the AppDropdownMenu with [key] and taps the item [label].
Future<void> pickFromDropdown(WidgetTester tester, Key key, String label) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// The text shown in the AppDropdownMenu with [key] (its field).
String dropdownText(WidgetTester tester, Key key) {
  final TextField field = tester.widget<TextField>(find.descendant(of: find.byKey(key), matching: find.byType(TextField)));
  return field.controller?.text ?? '';
}

/// Whether the AppDropdownMenu with [key] can be opened.
bool dropdownEnabled(WidgetTester tester, Key key) {
  final TextField field = tester.widget<TextField>(find.descendant(of: find.byKey(key), matching: find.byType(TextField)));
  return field.enabled ?? true;
}
