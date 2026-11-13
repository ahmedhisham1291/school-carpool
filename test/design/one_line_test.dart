// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI: `flutter test`.
//
// The one-line rule (CLAUDE.md DESIGN, docs/DESIGN.md): every tab, button,
// chip, title and label fits on one line in Arabic and English on a 320 dp
// wide phone. Real fonts are loaded so text has its true width.

import 'dart:async';

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/auth/signup_flow.dart';
import 'package:school_carpool/features/onboarding/account_status_badge.dart';
import 'package:school_carpool/features/onboarding/onboarding_layout.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/fonts.dart';
import '../helpers/test_app.dart';

const double _narrowWidth = 320;

/// Sets a 320 dp wide phone of the given height and the text scale.
void _useNarrowPhone(WidgetTester tester, {double height = 640, double textScale = 1}) {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(_narrowWidth * 2, height * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The paragraphs that [finder] renders.
List<RenderParagraph> _paragraphs(Finder finder) => find
    .descendant(of: finder, matching: find.byType(RichText), matchRoot: true)
    .evaluate()
    .map((Element element) => element.renderObject! as RenderParagraph)
    .toList();

/// Fails if any text under [finder] wraps onto a second line or is cut off
/// with an ellipsis.
void _expectOneLine(Finder finder, String where) {
  final List<RenderParagraph> paragraphs = _paragraphs(finder);
  expect(paragraphs, isNotEmpty, reason: 'no text found: $where');
  for (final RenderParagraph paragraph in paragraphs) {
    final String text = paragraph.text.toPlainText();
    if (text.isEmpty) {
      continue;
    }
    // A box that starts in the lower half of the paragraph is a second line.
    final double half = paragraph.size.height / 2;
    final bool wraps = paragraph
        .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length))
        .any((box) => box.top >= half);
    expect(wraps, isFalse, reason: '"$text" wraps onto two lines ($where)');
    expect(paragraph.didExceedMaxLines, isFalse, reason: '"$text" is cut off ($where)');
  }
}

/// Fails if any text under [finder] is drawn smaller than [minScale] of its
/// size (text that scales down to fit instead of wrapping).
void _expectNotShrunk(Finder finder, double minScale, String where) {
  for (final RenderParagraph paragraph in _paragraphs(finder)) {
    final Rect drawn = MatrixUtils.transformRect(
      paragraph.getTransformTo(null),
      Offset.zero & paragraph.size,
    );
    final double scale = drawn.width / paragraph.size.width;
    expect(
      scale,
      greaterThanOrEqualTo(minScale),
      reason: '"${paragraph.text.toPlainText()}" is shrunk to $scale; shorten it ($where)',
    );
  }
}

/// Pumps [build] inside our theme and locale and returns once it is laid out.
Future<void> _pumpContent(
  WidgetTester tester,
  Locale locale,
  WidgetBuilder build,
) async {
  await tester.pumpWidget(buildTestApp(Builder(builder: build), locale: locale));
  await tester.pump();
}

/// Like [_expectOneLine], but passes when [finder] finds nothing (a widget
/// that a screen shows only in some states).
void _expectOneLineIfShown(Finder finder, String where) {
  if (finder.evaluate().isNotEmpty) {
    _expectOneLine(finder, where);
  }
}

/// The code step needs a number the code was "sent" to. Fake number.
class _CodeSentFlow extends SignupFlowController {
  @override
  SignupFlowState build() => SignupFlowState(
    phoneE164: '+201000000001',
    resendAvailableAt: DateTime.now().add(const Duration(seconds: 45)),
  );
}

