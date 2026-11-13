// Screenshots for the owner (no Mac needed). Written, not run here.
//
// Renders the tab shell, the sign-up screens (Prompt 2), the verification
// screens (Prompt 3), the admin web panel (Prompt 4) and the component
// gallery in Arabic and English, light and dark (gallery also in design
// directions A and B) with the real bundled fonts, and writes PNGs to
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
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

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
        ...authOverrides(session: session),
        signupFlowProvider.overrideWith(_PresetSignupFlow.new),
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
    'audit': (AdminRoutes.audit, const AdminSignedIn(testSuperAdmin), const Size(1280, 800)),
    'admins': (AdminRoutes.admins, const AdminSignedIn(testSuperAdmin), const Size(1280, 800)),
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
}
