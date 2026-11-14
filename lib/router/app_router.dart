import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/about/about_screen.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_detail_screen.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_search_screen.dart';
import 'package:school_carpool/features/carpools/carpools_screen.dart';
import 'package:school_carpool/features/carpools/create_carpool_screen.dart';
import 'package:school_carpool/features/carpools/invite_screen.dart';
import 'package:school_carpool/features/carpools/looking_screen.dart';
import 'package:school_carpool/features/gallery/gallery_screen.dart';
import 'package:school_carpool/features/home/home_screen.dart';
import 'package:school_carpool/features/maps/driving_schools_screen.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/nearby_parents_screen.dart';
import 'package:school_carpool/features/notifications/notification_settings_screen.dart';
import 'package:school_carpool/features/notifications/notifications_screen.dart';
import 'package:school_carpool/features/onboarding/code_screen.dart';
import 'package:school_carpool/features/onboarding/email_screen.dart';
import 'package:school_carpool/features/onboarding/phone_screen.dart';
import 'package:school_carpool/features/onboarding/starting_screen.dart';
import 'package:school_carpool/features/onboarding/terms_screen.dart';
import 'package:school_carpool/features/onboarding/verify_account_screen.dart';
import 'package:school_carpool/features/onboarding/welcome_screen.dart';
import 'package:school_carpool/features/placeholder/placeholder_tab_screen.dart';
import 'package:school_carpool/features/profile/profile_screen.dart';
import 'package:school_carpool/features/schedule/balance_screen.dart';
import 'package:school_carpool/features/schedule/exceptions_screen.dart';
import 'package:school_carpool/features/schedule/schedule_screen.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/features/trips/driver_trip_screen.dart';
import 'package:school_carpool/features/trips/emergency_screens.dart';
import 'package:school_carpool/features/trips/handover_screen.dart';
import 'package:school_carpool/features/trips/trip_screen.dart';
import 'package:school_carpool/features/verification/children_screen.dart';
import 'package:school_carpool/features/verification/driving_screen.dart';
import 'package:school_carpool/features/verification/verification_flow_screen.dart';
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

/// Screens under the Profile tab (Prompt 3).
abstract final class ProfileRoutes {
  static const String childrenSegment = 'children';
  static const String drivingSegment = 'driving';
  static const String aboutSegment = 'about';
  static const String homeLocationSegment = 'home-location';
  static const String drivingSchoolsSegment = 'driving-schools';
  static const String notificationsSegment = 'notifications';
  static const String children = '/profile/$childrenSegment';
  static const String homeLocation = '/profile/$homeLocationSegment';
  static const String drivingSchools = '/profile/$drivingSchoolsSegment';
  static const String driving = '/profile/$drivingSegment';
  static const String about = '/profile/$aboutSegment';

  /// Prompt 8: alert settings (WhatsApp per group, quiet hours).
  static const String notifications = '/profile/$notificationsSegment';

  /// Prompt 10: who may receive each child (F29) and the emergency contact (F20).
  static const String handoverSegment = 'handover';
  static const String emergencyContactSegment = 'emergency-contact';
  static const String handover = '/profile/$handoverSegment';
  static const String emergencyContact = '/profile/$emergencyContactSegment';
}

/// Screens under the Home tab (Prompt 5). Verified parents only (the
/// session redirect keeps everyone else on Profile).
abstract final class HomeRoutes {
  static const String nearbySegment = 'nearby';
  static const String nearby = '/home/$nearbySegment';
}

/// Screens under the Carpools tab (Prompt 6) and invite links. Verified
/// parents only, except the invite link, which explains that the parent
/// must be verified first (F31).
abstract final class CarpoolRoutes {
  static const String searchSegment = 'search';
  static const String createSegment = 'new';
  static const String lookingSegment = 'looking';
  static const String search = '/carpools/$searchSegment';
  static const String create = '/carpools/$createSegment';
  static const String looking = '/carpools/$lookingSegment';

  /// Invite links: `https://<links site>/c/<code>` (universal links on
  /// iPhone). The router sends them to [invite], inside the Carpools tab,
  /// so opening the carpool afterwards stays in the same tab shell.
  static const String linkPattern = '/c/:code';
  static const String inviteSegment = 'invite/:code';

  static String detail(String carpoolId) => '/carpools/$carpoolId';

