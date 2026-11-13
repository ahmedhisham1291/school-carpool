// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI: `flutter test`.
//
// The one-line rule (CLAUDE.md DESIGN, docs/DESIGN.md): every tab, button,
// chip, title and label fits on one line in Arabic and English on a 320 dp
// wide phone. Real fonts are loaded so text has its true width.

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/l10n/l10n.dart';
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

/// Pumps [build] inside our theme and locale and returns once it is laid out.
Future<void> _pumpContent(
  WidgetTester tester,
  Locale locale,
  WidgetBuilder build,
) async {
  await tester.pumpWidget(buildTestApp(Builder(builder: build), locale: locale));
  await tester.pump();
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
          appBar: AppBar(title: OneLineText(l10n.galleryTitle)),
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

    testWidgets('[$lang] snackbar messages fit one line at 320 dp', (WidgetTester tester) async {
      _useNarrowPhone(tester);
      await _pumpContent(tester, locale, (BuildContext context) {
        final AppLocalizations l10n = context.l10n;
        final List<String> messages = <String>[
          l10n.sampleDone,
          l10n.devTestErrorSent,
          l10n.devSentryOff,
          l10n.devFunctionTestErrorDone,
          l10n.stateErrorBody,
        ];
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
      for (int i = 0; i < 5; i++) {
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
        'developer tool rows',
      );
    });
  }
}
