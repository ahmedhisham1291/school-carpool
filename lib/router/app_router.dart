import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/gallery/gallery_screen.dart';
import 'package:school_carpool/features/onboarding/code_screen.dart';
import 'package:school_carpool/features/onboarding/email_screen.dart';
import 'package:school_carpool/features/onboarding/phone_screen.dart';
import 'package:school_carpool/features/onboarding/starting_screen.dart';
import 'package:school_carpool/features/onboarding/terms_screen.dart';
import 'package:school_carpool/features/onboarding/verify_account_screen.dart';
import 'package:school_carpool/features/onboarding/welcome_screen.dart';
import 'package:school_carpool/features/placeholder/placeholder_tab_screen.dart';
import 'package:school_carpool/features/profile/profile_screen.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/router/session_redirect.dart';

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
///
/// With a [session], every navigation goes through [sessionRedirect]
/// (sign-up steps, Profile-only access until verified). Without one (some
/// widget tests and screenshots) there is no gate.
GoRouter buildAppRouter({
  required bool showDevTools,
  String initialLocation = AppRoutes.initial,
  ValueListenable<SessionState>? session,
}) {
  final ValueListenable<SessionState>? gate = session;
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: gate,
    redirect: gate == null
        ? null
        : (BuildContext context, GoRouterState state) => sessionRedirect(gate.value, state.uri.path),
    routes: <RouteBase>[
      GoRoute(
        path: AuthRoutes.starting,
        builder: (BuildContext context, GoRouterState state) => const StartingScreen(),
      ),
      GoRoute(
        path: AuthRoutes.welcome,
        builder: (BuildContext context, GoRouterState state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: AuthRoutes.phone,
        builder: (BuildContext context, GoRouterState state) => const PhoneScreen(),
      ),
      GoRoute(
        path: AuthRoutes.code,
        builder: (BuildContext context, GoRouterState state) => const CodeScreen(),
      ),
      GoRoute(
        path: AuthRoutes.email,
        builder: (BuildContext context, GoRouterState state) => const EmailScreen(),
      ),
      GoRoute(
        path: AuthRoutes.terms,
        builder: (BuildContext context, GoRouterState state) => const TermsScreen(),
      ),
      GoRoute(
        path: AuthRoutes.verifyAccount,
        builder: (BuildContext context, GoRouterState state) => const VerifyAccountScreen(),
      ),
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
                      tab == AppTab.profile ? const ProfileScreen() : PlaceholderTabScreen(tab: tab),
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
  final ValueNotifier<SessionState> session = ValueNotifier<SessionState>(const SessionLoading());
  ref.listen<SessionState>(
    sessionProvider,
    (SessionState? previous, SessionState next) => session.value = next,
    fireImmediately: true,
  );
  final GoRouter router = buildAppRouter(
    showDevTools: ref.watch(flavorConfigProvider).showDevTools,
    session: session,
  );
  ref.onDispose(() {
    router.dispose();
    session.dispose();
  });
  return router;
});
