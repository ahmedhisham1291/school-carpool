import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Scaffold with the five bottom tabs (spec section 10). Each tab keeps its
/// own navigation stack.
///
/// Tab labels are one short word in each language and never wrap
/// (AppNavigationBar enforces it; docs/DESIGN.md has the wording rules).
class HomeShell extends StatelessWidget {
  const HomeShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  void _onSelect(int index) {
    // Tapping the current tab again returns to the tab's first screen.
    navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);
  }

  /// The five tabs, in spec order. Shared with tests and the gallery.
  static List<AppNavDestination> destinations(AppLocalizations l10n) => <AppNavDestination>[
    AppNavDestination(
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      label: l10n.tabHome,
    ),
    AppNavDestination(
      icon: Icons.directions_car_outlined,
      selectedIcon: Icons.directions_car_rounded,
      label: l10n.tabCarpools,
    ),
    AppNavDestination(
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
      label: l10n.tabChats,
    ),
    AppNavDestination(
      icon: Icons.notifications_none_rounded,
      selectedIcon: Icons.notifications_rounded,
      label: l10n.tabNotifications,
    ),
    AppNavDestination(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: l10n.tabProfile,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: AppNavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _onSelect,
        destinations: destinations(context.l10n),
      ),
    );
  }
}
