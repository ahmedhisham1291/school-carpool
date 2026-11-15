// Screenshots for the owner (no Mac needed). Written, not run here.
//
// Renders the tab shell, the sign-up screens (Prompt 2), the verification
// screens (Prompt 3), the admin web panel (Prompt 4) and the component
// gallery in Arabic and English, light and dark (gallery also in design
// directions A and B), the schools picker and About (Prompt 4B), the maps
// screens (Prompt 5: nearby parents, home picker, driving schools), the
// carpool screens (Prompt 6: tab, search, create, detail as a member and
// as a visitor, invite, looking for a carpool), the trip screens (Prompt
// 10: driver run, live run, handover list) with the
// real bundled fonts, and writes PNGs to
// test/screenshots/goldens/. The shell, the sign-up and the verification
// screens are also rendered on a small 320 dp phone, at normal and at 200
// percent text, to show that tab labels, titles and buttons stay on one
// line; the admin panel also at 1024 px and at 200 percent text.
//
// These tests only run with --update-goldens (they are skipped in a plain
// `flutter test`, so there are no committed images to compare against):
//
//   flutter test test/screenshots --update-goldens
//
// CI (.github/workflows/checks.yml) runs this and uploads the folder as the
// "screenshots" artifact.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:run_recovery/run_recovery.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/about/about_screen.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/chat/chat_provider.dart';
import 'package:school_carpool/features/chat/chats_screen.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/features/schools/other_school_screen.dart';
import 'package:school_carpool/features/schools/school_picker_screen.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/trips/location_gate.dart';
import 'package:school_carpool/features/trips/location_tracker.dart';
import 'package:school_carpool/features/trips/run_recovery.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/carpool_fakes.dart';
import '../helpers/chat_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/map_fakes.dart';
import '../helpers/notification_fakes.dart';
import '../helpers/privacy_fakes.dart';
import '../helpers/schedule_fakes.dart';
import '../helpers/school_fakes.dart';
import '../helpers/settle_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/trip_fakes.dart';
import '../helpers/trust_fakes.dart';
import '../helpers/verification_fakes.dart';
import '../helpers/wallet_fakes.dart';

Future<void> _pumpScreen(
  WidgetTester tester, {
  required String location,
  required String locale,
  required String themeMode,
  required String direction,
  required Size logicalSize,
  required double pixelRatio,
  SessionState session = testVerifiedSession,
  double textScale = 1,
  List<Override> extraOverrides = const <Override>[],
  MapRepository? maps,
  CarpoolRepository? carpools,
  ScheduleRepository? schedule,
  NotificationRepository? notifications,
  FakeChatProvider? chat,
  FakeChatRepository? chatRepository,
  TripRepository? trips,
  LocationTracker? tracker,
  DrivingReadiness? readiness,
  RecoveryNative? recovery,
  FakeWalletRepository? wallet,
  FakeTrustRepository? trust,
  FeatureSwitches? features,
  FakeSettleUpRepository? settle,
}) async {
  tester.view
    ..devicePixelRatio = pixelRatio
    ..physicalSize = logicalSize * pixelRatio;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final GoRouter router = buildAppRouter(showDevTools: true, initialLocation: location);
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testDevConfig),
        settingsStoreProvider.overrideWithValue(
          InMemorySettingsStore(<String, String>{
            LocaleController.storageKey: locale,
            ThemeModeController.storageKey: themeMode,
            DesignDirectionController.storageKey: direction,
          }),
        ),
        routerProvider.overrideWithValue(router),
        ...authOverrides(
          session: session,
          maps: maps,
          carpools: carpools,
          schedule: schedule,
          notifications: notifications,
          chat: chat,
          chatRepository: chatRepository,
          trips: trips,
          tracker: tracker,
          readiness: readiness,
          recovery: recovery,
          wallet: wallet,
          trust: trust,
          features: features,
          settle: settle,
        ),
        signupFlowProvider.overrideWith(_PresetSignupFlow.new),
        // Prompt 12: the device guard reads the privacy repository.
        privacyRepositoryProvider.overrideWithValue(FakePrivacyRepository()),
        ...extraOverrides,
      ],
      child: const CarpoolApp(),
    ),
  );
  // The gallery has a looping skeleton animation: pump frames, do not settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The code screen needs a number the code was "sent" to. Fake number.
