import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/features/notifications/notifications_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Scaffold with the five bottom tabs (spec section 10). Each tab keeps its
/// own navigation stack.
///
/// Tab labels are one short word in each language and never wrap
/// (AppNavigationBar enforces it; docs/DESIGN.md has the wording rules).
///
/// Prompt 8: the Alerts tab has a dot while something is unread, and an
/// unopened critical alert is pinned above the tabs (spec section 11).
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  void _onSelect(int index) {
    // Tapping the current tab again returns to the tab's first screen.
    navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);
  }

  /// The five tabs, in spec order. Shared with tests and the gallery.
  static List<AppNavDestination> destinations(AppLocalizations l10n, {int unread = 0}) => <AppNavDestination>[
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
      badgeLabel: unread > 0 ? l10n.notifUnreadCount(unread) : null,
    ),
    AppNavDestination(
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: l10n.tabProfile,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Started by the app root too; watched here so the tab shell always has
    // it, and taps on pushes navigate with this shell's router.
    ref.watch(notificationCenterProvider).router = GoRouter.of(context);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CriticalAlertBanner(),
          AppNavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _onSelect,
            destinations: destinations(context.l10n, unread: ref.watch(unreadCountProvider)),
          ),
        ],
      ),
    );
  }
}
