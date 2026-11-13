import 'package:material_ui/material_ui.dart';

/// Text that always stays on one line: no wrapping, ever.
///
/// Every label, button, tab, chip and title uses this (DESIGN rules: one
/// line in Arabic and English at 320 dp width). It is a safety net, not a
/// layout tool: write short wording so it never has to act.
///
/// When the text is still too wide (for example at 200 percent text size):
/// - by default it ends with an ellipsis (list titles, chips, labels);
/// - with [scaleDown] it shrinks to fit instead, so no word is hidden. Use
///   it where every word matters: buttons, app bar and dialog titles.
class OneLineText extends StatelessWidget {
  const OneLineText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.semanticsLabel,
    this.scaleDown = false,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final String? semanticsLabel;
  final bool scaleDown;

  @override
  Widget build(BuildContext context) {
    if (!scaleDown) {
      return Text(
        data,
        style: style,
        textAlign: textAlign,
        semanticsLabel: semanticsLabel,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: textAlign == TextAlign.center
          ? Alignment.center
          : AlignmentDirectional.centerStart,
      child: Text(
        data,
        style: style,
        textAlign: textAlign,
        semanticsLabel: semanticsLabel,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
