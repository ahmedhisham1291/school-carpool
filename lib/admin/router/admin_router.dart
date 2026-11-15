import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/admin_gallery_screen.dart';
import 'package:school_carpool/admin/screens/admins_screen.dart';
import 'package:school_carpool/admin/screens/audit_screen.dart';
import 'package:school_carpool/admin/screens/case_screen.dart';
import 'package:school_carpool/admin/screens/other_schools_screen.dart';
import 'package:school_carpool/admin/screens/places_screen.dart';
import 'package:school_carpool/admin/screens/queue_screen.dart';
import 'package:school_carpool/admin/screens/report_screen.dart';
import 'package:school_carpool/admin/screens/reports_screen.dart';
import 'package:school_carpool/admin/screens/school_screen.dart';
import 'package:school_carpool/admin/screens/schools_screen.dart';
import 'package:school_carpool/admin/screens/settings_screen.dart';
import 'package:school_carpool/admin/screens/sign_in_screen.dart';
import 'package:school_carpool/admin/screens/trust_screen.dart';
import 'package:school_carpool/admin/screens/two_step_setup_screen.dart';
import 'package:school_carpool/admin/screens/user_screen.dart';
import 'package:school_carpool/admin/screens/users_screen.dart';
import 'package:school_carpool/admin/screens/wallet_screens.dart';
import 'package:school_carpool/admin/shell/admin_shell.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';

GoRoute _page(String path, Widget Function(GoRouterState state) build) =>
    GoRoute(path: path, builder: (BuildContext context, GoRouterState state) => build(state));

/// The admin panel's router (F14). With a [session], every navigation goes
/// through [adminRedirect]; without one (some widget tests) there is no gate.
GoRouter buildAdminRouter({
  required bool showDevTools,
  String initialLocation = AdminRoutes.home,
  ValueListenable<AdminSessionState>? session,
}) {
  final ValueListenable<AdminSessionState>? gate = session;
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: gate,
    redirect: gate == null
        ? null
        : (BuildContext context, GoRouterState state) => adminRedirect(gate.value, state.uri.path),
    routes: <RouteBase>[
      _page(AdminRoutes.starting, (_) => const Scaffold(body: AdminSkeletonPage())),
      _page(AdminRoutes.signIn, (_) => const AdminSignInScreen()),
      _page(AdminRoutes.twoStepSetup, (_) => const TwoStepSetupScreen()),
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AdminShell(location: state.uri.path, child: child),
        routes: <RouteBase>[
          GoRoute(
            path: AdminRoutes.queue,
            builder: (BuildContext context, GoRouterState state) => const QueueScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':caseId',
                builder: (BuildContext context, GoRouterState state) =>
                    CaseScreen(caseId: state.pathParameters['caseId'] ?? ''),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.users,
            builder: (BuildContext context, GoRouterState state) => const UsersScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':uid',
                builder: (BuildContext context, GoRouterState state) =>
                    UserScreen(uid: state.pathParameters['uid'] ?? ''),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.schools,
            builder: (BuildContext context, GoRouterState state) => const SchoolsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: 'new',
                builder: (BuildContext context, GoRouterState state) => const SchoolScreen(),
              ),
              GoRoute(
                path: ':id',
                builder: (BuildContext context, GoRouterState state) =>
                    SchoolScreen(schoolId: state.pathParameters['id']),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.otherSchools,
            builder: (BuildContext context, GoRouterState state) => const OtherSchoolsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':id',
                builder: (BuildContext context, GoRouterState state) =>
                    SchoolScreen(schoolId: state.pathParameters['id'], reviewing: true),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.reports,
            builder: (BuildContext context, GoRouterState state) => const ReportsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':id',
                builder: (BuildContext context, GoRouterState state) => ReportScreen(reportId: state.pathParameters['id'] ?? ''),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.wallets,
            builder: (BuildContext context, GoRouterState state) => const AdminWalletsScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':uid',
                builder: (BuildContext context, GoRouterState state) => AdminWalletScreen(uid: state.pathParameters['uid'] ?? ''),
              ),
            ],
          ),
          GoRoute(
            path: AdminRoutes.places,
            builder: (BuildContext context, GoRouterState state) => const PlacesScreen(),
          ),
          GoRoute(
            path: AdminRoutes.trust,
            builder: (BuildContext context, GoRouterState state) => const AdminTrustScreen(),
          ),
          GoRoute(
            path: AdminRoutes.settings,
            builder: (BuildContext context, GoRouterState state) => const AdminSettingsScreen(),
          ),
          GoRoute(
            path: AdminRoutes.audit,
            builder: (BuildContext context, GoRouterState state) => const AuditScreen(),
          ),
          GoRoute(
            path: AdminRoutes.admins,
            builder: (BuildContext context, GoRouterState state) => const AdminsScreen(),
          ),
        ],
      ),
      if (showDevTools) _page(AdminRoutes.gallery, (_) => const AdminGalleryScreen()),
    ],
  );
}

/// Full-page skeleton while the session loads.
class AdminSkeletonPage extends StatelessWidget {
  const AdminSkeletonPage({super.key});

  @override
  Widget build(BuildContext context) => const SafeArea(
    child: Skeleton(child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow()])),
  );
}

final Provider<GoRouter> adminRouterProvider = Provider<GoRouter>((Ref ref) {
  final ValueNotifier<AdminSessionState> session = ValueNotifier<AdminSessionState>(const AdminSessionLoading());
  ref.listen<AdminSessionState>(
    adminSessionProvider,
    (AdminSessionState? previous, AdminSessionState next) => session.value = next,
    fireImmediately: true,
  );
  final GoRouter router = buildAdminRouter(
    showDevTools: ref.watch(flavorConfigProvider).showDevTools,
    session: session,
  );
  ref.onDispose(() {
    router.dispose();
    session.dispose();
  });
  return router;
});