  /// Prompt 7: the week plan, days off and times, and the drive balance.
  static const String scheduleSegment = 'schedule';
  static const String exceptionsSegment = 'exceptions';
  static const String balanceSegment = 'balance';
  static String schedule(String carpoolId) => '/carpools/$carpoolId/$scheduleSegment';
  static String exceptions(String carpoolId) => '/carpools/$carpoolId/$exceptionsSegment';
  static String balance(String carpoolId) => '/carpools/$carpoolId/$balanceSegment';

  /// Prompt 10: the live run for parents, the driver's run, emergencies.
  static const String tripSegment = 'trip/:runId';
  static const String driveSegment = 'drive';
  static const String emergencySegment = 'emergency';
  static String trip(String carpoolId, String runId) => '/carpools/$carpoolId/trip/$runId';
  static String drive(String carpoolId, String runId) => '/carpools/$carpoolId/trip/$runId/$driveSegment';
  static String emergency(String carpoolId) => '/carpools/$carpoolId/$emergencySegment';

  /// The shared link path.
  static String link(String code) => '/c/$code';

  /// The invite screen inside the Carpools tab.
  static String invite(String code) => '/carpools/invite/$code';

  /// The nearby map's Join (F22): that parent's carpools at one school.
  static String searchParent({required String schoolId, required String parentUid, required String parentName}) => Uri(
    path: search,
    queryParameters: <String, String>{'school': schoolId, 'parent': parentUid, 'name': parentName},
  ).toString();

