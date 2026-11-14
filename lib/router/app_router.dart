import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/about/about_screen.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_detail_screen.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_search_screen.dart';
import 'package:school_carpool/features/carpools/carpools_screen.dart';
import 'package:school_carpool/features/carpools/create_carpool_screen.dart';
import 'package:school_carpool/features/carpools/invite_screen.dart';
import 'package:school_carpool/features/carpools/looking_screen.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chats_screen.dart';
import 'package:school_carpool/features/chat/conversation_screen.dart';
import 'package:school_carpool/features/feature_switches/feature_gate.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
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
import 'package:school_carpool/features/privacy/delete_account_screen.dart';
import 'package:school_carpool/features/privacy/devices_screen.dart';
import 'package:school_carpool/features/privacy/new_device_screen.dart';
import 'package:school_carpool/features/privacy/privacy_screen.dart';
import 'package:school_carpool/features/profile/profile_screen.dart';
import 'package:school_carpool/features/schedule/balance_screen.dart';
import 'package:school_carpool/features/schedule/exceptions_screen.dart';
import 'package:school_carpool/features/schedule/schedule_screen.dart';
import 'package:school_carpool/features/settle_up/instapay_address_screen.dart';
import 'package:school_carpool/features/settle_up/new_settle_up_screen.dart';
import 'package:school_carpool/features/settle_up/settle_up_detail_screen.dart';
import 'package:school_carpool/features/settle_up/settle_up_screen.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/features/trips/driver_trip_screen.dart';
import 'package:school_carpool/features/trips/emergency_screens.dart';
import 'package:school_carpool/features/trips/handover_screen.dart';
import 'package:school_carpool/features/trips/trip_screen.dart';
import 'package:school_carpool/features/trust/family_screen.dart';
import 'package:school_carpool/features/trust/phone_change_screen.dart';
import 'package:school_carpool/features/trust/rate_screen.dart';
import 'package:school_carpool/features/trust/school_year_screen.dart';
import 'package:school_carpool/features/verification/children_screen.dart';
import 'package:school_carpool/features/verification/driving_screen.dart';
import 'package:school_carpool/features/verification/verification_flow_screen.dart';
import 'package:school_carpool/features/wallet/money_screens.dart';
import 'package:school_carpool/features/wallet/send_screen.dart';
import 'package:school_carpool/features/wallet/transfer_screen.dart';
import 'package:school_carpool/features/wallet/wallet_screen.dart';
import 'package:school_carpool/observability/sentry_area.dart';
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

  /// Prompt 11B: the wallet (F43).
  static const String walletSegment = 'wallet';
  static const String wallet = '/profile/$walletSegment';

  /// Prompt 11 (F17): ratings, family links, the yearly check, phone change.
  static const String ratingsSegment = 'ratings';
  static const String familySegment = 'family';
  static const String schoolYearSegment = 'school-year';
  static const String phoneSegment = 'phone';
  static const String ratings = '/profile/$ratingsSegment';
  static const String family = '/profile/$familySegment';
  static const String schoolYear = '/profile/$schoolYearSegment';
  static const String phone = '/profile/$phoneSegment';
}

/// Prompt 12: privacy screens under Profile > Privacy.
abstract final class PrivacyRoutes {
  static const String segment = 'privacy';
  static const String devicesSegment = 'devices';
  static const String deleteSegment = 'delete';
  static const String newDeviceSegment = 'new-device';
  static const String privacy = '/profile/$segment';
  static const String devices = '$privacy/$devicesSegment';
  static const String delete = '$privacy/$deleteSegment';

  /// The fresh selfie after a sign-in from a new phone.
  static const String newDevice = '$privacy/$newDeviceSegment';
}

/// Wallet screens under Profile > Wallet (Prompt 11B). Verified parents
/// use them; the functions refuse everyone else.
abstract final class WalletRoutes {
  static const String sendSegment = 'send';
  static const String addSegment = 'add';
  static const String withdrawSegment = 'withdraw';
  static const String transferSegment = 't/:id';
  static const String add = '${ProfileRoutes.wallet}/$addSegment';
  static const String withdraw = '${ProfileRoutes.wallet}/$withdrawSegment';

  static String transfer(String id) => '${ProfileRoutes.wallet}/t/$id';

  /// Send money; from a carpool's "Pay contribution" with the carpool and
  /// the agreed amount (piastres) filled in (F25). Nothing is sent until the
  /// parent confirms.
  static String send({String? carpoolId, int? amount}) => Uri(
    path: '${ProfileRoutes.wallet}/$sendSegment',
    queryParameters: carpoolId == null && amount == null
        ? null
        : <String, String>{'carpool': ?carpoolId, if (amount != null) 'amount': '$amount'},
  ).toString();
}

/// Settle up by InstaPay (F45) under Profile > Settle up, also opened from
/// a carpool's page. Shown only while the "settleUp" feature switch is on.
abstract final class SettleUpRoutes {
  static const String segment = 'settle-up';
  static const String newSegment = 'new';
  static const String addressSegment = 'address';
  static const String recordSegment = 'r/:id';
  static const String home = '/profile/$segment';
  static const String address = '$home/$addressSegment';

  /// The list, opened from a carpool: a new request starts with its parents.
  static String homeFor(String carpoolId) => Uri(path: home, queryParameters: <String, String>{'carpool': carpoolId}).toString();

  static String create({String? carpoolId}) => Uri(
    path: '$home/$newSegment',
    queryParameters: carpoolId == null ? null : <String, String>{'carpool': carpoolId},
  ).toString();

