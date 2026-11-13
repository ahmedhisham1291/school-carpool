import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/gallery/gallery_screen.dart';
import 'package:school_carpool/features/placeholder/placeholder_tab_screen.dart';
import 'package:school_carpool/features/shell/home_shell.dart';

/// The five bottom tabs from spec section 10, in order.
enum AppTab {
  home('/home'),
  carpools('/carpools'),
  chats('/chats'),
  notifications('/notifications'),
  profile('/profile');

  const AppTab(this.path);

  final String path;
}

abstract final class AppRoutes {
  static const String initial = '/home';

  /// Dev flavor only: the route does not exist in staging and prod builds.
  static const String gallery = '/dev/gallery';
}

/// Builds the app router. The gallery route is added only when
/// [showDevTools] is true (dev flavor).
GoRouter buildAppRouter({required bool showDevTools, String initialLocation = AppRoutes.initial}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
            HomeShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          for (final AppTab tab in AppTab.values)
            StatefulShellBranch(
              routes: <RouteBase>[
                GoRoute(
                  path: tab.path,
                  builder: (BuildContext context, GoRouterState state) =>
                      PlaceholderTabScreen(tab: tab),
                ),
              ],
            ),
        ],
      ),
      if (showDevTools)
        GoRoute(
          path: AppRoutes.gallery,
          builder: (BuildContext context, GoRouterState state) => const GalleryScreen(),
        ),
    ],
  );
}

final Provider<GoRouter> routerProvider = Provider<GoRouter>((Ref ref) {
  final GoRouter router = buildAppRouter(
    showDevTools: ref.watch(flavorConfigProvider).showDevTools,
  );
  ref.onDispose(router.dispose);
  return router;
});
