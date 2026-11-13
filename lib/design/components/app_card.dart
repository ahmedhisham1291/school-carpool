import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Rounded card on the lowest surface tone, optionally tappable.
class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    super.key,
    this.onTap,
    this.padding = AppSpacing.cardPadding,
    this.elevation = AppElevation.none,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final AppElevation elevation;

  /// Read by screen readers instead of the card's content, when set.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget body = Padding(padding: padding, child: child);
    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppRadii.card,
        boxShadow: context.appColors.shadow(elevation),
      ),
      child: Card(child: onTap == null ? body : InkWell(onTap: onTap, child: body)),
    );
    if (semanticLabel == null) {
      return card;
    }
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticLabel,
      excludeSemantics: true,
      child: card,
    );
  }
}
