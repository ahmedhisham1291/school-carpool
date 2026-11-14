import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

enum AppAmountSize {
  /// The wallet balance and the review screen: the one number that matters.
  large,

  /// History rows.
  regular,
}

/// A money amount on one line (Prompt 11B). [text] is already formatted
/// with its currency ("EGP 1,250.50"); the digits read left to right in
/// Arabic too. [incoming] amounts are in the success color with a plus
/// sign added by the caller; color is never the only signal.
class AppAmount extends StatelessWidget {
  const AppAmount(this.text, {super.key, this.size = AppAmountSize.regular, this.incoming = false, this.muted = false});

  final String text;
  final AppAmountSize size;
  final bool incoming;

  /// Failed transfers: quiet, as nothing moved.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final TextStyle? base = size == AppAmountSize.large ? context.text.headlineSmall : context.text.titleSmall;
    final Color color = muted
        ? context.colors.onSurfaceVariant
        : incoming
        ? context.appColors.success
        : context.colors.onSurface;
    return OneLineText(
      text,
      scaleDown: true,
      style: base?.copyWith(color: color, decoration: muted ? TextDecoration.lineThrough : null),
    );
  }
}
