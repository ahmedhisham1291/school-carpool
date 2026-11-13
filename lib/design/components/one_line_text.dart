import 'package:material_ui/material_ui.dart';

/// Text that always stays on one line: no wrapping, and an ellipsis if it is
/// ever too long.
///
/// Every label, button, tab, chip and title uses this (DESIGN rules: one
/// line in Arabic and English at 320 dp width). It is a safety net, not a
/// layout tool: write short wording so the ellipsis never shows.
class OneLineText extends StatelessWidget {
  const OneLineText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.semanticsLabel,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Text(
    data,
    style: style,
    textAlign: textAlign,
    semanticsLabel: semanticsLabel,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
  );
}