class _PresetSignupFlow extends SignupFlowController {
  @override
  SignupFlowState build() => SignupFlowState(
    phoneE164: '+201000000001',
    resendAvailableAt: DateTime.now().add(const Duration(seconds: 45)),
  );
}

void main() {
  setUpAll(loadAppFonts);

  const List<String> locales = <String>['ar', 'en'];
  const List<String> modes = <String>['light', 'dark'];
  // Only render when asked to write images (see the header).
  final bool skip = !autoUpdateGoldenFiles;

  // Tab shell: Home and Profile (settings), direction A, iPhone 13 size.
  for (final String tab in <String>['home', 'profile']) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'shell_${tab}_a_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: '/$tab',
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Sign-up screens (Prompt 2) and the screens of an unverified account,
  // each with the session the router lets onto that screen.
  const Map<String, (String, SessionState)> signupScreens = <String, (String, SessionState)>{
    'welcome': (AuthRoutes.welcome, SessionSignedOut()),
    'phone': (AuthRoutes.phone, SessionSignedOut()),
    'code': (AuthRoutes.code, SessionSignedOut()),
    'email': (AuthRoutes.email, testEmailStageSession),
    'terms': (AuthRoutes.terms, testTermsStageSession),
    'verify_account': (AuthRoutes.verifyAccount, testUnverifiedSession),
    'profile_unverified': ('/profile', testUnverifiedSession),
  };
  for (final MapEntry<String, (String, SessionState)> screen in signupScreens.entries) {
    final (String location, SessionState session) = screen.value;
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'signup_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: location,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            session: session,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
    // Small phone (320 dp), light, normal and 200 percent text: titles,
    // labels and buttons stay on one line.
    for (final double scale in <double>[1, 2]) {
      for (final String locale in locales) {
        final String name = 'signup_${screen.key}_${locale}_light_320_text${scale.round()}x';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: location,
            locale: locale,
            themeMode: 'light',
            direction: 'a',
            logicalSize: const Size(320, 640),
            pixelRatio: 3,
            session: session,
            textScale: scale,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Small phone (320 dp wide), Home tab, normal and 200 percent text: the
  // tab labels must stay on one line.
  for (final double scale in <double>[1, 2]) {
    for (final String locale in locales) {
      final String name = 'shell_home_a_${locale}_light_320_text${scale.round()}x';
      testWidgets(name, skip: skip, (WidgetTester tester) async {
        await _pumpScreen(
          tester,
          location: '/home',
          locale: locale,
          themeMode: 'light',
          direction: 'a',
          logicalSize: const Size(320, 640),
          pixelRatio: 3,
          textScale: scale,
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
      });
    }
  }

  // Gallery: every component, both directions. Tall canvas so the whole
  // list is in one image.
  for (final String direction in <String>['a', 'b']) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'gallery_${direction}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: AppRoutes.gallery,
            locale: locale,
            themeMode: mode,
            direction: direction,
            logicalSize: const Size(390, 8800),
            pixelRatio: 2,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Verification (Prompt 3): the first step, pending, rejected with a
  // reason, children and driving. The camera screen needs a real camera and
  // is not rendered here (see docs/progress/prompt-03.md).
  SessionState withStatus(AccountStatus status, VerificationSummary? summary) => SessionSignedIn(
    uid: 'uid-1',
    account: Account(
      parentId: 'ABCD2345',
      status: status,
      phone: '+201000000001',
      email: 'parent@example.com',
      emailVerified: true,
      termsAccepted: true,
      language: 'ar',
      firstName: 'Mona',
      verification: summary,
    ),
  );
  const List<ChildRecord> sampleChildren = <ChildRecord>[
    ChildRecord(id: 'k1', firstName: 'Omar', age: 8, grade: Grade.g3, schoolName: 'Nile School', status: ReviewStatus.approved),
    ChildRecord(
      id: 'k2',
      firstName: 'Laila',
      age: 5,
      grade: Grade.kg2,
      schoolName: 'Nile School',
      status: ReviewStatus.rejected,
      reason: RejectionReason.schoolIdUnclear,
    ),
  ];
  final Map<String, (String, SessionState)> verificationScreens = <String, (String, SessionState)>{
    'verify_details': (AuthRoutes.verifySubmit, withStatus(AccountStatus.unverified, null)),
    'verify_pending': (
      AuthRoutes.verifyAccount,
      withStatus(AccountStatus.pending, const VerificationSummary(caseId: 'c1', status: ReviewStatus.pending)),
    ),
    'verify_rejected': (
      AuthRoutes.verifyAccount,
      withStatus(
        AccountStatus.rejected,
        const VerificationSummary(caseId: 'c1', status: ReviewStatus.rejected, reason: RejectionReason.selfieMismatch),
      ),
    ),
    'children': (ProfileRoutes.children, withStatus(AccountStatus.verified, null)),
    'driving': (ProfileRoutes.driving, withStatus(AccountStatus.verified, null)),
  };
  for (final MapEntry<String, (String, SessionState)> screen in verificationScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'verification_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value.$1,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            session: screen.value.$2,
            extraOverrides: verificationOverrides(
              repository: FakeVerificationRepository(),
              children: sampleChildren,
            ),
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
    // Small phone (320 dp), light, normal and 200 percent text.
    for (final double scale in <double>[1, 2]) {
      for (final String locale in locales) {
        final String name = 'verification_${screen.key}_${locale}_light_320_text${scale.round()}x';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value.$1,
            locale: locale,
            themeMode: 'light',
            direction: 'a',
            logicalSize: const Size(320, 640),
            pixelRatio: 3,
            session: screen.value.$2,
            textScale: scale,
            extraOverrides: verificationOverrides(
              repository: FakeVerificationRepository(),
              children: sampleChildren,
            ),
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Settle up by InstaPay (F45) and the pilot feature switches: the list,
  // my InstaPay address, a new request, a record I have to pay (with the
  // payee's address and Copy), a record waiting for my confirmation,
  // Profile with the pilot defaults and the "Not available yet" screen.
  // Arabic and English, light and dark, fake data.
  const Map<String, String> settleScreens = <String, String>{
    'home': SettleUpRoutes.home,
    'address': SettleUpRoutes.address,
    'new': '${SettleUpRoutes.home}/${SettleUpRoutes.newSegment}',
    'detail_pay': '${SettleUpRoutes.home}/r/s_owe',
    'detail_confirm': '${SettleUpRoutes.home}/r/s_confirm',
    'profile_pilot': '/profile',
    'feature_off': ProfileRoutes.wallet,
  };
  for (final MapEntry<String, String> screen in settleScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'settle_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          final FakeSettleUpRepository settle = FakeSettleUpRepository(
            records: <SettleUp>[
              ...sampleSettleUps(),
              settleRecord('s_confirm', iPay: false, other: 'Badr', otherUid: 'uid-badr', amount: 4000, status: SettleStatus.paid),
            ],
          );
          addTearDown(settle.dispose);
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 1200),
            pixelRatio: 3,
            features: FeatureSwitches.pilot,
            settle: settle,
          );
          await tester.pump(const Duration(milliseconds: 100));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
    // Small phone (320 dp), light, normal and 200 percent text.
    for (final double scale in <double>[1, 2]) {
      for (final String locale in locales) {
        final String name = 'settle_${screen.key}_${locale}_light_320_text${scale.round()}x';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          final FakeSettleUpRepository settle = FakeSettleUpRepository();
          addTearDown(settle.dispose);
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: 'light',
            direction: 'a',
            logicalSize: const Size(320, 1200),
            pixelRatio: 3,
            textScale: scale,
            features: FeatureSwitches.pilot,
            settle: settle,
          );
          await tester.pump(const Duration(milliseconds: 100));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Admin web panel (Prompt 4, F14): desktop size, fake data.
  final Map<String, (String, AdminSessionState, Size)> adminScreens = <String, (String, AdminSessionState, Size)>{
    'sign_in': (AdminRoutes.signIn, const AdminSignedOut(), const Size(1280, 800)),
    'two_step_setup': (AdminRoutes.twoStepSetup, const AdminNeedsSecondFactor(testReviewer), const Size(1280, 800)),
    'queue': (AdminRoutes.queue, const AdminSignedIn(testReviewer), const Size(1280, 800)),
    'case': ('/queue/case1', const AdminSignedIn(testReviewer), const Size(1280, 1500)),
    'users': (AdminRoutes.users, const AdminSignedIn(testReviewer), const Size(1280, 800)),
    'user': ('/users/parent1', const AdminSignedIn(testReviewer), const Size(1280, 1000)),
    'schools': (AdminRoutes.schools, const AdminSignedIn(testReviewer), const Size(1280, 800)),
    'school_new': (AdminRoutes.newSchool, const AdminSignedIn(testReviewer), const Size(1280, 1000)),
    'school_edit': ('/schools/s1', const AdminSignedIn(testReviewer), const Size(1280, 1100)),
    'other_schools': (AdminRoutes.otherSchools, const AdminSignedIn(testReviewer), const Size(1280, 800)),
    'other_school_review': ('/other-schools/p1', const AdminSignedIn(testReviewer), const Size(1280, 1100)),
    'reports': (AdminRoutes.reports, const AdminSignedIn(testReviewer), const Size(1280, 800)),
    'report': ('/reports/r1', const AdminSignedIn(testReviewer), const Size(1280, 1100)),
    'audit': (AdminRoutes.audit, const AdminSignedIn(testSuperAdmin), const Size(1280, 800)),
    'admins': (AdminRoutes.admins, const AdminSignedIn(testSuperAdmin), const Size(1280, 800)),
    // Pilot feature switches (super admin: the switches can be changed).
    'settings': (AdminRoutes.settings, const AdminSignedIn(testSuperAdmin), const Size(1280, 900)),
    'gallery': (AdminRoutes.gallery, const AdminSignedIn(testReviewer), const Size(1280, 1600)),
  };
  for (final MapEntry<String, (String, AdminSessionState, Size)> screen in adminScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'admin_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await pumpAdminPanel(
            tester,
            session: screen.value.$2,
            location: screen.value.$1,
            locale: locale,
            themeMode: mode,
            size: screen.value.$3,
          );
          for (int i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Schools list (Prompt 4B, F4): the school picker before typing, with
  // results, with no results, the "Other" form, and About with the
  // OpenStreetMap credit.
  final Map<String, (Widget, String?)> schoolScreens = <String, (Widget, String?)>{
    'school_picker': (const SchoolPickerScreen(), null),
    'school_picker_results': (const SchoolPickerScreen(), 'school'),
    'school_picker_empty': (const SchoolPickerScreen(), 'zzzz'),
    'school_other': (const OtherSchoolScreen(initialName: 'Zohour School'), null),
    'about': (const AboutScreen(), null),
  };
  for (final MapEntry<String, (Widget, String?)> screen in schoolScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = '${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          tester.view
            ..devicePixelRatio = 3
            ..physicalSize = const Size(390, 844) * 3;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            buildTestApp(
              screen.value.$1,
              locale: locale == 'ar' ? AppLocales.arabic : AppLocales.english,
              brightness: mode == 'dark' ? Brightness.dark : Brightness.light,
              extraOverrides: <Override>[...authOverrides(session: testUnverifiedSession), ...schoolOverrides()],
            ),
          );
          await tester.pump();
          final String? query = screen.value.$2;
          if (query != null) {
            await tester.enterText(find.byKey(const Key('school.search')), query);
            await tester.pump(const Duration(milliseconds: 400));
          }
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Maps (Prompt 5): nearby parents, the home picker and driving schools,
  // with a saved fake home and a child at a fake school. The maps are drawn
  // by the sketch (no Google key in CI).
  const Map<String, String> mapScreens = <String, String>{
    'nearby': HomeRoutes.nearby,
    'home_location': ProfileRoutes.homeLocation,
    'driving_schools': ProfileRoutes.drivingSchools,
  };
  for (final MapEntry<String, String> screen in mapScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'maps_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            maps: FakeMapRepository(home: const HomeLocation(location: testHome, label: 'Road 9, Maadi (test)')),
            extraOverrides: verificationOverrides(
              repository: FakeVerificationRepository(),
              children: const <ChildRecord>[
                ChildRecord(
                  id: 'c1',
                  firstName: 'Adam',
                  age: 8,
                  grade: Grade.g3,
                  schoolName: 'Nile International School',
                  status: ReviewStatus.approved,
                  schoolId: 'nile',
                ),
              ],
            ),
          );
          // The nearby search runs after the first frame.
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Carpools (Prompt 6): the tab, search, the first create step, a carpool
  // as a member (members, consent, requests) and as a visitor, the invite
  // link of an unverified parent, and "looking for a carpool" with a match.
  const List<CarpoolMember> members = <CarpoolMember>[
    CarpoolMember(
      uid: 'p1',
      firstName: 'Hoda',
      isAdmin: true,
      children: <CarpoolChild>[CarpoolChild(id: 'h1', firstName: 'Laila', grade: Grade.g2)],
    ),
    testMe,
  ];
  const WantedList wanted = WantedList(
    posts: <WantedPost>[
      WantedPost(id: 'uid-1', firstName: 'Mona', days: Weekday.schoolDays, childrenCount: 1, morning: '07:30', mine: true),
      WantedPost(id: 'p1', firstName: 'Hoda', days: Weekday.schoolDays, childrenCount: 2, morning: '07:45', areaNameEn: 'Degla', areaNameAr: 'دجلة'),
      WantedPost(id: 'p2', firstName: 'Tarek', days: <Weekday>[Weekday.sun, Weekday.tue], childrenCount: 1, morning: '07:15'),
    ],
    suggestion: WantedSuggestion(families: 3, days: Weekday.schoolDays, morning: '07:30'),
  );
  final Map<String, (String, SessionState, bool)> carpoolScreens = <String, (String, SessionState, bool)>{
    'tab': (AppTab.carpools.path, testVerifiedSession, true),
    'search': (CarpoolRoutes.search, testVerifiedSession, false),
    'create': ('${CarpoolRoutes.create}?school=nile', testVerifiedSession, false),
    'detail_member': ('/carpools/k1', testVerifiedSession, true),
    'detail_visitor': ('/carpools/k1', testVerifiedSession, false),
    'invite_unverified': (CarpoolRoutes.invite('ABCDEFGH23'), testUnverifiedSession, false),
    'looking': (CarpoolRoutes.looking, testVerifiedSession, false),
  };
  for (final MapEntry<String, (String, SessionState, bool)> screen in carpoolScreens.entries) {
    final (String location, SessionState session, bool member) = screen.value;
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'carpools_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: location,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            session: session,
            carpools: FakeCarpoolRepository(
              memberships: member
                  ? const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved, isAdmin: true)]
                  : const <Membership>[],
              members: members,
              requests: const <JoinRequest>[
                JoinRequest(
                  uid: 'p2',
                  firstName: 'Tarek',
                  children: <CarpoolChild>[CarpoolChild(id: 't1', firstName: 'Omar', grade: Grade.kg2)],
                ),
              ],
              wanted: wanted,
            ),
            extraOverrides: verificationOverrides(
              repository: FakeVerificationRepository(),
              children: const <ChildRecord>[
                ChildRecord(
                  id: 'c1',
                  firstName: 'Adam',
                  age: 8,
                  grade: Grade.g3,
                  schoolName: 'Nile International School',
                  status: ReviewStatus.approved,
                  schoolId: 'nile',
                ),
              ],
            ),
          );
          // Searches and lists load after the first frame.
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Schedule (Prompt 7): the week plan with every run status, days off and
  // times (a holiday and Ramadan times), and the drive balance. Fake data.
  final FakeScheduleRepository schedule = FakeScheduleRepository(
    weeks: <String, List<ScheduleRun>>{
      '2026-11-14': <ScheduleRun>[
        testRun('2026-11-15', RunDirection.toSchool),
        testRun('2026-11-15', RunDirection.toHome, status: RunStatus.confirmed, driverUid: 'p1', driverFirstName: 'Hoda'),
        testRun('2026-11-16', RunDirection.toSchool, status: RunStatus.open, driverUid: null, swapId: 's1', swapBy: 'p1'),
        testRun('2026-11-16', RunDirection.toHome, status: RunStatus.confirmed),
        testRun('2026-11-17', RunDirection.toSchool, status: RunStatus.cancelled, driverUid: null),
        testRun('2026-11-17', RunDirection.toHome, status: RunStatus.cancelled, driverUid: null),
      ],
    },
    exceptions: <ScheduleException>[
      ScheduleException(id: 'x1', kind: ExceptionKind.noSchool, reason: ExceptionReason.holiday, from: DateTime(2026, 11, 17), to: DateTime(2026, 11, 17)),
      ScheduleException(
        id: 'x2',
        kind: ExceptionKind.times,
        reason: ExceptionReason.ramadan,
        from: DateTime(2027, 2, 8),
        to: DateTime(2027, 3, 9),
        morning: '08:30',
        afternoon: '13:30',
      ),
    ],
    balance: const DriveBalance(
      termId: '2026-t1',
      families: <FamilyBalance>[
        FamilyBalance(uid: 'p1', firstName: 'Hoda', driven: 6, received: 2, share: 4),
        FamilyBalance(uid: 'uid-1', firstName: 'Mona', driven: 3, received: 5, share: 5),
      ],
    ),
  );
  final Map<String, String> scheduleScreens = <String, String>{
    'week': CarpoolRoutes.schedule('k1'),
    'exceptions': CarpoolRoutes.exceptions('k1'),
    'balance': CarpoolRoutes.balance('k1'),
  };
  for (final MapEntry<String, String> screen in scheduleScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'schedule_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            carpools: FakeCarpoolRepository(
              memberships: const <Membership>[Membership(carpoolId: 'k1', status: MembershipStatus.approved, isAdmin: true)],
              members: members,
            ),
            schedule: schedule,
            extraOverrides: verificationOverrides(repository: FakeVerificationRepository()),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 8: the Notifications tab (with a critical alert pinned above the
  // tabs) and the alert settings.
  final Map<String, String> notificationScreens = <String, String>{
    'tab': AppTab.notifications.path,
    'settings': ProfileRoutes.notifications,
  };
  for (final MapEntry<String, String> screen in notificationScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'notifications_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            notifications: FakeNotificationRepository(
              items: <AppNotification>[
                testNotification('c1', NotificationKind.noDriver, ago: const Duration(minutes: 20)),
                testNotification('n1', NotificationKind.swapRequested),
                testNotification('n2', NotificationKind.joinRequested, ago: const Duration(hours: 3)),
                testNotification('n3', NotificationKind.driveEvening, read: true, ago: const Duration(days: 1)),
                testNotification('n4', NotificationKind.childAbsent, read: true, ago: const Duration(days: 2)),
              ],
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 9: the Chats tab, a carpool chat, requests and chat settings
  // (fake parents, the on-phone fake chat).
  final Map<String, String> chatScreens = <String, String>{
    'tab': AppTab.chats.path,
    'carpool_chat': carpoolChat.route,
    'requests': ChatRoutes.requests,
    'settings': ChatRoutes.settings,
  };
  for (final MapEntry<String, String> screen in chatScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'chat_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          final FakeChatProvider chat = FakeChatProvider(chats: sampleChats(), messages: sampleMessages(), now: chatNow);
          final FakeChatRepository repo = FakeChatRepository(
            requests: <ChatRequest>[testChatRequest('hoda_uid-1', from: 'uid-hoda', to: 'uid-1')],
            blocks: const <ChatBlock>[ChatBlock(blockedUid: 'uid-x', firstName: 'Samir')],
          );
          addTearDown(chat.close);
          addTearDown(repo.close);
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            chat: chat,
            chatRepository: repo,
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 10: the driver's run (stops, quick and emergency buttons), the
  // parents' live run (map, arrival time, driver card) and the handover list.
  final Map<String, String> tripScreens = <String, String>{
    'drive': CarpoolRoutes.drive('k1', '2026-11-14_am'),
    'live': CarpoolRoutes.trip('k1', '2026-11-14_am'),
    'handover': '${ProfileRoutes.handover}/c1',
  };
  for (final MapEntry<String, String> screen in tripScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'trips_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          final bool live = screen.key == 'live';
          final FakeTripRepository trips = FakeTripRepository(trip: testTrip(driverUid: live ? 'p1' : 'uid-1'))
            ..eta = TripEta(stops: <String, DateTime>{'c1': testNow.add(const Duration(minutes: 7)).toUtc()})
            ..adults = <HandoverAdult>[const HandoverAdult(name: 'Gran', relation: Relation.grandparent)]
            ..preparation = const TripPreparation(tripId: 'k1_2026-11-14_am', selfieRequired: false, active: true);
          final FakeLocationTracker tracker = FakeLocationTracker(permission: TrackerPermission.always);
          addTearDown(trips.dispose);
          addTearDown(tracker.dispose);
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            trips: trips,
            tracker: tracker,
            extraOverrides: verificationOverrides(repository: FakeVerificationRepository()),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 13: the driving gate (every item missing, blocking) and the
  // home banner with its non-blocking steps. Fake data only.
  for (final String locale in locales) {
    for (final String mode in modes) {
      final String gate = 'trips_gate_${locale}_$mode';
      testWidgets(gate, skip: skip, (WidgetTester tester) async {
        final FakeTripRepository trips = FakeTripRepository(trip: testTrip());
        final FakeDrivingReadiness readiness = FakeDrivingReadiness(
          current: const DrivingCheck(missing: <GateItem>{GateItem.service, GateItem.permission, GateItem.precise, GateItem.notifications}),
        );
        addTearDown(trips.dispose);
        addTearDown(readiness.dispose);
        await _pumpScreen(
          tester,
          location: CarpoolRoutes.drive('k1', '2026-11-14_am'),
          locale: locale,
          themeMode: mode,
          direction: 'a',
          logicalSize: const Size(390, 844),
          pixelRatio: 3,
          trips: trips,
          readiness: readiness,
          extraOverrides: verificationOverrides(repository: FakeVerificationRepository()),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('drive.start')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$gate.png'));
      });
      final String always = 'trips_always_${locale}_$mode';
      testWidgets(always, skip: skip, (WidgetTester tester) async {
        final FakeTripRepository trips = FakeTripRepository(trip: testTrip());
        addTearDown(trips.dispose);
        await _pumpScreen(
          tester,
          location: CarpoolRoutes.drive('k1', '2026-11-14_am'),
          locale: locale,
          themeMode: mode,
          direction: 'a',
          logicalSize: const Size(390, 844),
          pixelRatio: 3,
          trips: trips,
          recovery: FakeRecoveryNative(supported: true, status: RecoveryAuthorization.whenInUse),
          extraOverrides: verificationOverrides(repository: FakeVerificationRepository()),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('drive.start')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$always.png'));
      });
      for (final bool steps in <bool>[false, true]) {
        final String banner = steps ? 'home_location_steps_${locale}_$mode' : 'home_location_banner_${locale}_$mode';
        testWidgets(banner, skip: skip, (WidgetTester tester) async {
          final FakeDrivingReadiness readiness = FakeDrivingReadiness(
            current: const DrivingCheck(missing: <GateItem>{GateItem.permission, GateItem.notifications}),
          );
          addTearDown(readiness.dispose);
          await _pumpScreen(
            tester,
            location: '/home',
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            readiness: readiness,
          );
          await tester.pump(const Duration(milliseconds: 400));
          if (steps) {
            await tester.tap(find.text(locale == 'ar' ? 'الخطوات' : 'Steps'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
          }
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$banner.png'));
        });
      }
    }
  }

  // Prompt 11B: the wallet (open and not yet opened), Send (Pay contribution
  // lands on the receiver confirmation), a pending transfer and Add money.
  // Fake parents and test money only.
  final Map<String, (String, WalletInfo)> walletScreens = <String, (String, WalletInfo)>{
    'wallet': (ProfileRoutes.wallet, openWallet),
    'open': (ProfileRoutes.wallet, closedWallet),
    'send_who': (WalletRoutes.send(), openWallet),
    'send_confirm': (WalletRoutes.send(carpoolId: 'c-k1', amount: 30000), openWallet),
    'transfer': (WalletRoutes.transfer('t_2'), openWallet),
    'add': (WalletRoutes.add, openWallet),
  };
  for (final MapEntry<String, (String, WalletInfo)> screen in walletScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'wallet_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value.$1,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            wallet: FakeWalletRepository(info: screen.value.$2),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 11 (F17): rate parents, family links, the yearly check and the
  // phone change. Fake parents only.
  final Map<String, String> trustScreens = <String, String>{
    'rate': ProfileRoutes.ratings,
    'family': ProfileRoutes.family,
    'school_year': ProfileRoutes.schoolYear,
    'phone': ProfileRoutes.phone,
  };
  for (final MapEntry<String, String> screen in trustScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'trust_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            trust: FakeTrustRepository(overviewValue: const TrustOverview(summary: TrustSummary(ratings: 4, average: 4.5, vouches: 2), toRate: 2, yearCheck: sampleYearCheck), familyValue: sampleFamily),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }

  // Prompt 12: privacy, phones and sign-ins, delete account, new phone.
  // Fake data only.
  final Map<String, String> privacyScreens = <String, String>{
    'privacy': PrivacyRoutes.privacy,
    'devices': PrivacyRoutes.devices,
    'delete': PrivacyRoutes.delete,
    'new_device': PrivacyRoutes.newDevice,
  };
  for (final MapEntry<String, String> screen in privacyScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'privacy_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }
}
