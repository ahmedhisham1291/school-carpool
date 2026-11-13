// Screenshots for the owner (no Mac needed). Written, not run here.
//
// Renders the tab shell, the sign-up screens (Prompt 2) and the component
// gallery in Arabic and English, light and dark (gallery also in design
// directions A and B) with the real bundled fonts, and writes PNGs to
// test/screenshots/goldens/.
//
// These tests only run with --update-goldens (they are skipped in a plain
// `flutter test`, so there are no committed images to compare against):
//
//   flutter test test/screenshots --update-goldens
//
// CI (.github/workflows/checks.yml) runs this and uploads the folder as the
// "screenshots" artifact.

import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
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

import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

Future<void> _loadFont(String family, List<String> assets) async {
  final FontLoader loader = FontLoader(family);
  for (final String asset in assets) {
    loader.addFont(rootBundle.load(asset));
  }
  await loader.load();
}

Future<void> _loadFonts() async {
  await _loadFont('IBMPlexSansArabic', <String>[
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Regular.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Medium.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-SemiBold.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Bold.ttf',
  ]);
  await _loadFont('Tajawal', <String>[
    'assets/fonts/tajawal/Tajawal-Regular.ttf',
    'assets/fonts/tajawal/Tajawal-Medium.ttf',
    'assets/fonts/tajawal/Tajawal-Bold.ttf',
  ]);
  try {
    // Bundled by `uses-material-design: true`; without it icons are boxes.
    await _loadFont('MaterialIcons', <String>['fonts/MaterialIcons-Regular.otf']);
  } on Object catch (error) {
    debugPrint('screenshots: Material icons font not loaded ($error)');
  }
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required String location,
  required String locale,
  required String themeMode,
  required String direction,
  required Size logicalSize,
  required double pixelRatio,
  SessionState session = testVerifiedSession,
  List<Override> extraOverrides = const <Override>[],
}) async {
  tester.view
    ..devicePixelRatio = pixelRatio
    ..physicalSize = logicalSize * pixelRatio;
  addTearDown(tester.view.reset);

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
  setUpAll(_loadFonts);

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

  // Sign-up screens (Prompt 2) and the screens of an unverified account.
  const Map<String, String> signupScreens = <String, String>{
    'welcome': AuthRoutes.welcome,
    'phone': AuthRoutes.phone,
    'code': AuthRoutes.code,
    'email': AuthRoutes.email,
    'terms': AuthRoutes.terms,
    'verify_account': AuthRoutes.verifyAccount,
    'profile_unverified': '/profile',
  };
  for (final MapEntry<String, String> screen in signupScreens.entries) {
    for (final String locale in locales) {
      for (final String mode in modes) {
        final String name = 'signup_${screen.key}_${locale}_$mode';
        testWidgets(name, skip: skip, (WidgetTester tester) async {
          await _pumpScreen(
            tester,
            location: screen.value,
            locale: locale,
            themeMode: mode,
            direction: 'a',
            logicalSize: const Size(390, 844),
            pixelRatio: 3,
            session: testUnverifiedSession,
          );
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
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
            logicalSize: const Size(390, 7800),
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
  }
}