  static String record(String id) => '$home/r/$id';
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
                    AppTab.chats => const ChatsScreen(),
                  },
                  routes: <RouteBase>[
                    if (tab == AppTab.chats) ...<RouteBase>[
                      GoRoute(
                        path: ChatRoutes.requestsSegment,
                        builder: (BuildContext context, GoRouterState state) => const ChatRequestsScreen(),
                      ),
                      GoRoute(
                        path: ChatRoutes.settingsSegment,
                        builder: (BuildContext context, GoRouterState state) => const ChatSettingsScreen(),
                      ),
                      // A chat by its Stream type and ID (pushes open these).
                      GoRoute(
                        path: ':type/:id',
                        redirect: (BuildContext context, GoRouterState state) =>
                            ChatRef.parse(state.pathParameters['type'], state.pathParameters['id']) == null ? AppTab.chats.path : null,
                        builder: (BuildContext context, GoRouterState state) => ConversationScreen(
                          chat: ChatRef.parse(state.pathParameters['type'], state.pathParameters['id']) ?? const ChatRef(ChatKind.private, 'none'),
                        ),
                      ),
                    ],
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
                      GoRoute(
                        path: ProfileRoutes.ratingsSegment,
                        builder: (BuildContext context, GoRouterState state) =>
                            const FeatureGate(feature: AppFeature.ratingsAndVouching, child: RateParentsScreen()),
                      ),
                      GoRoute(
                        path: ProfileRoutes.familySegment,
                        builder: (BuildContext context, GoRouterState state) => const FamilyScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.schoolYearSegment,
                        builder: (BuildContext context, GoRouterState state) =>
                            const FeatureGate(feature: AppFeature.yearlyChecks, child: SchoolYearScreen()),
                      ),
                      GoRoute(
                        path: ProfileRoutes.phoneSegment,
                        builder: (BuildContext context, GoRouterState state) => const PhoneChangeScreen(),
                      ),
                      GoRoute(
                        path: ProfileRoutes.walletSegment,
                        builder: (BuildContext context, GoRouterState state) =>
                            const FeatureGate(feature: AppFeature.wallet, child: WalletScreen()),
                        routes: <RouteBase>[
                          GoRoute(
                            path: WalletRoutes.sendSegment,
                            builder: (BuildContext context, GoRouterState state) => FeatureGate(
                              feature: AppFeature.wallet,
                              child: SendMoneyScreen(
                                carpoolId: state.uri.queryParameters['carpool'],
                                amount: int.tryParse(state.uri.queryParameters['amount'] ?? ''),
                              ),
                            ),
                          ),
                          GoRoute(
                            path: WalletRoutes.addSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                const FeatureGate(feature: AppFeature.wallet, child: AddMoneyScreen()),
                          ),
                          GoRoute(
                            path: WalletRoutes.withdrawSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                const FeatureGate(feature: AppFeature.wallet, child: WithdrawScreen()),
                          ),
                          GoRoute(
                            path: WalletRoutes.transferSegment,
                            builder: (BuildContext context, GoRouterState state) => FeatureGate(
                              feature: AppFeature.wallet,
                              child: TransferScreen(transferId: state.pathParameters['id'] ?? ''),
                            ),
                          ),
                        ],
                      ),
                      // Settle up by InstaPay (F45): the pilot's payment feature.
                      GoRoute(
                        path: SettleUpRoutes.segment,
                        builder: (BuildContext context, GoRouterState state) => FeatureGate(
                          feature: AppFeature.settleUp,
                          child: SettleUpScreen(carpoolId: state.uri.queryParameters['carpool']),
                        ),
                        routes: <RouteBase>[
                          GoRoute(
                            path: SettleUpRoutes.newSegment,
                            builder: (BuildContext context, GoRouterState state) => FeatureGate(
                              feature: AppFeature.settleUp,
                              child: NewSettleUpScreen(carpoolId: state.uri.queryParameters['carpool']),
                            ),
                          ),
                          GoRoute(
                            path: SettleUpRoutes.addressSegment,
                            builder: (BuildContext context, GoRouterState state) =>
                                const FeatureGate(feature: AppFeature.settleUp, child: InstaPayAddressScreen()),
                          ),
                          GoRoute(
                            path: SettleUpRoutes.recordSegment,
                            builder: (BuildContext context, GoRouterState state) => FeatureGate(
                              feature: AppFeature.settleUp,
                              child: SettleUpDetailScreen(id: state.pathParameters['id'] ?? ''),
                            ),
                          ),
                        ],
                      ),
                      // Prompt 12: privacy, phones, account deletion, new-phone check.
                      GoRoute(
                        path: PrivacyRoutes.segment,
                        builder: (BuildContext context, GoRouterState state) => const PrivacyScreen(),
                        routes: <RouteBase>[
                          GoRoute(
                            path: PrivacyRoutes.devicesSegment,
                            builder: (BuildContext context, GoRouterState state) => const DevicesScreen(),
                          ),
                          GoRoute(
                            path: PrivacyRoutes.deleteSegment,
                            builder: (BuildContext context, GoRouterState state) => const DeleteAccountScreen(),
                          ),
                          GoRoute(
                            path: PrivacyRoutes.newDeviceSegment,
                            builder: (BuildContext context, GoRouterState state) => const NewDeviceScreen(),
                          ),
                        ],
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
  // Prompt 12: screen tracking for usage analytics (route patterns only,
  // never IDs; consent in Settings) and the Sentry "area" tag.
  void trackScreen() {
    try {
      final String pattern = router.routerDelegate.currentConfiguration.fullPath;
      SentryArea.current = SentryArea.ofPath(pattern);
      ref.read(analyticsProvider).screen(pattern);
    } on Object catch (error) {
      debugPrint('screen tracking: ${error.runtimeType}');
    }
  }

  router.routerDelegate.addListener(trackScreen);
  ref.onDispose(() {
    router.routerDelegate.removeListener(trackScreen);
    router.dispose();
    session.dispose();
  });
  return router;
});
