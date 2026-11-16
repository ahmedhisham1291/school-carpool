// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/home/home_screen.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/privacy_fakes.dart';
import '../helpers/test_app.dart';

Future<void> _pump(
  WidgetTester tester, {
  required InMemorySettingsStore store,
  required RecordingAnalyticsSink sink,
  required FakePrivacyRepository repo,
  Locale locale = AppLocales.english,
  double width = 400,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 2400 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestApp(
      const HomeScreen(),
      locale: locale,
      store: store,
      extraOverrides: <Override>[
        ...authOverrides(),
        analyticsSinkProvider.overrideWithValue(sink),
        privacyRepositoryProvider.overrideWithValue(repo),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('usage statistics: asked once, off until yes (guideline 5.1.1(ii))', () {
    testWidgets('never answered: the card shows, nothing is collected, the rest of Home works', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      await _pump(tester, store: store, sink: sink, repo: FakePrivacyRepository());
      expect(find.byKey(const Key('analyticsAsk.card')), findsOneWidget);
      expect(find.text('Help improve the app?'), findsOneWidget);
      expect(find.byKey(const Key('home.nearby')), findsOneWidget, reason: 'never blocks');
      expect(sink.enabled, isNot(true));
      expect(sink.events, isEmpty);
      expect(sink.screens, isEmpty);
    });

    testWidgets('Share: statistics on, saved, the card is gone for good', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      final FakePrivacyRepository repo = FakePrivacyRepository();
      await _pump(tester, store: store, sink: sink, repo: repo);
      await tester.tap(find.byKey(const Key('analyticsAsk.yes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analyticsAsk.card')), findsNothing);
      expect(AnalyticsConsent.read(store), isTrue);
      expect(sink.enabled, isTrue);
      expect(find.text('Statistics on'), findsOneWidget);
      expect(repo.calls, contains('setConsent:analytics:true'), reason: 'the consent record on the server');
      // A new start of the app: not asked again.
      await _pump(tester, store: store, sink: sink, repo: repo);
      expect(find.byKey(const Key('analyticsAsk.card')), findsNothing);
    });

    testWidgets('No thanks: statistics stay off, the card is gone for good', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final RecordingAnalyticsSink sink = RecordingAnalyticsSink();
      await _pump(tester, store: store, sink: sink, repo: FakePrivacyRepository());
      await tester.tap(find.byKey(const Key('analyticsAsk.no')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analyticsAsk.card')), findsNothing);
      expect(AnalyticsConsent.read(store), isFalse);
      expect(AnalyticsConsent.answered(store), isTrue);
      expect(sink.enabled, isFalse);
      expect(sink.events, isEmpty);
    });

    for (final Locale locale in AppLocales.supported) {
      testWidgets('[${locale.languageCode}] the title and both buttons fit on one line at 320 dp', (WidgetTester tester) async {
        await _pump(tester, store: InMemorySettingsStore(), sink: RecordingAnalyticsSink(), repo: FakePrivacyRepository(), locale: locale, width: 320);
        final Finder card = find.byKey(const Key('analyticsAsk.card'));
        expectOneLine(find.descendant(of: card, matching: find.byType(OneLineText)), 'title');
        expectOneLine(find.descendant(of: card, matching: find.byType(AppButton)), 'buttons');
      });
    }
  });

  test('ConsentKind.analytics is still switchable on the privacy screen', () {
    expect(ConsentKind.analytics.switchable, isTrue);
  });
}