  /// Start a carpool with a "looking for a carpool" match filled in (F32).
  static String createFrom({
    required String schoolId,
    String? areaId,
    String? morning,
    String? afternoon,
    List<Weekday> days = const <Weekday>[],
  }) => Uri(
    path: create,
    queryParameters: <String, String>{
      'school': schoolId,
      'area': ?areaId,
      'morning': ?morning,
      'afternoon': ?afternoon,
      if (days.isNotEmpty) 'days': days.map((Weekday d) => d.name).join(','),
    },
  ).toString();
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
///
/// [onInviteLink] gets the code of every invite link the router sees, so a
/// link opened before sign-up or verification is not lost (F31).
GoRouter buildAppRouter({
  required bool showDevTools,
  String initialLocation = AppRoutes.initial,
  ValueListenable<SessionState>? session,
  ValueChanged<String>? onInviteLink,
}) {
  final ValueListenable<SessionState>? gate = session;
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: gate,
    redirect: gate == null
        ? null
        : (BuildContext context, GoRouterState state) {
            final String? code = inviteCodeFromPath(state.uri.path);
            if (code != null) {
              onInviteLink?.call(code);
            }
            return sessionRedirect(gate.value, state.uri.path);
          },
    routes: <RouteBase>[
      GoRoute(
        path: CarpoolRoutes.linkPattern,
        redirect: (BuildContext context, GoRouterState state) =>
            CarpoolRoutes.invite((state.pathParameters['code'] ?? '').toUpperCase()),
      ),
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
      GoRoute(
        path: AuthRoutes.verifySubmit,
        builder: (BuildContext context, GoRouterState state) => const VerificationFlowScreen(),
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
                  builder: (BuildContext context, GoRouterState state) => switch (tab) {
                    AppTab.profile => const ProfileScreen(),
                    AppTab.home => const HomeScreen(),
                    AppTab.carpools => const CarpoolsScreen(),
                    AppTab.notifications => const NotificationsScreen(),
                    AppTab.chats => PlaceholderTabScreen(tab: tab),
                  },
                  routes: <RouteBase>[
                    if (tab == AppTab.home)
                      GoRoute(
                        path: HomeRoutes.nearbySegment,
                        builder: (BuildContext context, GoRouterState state) => const NearbyParentsScreen(),
                      ),
                    if (tab == AppTab.carpools) ...<RouteBase>[
                      GoRoute(
                        path: CarpoolRoutes.searchSegment,
                        builder: (BuildContext context, GoRouterState state) => CarpoolSearchScreen(
                          schoolId: state.uri.queryParameters['school'],
                          parentUid: state.uri.queryParameters['parent'],
                          parentName: state.uri.queryParameters['name'],
                        ),
                      ),
                      GoRoute(
                        path: CarpoolRoutes.createSegment,
                        builder: (BuildContext context, GoRouterState state) {
                          final Map<String, String> q = state.uri.queryParameters;
                          return CreateCarpoolScreen(
                            prefill: CreatePrefill(
                              schoolId: q['school'],
                              areaId: q['area'],
                              morning: q['morning'],
                              afternoon: q['afternoon'],
                              days: Weekday.listFrom(q['days']?.split(',')),
                            ),
                          );
                        },
                      ),
                      GoRoute(
                        path: CarpoolRoutes.lookingSegment,
                        builder: (BuildContext context, GoRouterState state) => const LookingScreen(),
                      ),
                      GoRoute(
                        path: CarpoolRoutes.inviteSegment,
                        builder: (BuildContext context, GoRouterState state) =>
                            InviteScreen(code: (state.pathParameters['code'] ?? '').toUpperCase()),
                      ),
                      GoRoute(
                        path: ':carpoolId',
                        builder: (BuildContext context, GoRouterState state) =>
                            CarpoolDetailScreen(carpoolId: state.pathParameters['carpoolId'] ?? ''),
                        routes: <RouteBase>[
                          GoRoute(
                            path: CarpoolRoutes.scheduleSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                ScheduleScreen(carpoolId: state.pathParameters['carpoolId'] ?? ''),
                          ),
                          GoRoute(
                            path: CarpoolRoutes.exceptionsSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                ExceptionsScreen(carpoolId: state.pathParameters['carpoolId'] ?? ''),
                          ),
                          GoRoute(
                            path: CarpoolRoutes.balanceSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                BalanceScreen(carpoolId: state.pathParameters['carpoolId'] ?? ''),
                          ),
                          GoRoute(
                            path: CarpoolRoutes.tripSegment,
                            builder: (BuildContext context, GoRouterState state) => TripScreen(
                              carpoolId: state.pathParameters['carpoolId'] ?? '',
                              runId: state.pathParameters['runId'] ?? '',
                            ),
                            routes: <RouteBase>[
                              GoRoute(
                                path: CarpoolRoutes.driveSegment,
                                builder: (BuildContext context, GoRouterState state) => DriverTripScreen(
                                  carpoolId: state.pathParameters['carpoolId'] ?? '',
                                  runId: state.pathParameters['runId'] ?? '',
                                ),
                              ),
                            ],
                          ),
                          GoRoute(
                            path: CarpoolRoutes.emergencySegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                EmergencyScreen(carpoolId: state.pathParameters['carpoolId'] ?? ''),
                          ),
                        ],
                      ),
                    ],
                    if (tab == AppTab.profile) ...<RouteBase>[
                      GoRoute(
                        path: ProfileRoutes.childrenSegment,
                        builder: (BuildContext context, GoRouterState state) => const ChildrenScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.drivingSegment,
                        builder: (BuildContext context, GoRouterState state) => const DrivingScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.aboutSegment,
                        builder: (BuildContext context, GoRouterState state) => const AboutScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.homeLocationSegment,
                        builder: (BuildContext context, GoRouterState state) => const HomeLocationScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.drivingSchoolsSegment,
                        builder: (BuildContext context, GoRouterState state) => const DrivingSchoolsScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.notificationsSegment,
                        builder: (BuildContext context, GoRouterState state) => const NotificationSettingsScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.handoverSegment,
                        builder: (BuildContext context, GoRouterState state) => const HandoverChildrenScreen(),
                        routes: <RouteBase>[
                          GoRoute(
                            path: ':childId',
                            builder: (BuildContext context, GoRouterState state) =>
                                HandoverEditScreen(childId: state.pathParameters['childId'] ?? ''),
                          ),
                        ],
                      ),
                      GoRoute(
                        path: ProfileRoutes.emergencyContactSegment,
                        builder: (BuildContext context, GoRouterState state) => const EmergencyContactScreen(),
                      ),
                    ],
                  ],
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
    // Kept on the phone until opened (after sign-up and verification).
    onInviteLink: (String code) => unawaited(Future<void>.microtask(() async {
      if (ref.read(pendingInviteProvider) != code) {
        await ref.read(pendingInviteProvider.notifier).save(code);
      }
    })),
  );
  ref.onDispose(() {
    router.dispose();
    session.dispose();
  });
  return router;
});
