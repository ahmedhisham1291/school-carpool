import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/alert_banner.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// One tab of [AppNavigationBar].
@immutable
class AppNavDestination {
  const AppNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeLabel,
  });

  /// Outlined icon, shown when the tab is not selected.
  final IconData icon;

  /// Filled icon, shown when the tab is selected.
  final IconData selectedIcon;

  /// One short word in each language (DESIGN.md, one-line wording).
  final String label;

  /// When set, a dot on the icon (for example unread alerts) and this text
  /// for screen readers ("3 unread").
  final String? badgeLabel;
}

/// The app's bottom navigation: raised surface with a hairline on top, a
/// soft pill behind the selected icon, outlined and filled icon pairs and
/// quiet labels.
///
/// Labels never wrap. Text scaling is clamped to
/// [AppTypeScale.maxNavTextScale] inside the bar only (body text elsewhere
/// still scales to 200 percent), and a label that is still too wide is
/// scaled down instead of breaking onto a second line.
class AppNavigationBar extends StatelessWidget {
  const AppNavigationBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });

  final List<AppNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: AppTypeScale.maxNavTextScale,
      child: Material(
        color: context.appColors.surfaceRaised,
        shape: Border(top: BorderSide(color: context.colors.outlineVariant)),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSpacing.navBarHeight),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (int i = 0; i < destinations.length; i++)
                  Expanded(
                    child: AppNavigationBarItem(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () => onDestinationSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab button of [AppNavigationBar]. Public so tests can find it.
class AppNavigationBarItem extends StatelessWidget {
  const AppNavigationBarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AppNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final TextStyle base = context.text.labelSmall ?? const TextStyle();
    final TextStyle labelStyle = base.copyWith(
      color: selected ? colors.onSurface : colors.onSurfaceVariant,
      fontWeight: selected ? AppTypeScale.semiBold : AppTypeScale.medium,
    );
    // Every label gets the same one-line box, so all tabs are the same
    // height even when one label is scaled down to fit.
    final double fontSize = labelStyle.fontSize ?? AppSpacing.s16;
    final double labelHeight =
        MediaQuery.textScalerOf(context).scale(fontSize) * (labelStyle.height ?? 1);
    final Duration motion = AppMotion.resolve(context, AppMotion.normal);

    return Semantics(
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: destination.badgeLabel == null ? destination.label : '${destination.label}, ${destination.badgeLabel}',
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.s4,
            vertical: AppSpacing.s8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: AppSpacing.navIndicator.width),
                child: AnimatedContainer(
                  duration: motion,
                  curve: AppMotion.standard,
                  width: double.infinity,
                  height: AppSpacing.navIndicator.height,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primaryContainer
                        : colors.primaryContainer.withValues(alpha: 0),
                    borderRadius: AppRadii.chip,
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: <Widget>[
                      Icon(
                        selected ? destination.selectedIcon : destination.icon,
                        size: AppIconSize.md,
                        color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
                      ),
                      if (destination.badgeLabel != null)
                        const PositionedDirectional(top: 0, end: 0, child: AppUnreadDot()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              SizedBox(
                width: double.infinity,
                height: labelHeight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ExcludeSemantics(
                    child: Text(
                      destination.label,
                      style: labelStyle,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