/// Sign-up screens (Prompt 2) and Profile, each with the session the router
/// lets onto it.
const Map<String, (String, SessionState)> _signupScreens = <String, (String, SessionState)>{
  'welcome': (AuthRoutes.welcome, SessionSignedOut()),
  'phone': (AuthRoutes.phone, SessionSignedOut()),
  'code': (AuthRoutes.code, SessionSignedOut()),
  'email': (AuthRoutes.email, testEmailStageSession),
  'terms': (AuthRoutes.terms, testTermsStageSession),
  'verify account': (AuthRoutes.verifyAccount, testUnverifiedSession),
  'profile': ('/profile', testUnverifiedSession),
};

/// Pumps the real app router at [location] with a fixed session and a fake
/// repository (no Firebase).
Future<void> _pumpRoute(
  WidgetTester tester, {
  required Locale locale,
  required String location,
  required SessionState session,
}) async {
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testStagingConfig),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ...authOverrides(session: session),
        signupFlowProvider.overrideWith(_CodeSentFlow.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.light(DesignDirection.a),
      ),
    ),
  );
  // The code step ticks a countdown and the email step checks once on
  // open: pump frames, do not settle.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(loadAppFonts);

  for (final Locale locale in AppLocales.supported) {
    final String lang = locale.languageCode;

    for (final double textScale in <double>[1, 2]) {
      testWidgets('[$lang] bottom tabs fit one line at 320 dp, text x$textScale', (
        WidgetTester tester,
      ) async {
        _useNarrowPhone(tester, textScale: textScale);
        await _pumpContent(
          tester,
          locale,
          (BuildContext context) => Scaffold(
            bottomNavigationBar: AppNavigationBar(
              destinations: HomeShell.destinations(context.l10n),
              selectedIndex: 3,
              onDestinationSelected: (int index) {},
            ),
          ),
        );

        final Finder items = find.byType(AppNavigationBarItem);
        expect(items, findsNWidgets(5));
        for (int i = 0; i < 5; i++) {
          final Finder item = items.at(i);
          final Finder label = find.descendant(of: item, matching: find.byType(Text));
          _expectOneLine(label, 'tab $i');

          // The label sits inside its own tab, and is not shrunk much: the
          // wording is short enough to read at a glance.
          final Rect itemRect = tester.getRect(item);
          final Rect labelRect = tester.getRect(label);
          expect(labelRect.left, greaterThanOrEqualTo(itemRect.left - 0.5));
          expect(labelRect.right, lessThanOrEqualTo(itemRect.right + 0.5));
          final RenderParagraph paragraph = _paragraphs(label).single;
          final double shrink = labelRect.width / paragraph.size.width;
          expect(
            shrink,
            greaterThanOrEqualTo(textScale == 1 ? 0.95 : 0.75),
            reason: '"${paragraph.text.toPlainText()}" is scaled to $shrink; shorten it',
          );
          // Text scaling is clamped inside the bar only.
          expect(
            paragraph.textScaler.scale(1),
            lessThanOrEqualTo(AppTypeScale.maxNavTextScale + 0.001),
          );
        }
      });
    }

    testWidgets('[$lang] buttons, chips, rows and titles fit one line at 320 dp', (
      WidgetTester tester,
    ) async {
      _useNarrowPhone(tester, height: 4000);
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        final List<String> buttons = <String>[
          l10n.sampleButtonPrimary,
          l10n.sampleButtonSecondary,
          l10n.sampleButtonTertiary,
          l10n.sampleButtonDanger,
          l10n.sampleButtonLoading,
          l10n.sampleSheetOpen,
          l10n.sampleConfirmOpen,
          l10n.actionRetry,
          l10n.actionCancel,
          l10n.actionConfirm,
        ];
        final List<String> headers = <String>[
          l10n.settingsTitle,
          l10n.devToolsTitle,
          l10n.gallerySectionButtons,
          l10n.gallerySectionChips,
          l10n.gallerySectionInputs,
          l10n.gallerySectionCards,
          l10n.gallerySectionNavigation,
          l10n.gallerySectionListRows,
          l10n.gallerySectionSheets,
          l10n.gallerySectionSkeleton,
          l10n.gallerySectionStates,
        ];
        final List<String> rows = <String>[
          l10n.devOpenGallery,
          l10n.devSendTestError,
          l10n.devSendFunctionTestError,
          l10n.sampleListTitle,
        ];
        const double stateHeight = AppSpacing.s64 * 6;
        return Scaffold(
          appBar: AppBar(title: AppBarTitle(l10n.galleryTitle)),
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final String label in buttons) ...<Widget>[
                        AppButton(
                          label: label,
                          icon: Icons.add_rounded,
                          expand: true,
                          onPressed: () {},
                        ),
                        const SizedBox(height: AppSpacing.s8),
                      ],
                      Wrap(
                        key: const Key('chips'),
                        spacing: AppSpacing.s8,
                        children: <Widget>[
                          AppChip(
                            label: l10n.sampleChipMorning,
                            selected: true,
                            onSelected: (bool on) {},
                          ),
                          AppChip(label: l10n.sampleChipAfternoon, onSelected: (bool on) {}),
                          AppChip(label: l10n.sampleChipBoth, onSelected: (bool on) {}),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.s16),
                      AppTextField(label: l10n.sampleFieldLabel),
                    ],
                  ),
                ),
                for (final String header in headers) AppSectionHeader(header),
                for (final String row in rows)
                  AppListRow(
                    title: row,
                    subtitle: l10n.sampleListSubtitle,
                    leadingIcon: Icons.school_outlined,
                    onTap: () {},
                  ),
                SizedBox(
                  height: stateHeight,
                  child: EmptyStateView(actionLabel: l10n.sampleButtonPrimary, onAction: () {}),
                ),
                SizedBox(height: stateHeight, child: ErrorStateView(onRetry: () {})),
                SizedBox(height: stateHeight, child: OfflineStateView(onRetry: () {})),
              ],
            ),
          ),
        );
      });

      _expectOneLine(find.byType(AppBar), 'app bar title');
      _expectOneLine(find.byType(AppButton), 'buttons');
      _expectOneLine(find.byKey(const Key('chips')), 'chips');
      _expectOneLine(find.byType(AppSectionHeader), 'section headers');
      _expectOneLine(
        find.descendant(of: find.byType(AppTextField), matching: find.byType(OneLineText)),
        'field label',
      );
      _expectOneLine(
        find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)),
        'list row titles',
      );
      // State views: the one-line title and the action button.
      _expectOneLine(
        find.descendant(of: find.byType(AppStateView), matching: find.byType(OneLineText)),
        'state titles and actions',
      );
    });

    testWidgets('[$lang] at 200 percent text, buttons and titles shrink, never cut words', (
      WidgetTester tester,
    ) async {
      _useNarrowPhone(tester, height: 1600, textScale: 2);
      late String confirmTitle;
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        confirmTitle = l10n.sampleConfirmTitle;
        final List<String> buttons = <String>[
          l10n.sampleButtonPrimary,
          l10n.sampleButtonSecondary,
          l10n.sampleButtonDanger,
          l10n.actionRetry,
          l10n.actionConfirm,
        ];
        return Scaffold(
          appBar: AppBar(title: AppBarTitle(l10n.devOpenGallery)),
          body: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final String label in buttons) ...<Widget>[
                  AppButton(
                    label: label,
                    icon: Icons.add_rounded,
                    expand: true,
                    onPressed: () {},
                  ),
                  const SizedBox(height: AppSpacing.s8),
                ],
                Builder(
                  builder: (BuildContext inner) => AppButton(
                    key: const Key('openDialog'),
                    label: l10n.sampleConfirmOpen,
                    onPressed: () => unawaited(
                      showConfirmDialog(
                        context: inner,
                        title: l10n.sampleConfirmTitle,
                        body: l10n.sampleConfirmBody,
                        confirmLabel: l10n.sampleButtonDanger,
                        destructive: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      });

      _expectOneLine(find.byType(AppBarTitle), 'app bar title x2');
      _expectOneLine(find.byType(AppButton), 'buttons x2');
      _expectNotShrunk(find.byType(AppButton), 0.75, 'buttons x2');

      await tester.tap(find.byKey(const Key('openDialog')));
      await tester.pumpAndSettle();
      final Finder dialogTitle = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(confirmTitle),
      );
      _expectOneLine(dialogTitle, 'dialog title x2');
      _expectOneLine(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(AppButton)),
        'dialog buttons x2',
      );
    });

    testWidgets('[$lang] snackbar messages fit one line at 320 dp', (WidgetTester tester) async {
      _useNarrowPhone(tester);
      late int count;
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        final List<String> messages = <String>[
          l10n.sampleDone,
          l10n.devTestErrorSent,
          l10n.devSentryOff,
          l10n.devFunctionTestErrorDone,
          l10n.stateErrorBody,
          // Prompt 2
          l10n.codeSent,
          l10n.emailLinkSent,
          l10n.copiedToClipboard,
          l10n.signOutFailed,
        ];
        count = messages.length;
        return Scaffold(
          body: Builder(
            builder: (BuildContext inner) => Column(
              children: <Widget>[
                for (int i = 0; i < messages.length; i++)
                  TextButton(
                    key: ValueKey<int>(i),
                    onPressed: () => showAppSnackBar(inner, messages[i]),
                    child: const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        );
      });
      expect(count, 9);
      for (int i = 0; i < count; i++) {
        await tester.tap(find.byKey(ValueKey<int>(i)));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        _expectOneLine(find.byType(SnackBar), 'snackbar $i');
      }
    });

    testWidgets('[$lang] Profile tab (settings) fits one line at 320 dp', (
      WidgetTester tester,
    ) async {
      _useNarrowPhone(tester, height: 1600);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            flavorConfigProvider.overrideWithValue(testDevConfig),
            settingsStoreProvider.overrideWithValue(
              InMemorySettingsStore(<String, String>{LocaleController.storageKey: lang}),
            ),
            // A verified parent, so the tabs show (Prompt 2 router gate).
            ...authOverrides(),
          ],
          child: const CarpoolApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.person_outline_rounded));
      await tester.pumpAndSettle();

      _expectOneLine(find.byType(AppBar), 'app bar title');
      _expectOneLine(find.byType(AppNavigationBar), 'tab labels');
      _expectOneLine(find.byType(AppSectionHeader), 'section headers');
      _expectOneLine(
        find.byWidgetPredicate((Widget widget) => widget is SegmentedButton<Object?>),
        'settings options',
      );
      _expectOneLine(
        find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)),
        'account and developer tool rows',
      );
      _expectOneLine(
        find.descendant(of: find.byType(AppCopyValue), matching: find.byType(OneLineText)),
        'parent ID label',
      );
    });

    // Prompt 2: every sign-up screen and Profile, as the router shows them.
    for (final MapEntry<String, (String, SessionState)> screen in _signupScreens.entries) {
      final (String location, SessionState session) = screen.value;
      for (final double textScale in <double>[1, 2]) {
        testWidgets('[$lang] ${screen.key} screen fits one line at 320 dp, text x$textScale', (
          WidgetTester tester,
        ) async {
          _useNarrowPhone(tester, height: 1600, textScale: textScale);
          await _pumpRoute(tester, locale: locale, location: location, session: session);

          // Buttons and titles: one line at any text size, never shrunk to
          // unreadable.
          // Profile builds its list lazily: the sign-out button may not be
          // built at 200 percent text.
          _expectOneLineIfShown(find.byType(AppButton), '${screen.key}: buttons');
          _expectNotShrunk(
            find.byType(AppButton),
            textScale == 1 ? 0.9 : 0.5,
            '${screen.key}: buttons',
          );
          _expectOneLineIfShown(find.byType(AppBarTitle), '${screen.key}: app bar title');
          final Finder stepTitle = find.descendant(
            of: find.byType(OnboardingLayout),
            matching: find.byWidgetPredicate(
              (Widget widget) => widget is OneLineText && widget.scaleDown,
            ),
          );
          _expectOneLineIfShown(stepTitle, '${screen.key}: title and buttons');
          if (textScale == 1) {
            _expectNotShrunk(stepTitle, 0.9, '${screen.key}: title and buttons');
            // At normal text every one-line label fits without an ellipsis.
            _expectOneLine(find.byType(OneLineText), '${screen.key}: labels');
          }
        });
      }
    }

    testWidgets('[$lang] sign-up labels in every state fit one line at 320 dp', (
      WidgetTester tester,
    ) async {
      _useNarrowPhone(tester, height: 4000);
      final List<String> titles = <String>[];
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        // Buttons that some screens show only in one state.
        final List<String> buttons = <String>[
          l10n.welcomeStart,
          l10n.phoneSendCode,
          l10n.codeVerify,
          l10n.codeResend,
          l10n.codeChangeNumber,
          l10n.emailSendLink,
          l10n.emailConfirmed,
          l10n.emailResend,
          l10n.emailChange,
          l10n.actionSignInAgain,
          l10n.termsAcceptButton,
          l10n.verifyOpenProfile,
          l10n.profileSignOut,
          l10n.actionContinue,
        ];
        titles
          ..clear()
          ..addAll(<String>[
            l10n.phoneTitle,
            l10n.codeTitle,
            l10n.emailTitle,
            l10n.emailCheckTitle,
            l10n.termsTitle,
          ]);
        return Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final String title in titles)
                  SizedBox(
                    height: AppSpacing.s64 * 4,
                    child: OnboardingLayout(
                      step: kSignupSteps,
                      title: title,
                      children: const <Widget>[],
                    ),
                  ),
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final String label in buttons) ...<Widget>[
                        AppButton(label: label, expand: true, onPressed: () {}),
                        const SizedBox(height: AppSpacing.s8),
                      ],
                      AppTextField(label: l10n.phoneLabel),
                      AppTextField(label: l10n.emailLabel),
                      AppCodeField(label: l10n.codeLabel, controller: TextEditingController()),
                      AppCheckRow(
                        key: const Key('checkRow'),
                        label: l10n.termsAcceptPrivacy,
                        value: false,
                        onChanged: (bool value) {},
                        actionLabel: l10n.termsRead,
                        onAction: () {},
                      ),
                      AppCopyValue(label: l10n.profileParentIdLabel, value: 'ABCD2345'),
                    ],
                  ),
                ),
                AppSectionHeader(l10n.verifyStepsTitle),
                AppSectionHeader(l10n.profileAccountSection),
                AppListRow(
                  title: l10n.verifyStepId,
                  subtitle: l10n.verifyStepIdDetail,
                  leadingIcon: Icons.badge_outlined,
                ),
                AppListRow(
                  title: l10n.verifyStepSelfie,
                  subtitle: l10n.verifyStepSelfieDetail,
                  leadingIcon: Icons.face_outlined,
                ),
                AppListRow(
                  title: l10n.verifyStepChild,
                  subtitle: l10n.verifyStepChildDetail,
                  leadingIcon: Icons.school_outlined,
                ),
                AppListRow(
                  title: l10n.verifyStepDriver,
                  subtitle: l10n.verifyStepDriverDetail,
                  leadingIcon: Icons.directions_car_outlined,
                ),
                // The Profile status row, with the longest status words.
                for (final AccountStatus status in AccountStatus.values)
                  AppListRow(
                    title: l10n.profileStatus,
                    subtitle: AccountStatusBadge.describe(status, l10n).$1,
                    leadingIcon: AccountStatusBadge.describe(status, l10n).$3,
                  ),
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: Wrap(
                    key: const Key('badges'),
                    spacing: AppSpacing.s8,
                    runSpacing: AppSpacing.s8,
                    children: <Widget>[
                      for (final AccountStatus status in AccountStatus.values)
                        AccountStatusBadge(status: status),
                    ],
                  ),
                ),
                AppListRow(
                  title: l10n.profilePhone,
                  subtitle: '010 0000 0001',
                  leadingIcon: Icons.phone_iphone_rounded,
                ),
              ],
            ),
          ),
        );
      });

      _expectOneLine(find.byType(AppButton), 'sign-up buttons');
      _expectNotShrunk(find.byType(AppButton), 0.9, 'sign-up buttons');
      for (final String title in titles) {
        final Finder text = find.text(title);
        _expectOneLine(text, 'step title');
        _expectNotShrunk(text, 0.9, 'step title');
      }
      _expectOneLine(find.byType(AppStepProgress), 'step progress');
      _expectOneLine(
        find.descendant(of: find.byType(AppTextField), matching: find.byType(OneLineText)),
        'field labels',
      );
      _expectOneLine(
        find.descendant(of: find.byType(AppCodeField), matching: find.byType(OneLineText)),
        'code field label',
      );
      _expectOneLine(
        find.descendant(of: find.byKey(const Key('checkRow')), matching: find.byType(OneLineText)),
        'check row link',
      );
      _expectOneLine(
        find.descendant(of: find.byType(AppCopyValue), matching: find.byType(OneLineText)),
        'parent ID label',
      );
      _expectOneLine(find.byType(AppSectionHeader), 'section headers');
      _expectOneLine(
        find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText)),
        'row titles',
      );
      _expectOneLine(find.byKey(const Key('badges')), 'status badges');
    });

    testWidgets('[$lang] at 200 percent text, sign-up buttons and titles never cut words', (
      WidgetTester tester,
    ) async {
      _useNarrowPhone(tester, height: 2400, textScale: 2);
      late String confirmTitle;
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        confirmTitle = l10n.profileSignOutConfirmTitle;
        final List<String> buttons = <String>[
          l10n.welcomeStart,
          l10n.phoneSendCode,
          l10n.codeVerify,
          l10n.codeResend,
          l10n.codeChangeNumber,
          l10n.emailSendLink,
          l10n.emailConfirmed,
          l10n.emailResend,
          l10n.emailChange,
          l10n.actionSignInAgain,
          l10n.termsAcceptButton,
          l10n.verifyOpenProfile,
          l10n.profileSignOut,
        ];
        return Scaffold(
          appBar: AppBar(title: AppBarTitle(l10n.verifyTitle)),
          body: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final String label in buttons) ...<Widget>[
                  AppButton(label: label, expand: true, onPressed: () {}),
                  const SizedBox(height: AppSpacing.s8),
                ],
                Builder(
                  builder: (BuildContext inner) => AppButton(
                    key: const Key('openSignOut'),
                    label: l10n.profileSignOut,
                    variant: AppButtonVariant.secondary,
                    onPressed: () => unawaited(
                      showConfirmDialog(
                        context: inner,
                        title: l10n.profileSignOutConfirmTitle,
                        body: l10n.profileSignOutConfirmBody,
                        confirmLabel: l10n.profileSignOut,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      });

      _expectOneLine(find.byType(AppBarTitle), 'app bar title x2');
      _expectOneLine(find.byType(AppButton), 'sign-up buttons x2');
      _expectNotShrunk(find.byType(AppButton), 0.5, 'sign-up buttons x2');

      await tester.ensureVisible(find.byKey(const Key('openSignOut')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('openSignOut')));
      await tester.pumpAndSettle();
      _expectOneLine(
        find.descendant(of: find.byType(AlertDialog), matching: find.text(confirmTitle)),
        'sign-out dialog title x2',
      );
    });
  }
}
