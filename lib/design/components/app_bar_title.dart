import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';

/// The title of every app bar: one line, announced as a header, and scaled
/// down (never cut off) when large text makes it too wide.
///
/// Use `AppBar(title: AppBarTitle(l10n.something))`; the style comes from
/// the theme's `appBarTheme.titleTextStyle`. Keep titles to one to three
/// words ("Profile", "Swap a day").
class AppBarTitle extends StatelessWidget {
  const AppBarTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: OneLineText(title, scaleDown: true));
}
