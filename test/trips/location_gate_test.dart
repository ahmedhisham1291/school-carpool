// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/home/home_screen.dart';
import 'package:school_carpool/features/trips/location_gate.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/fonts.dart';
import '../helpers/one_line.dart';
import '../helpers/test_app.dart';

Future<void> _pumpHome(WidgetTester tester, FakeDrivingReadiness readiness, {Locale locale = AppLocales.english, double width = 400, double textScale = 1}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 2400 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(buildTestApp(const HomeScreen(), locale: locale, extraOverrides: authOverrides(readiness: readiness)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  group('home banner (other parents, never blocks)', () {
    testWidgets('hidden when location is fine (also with notifications off)', (WidgetTester tester) async {
      final FakeDrivingReadiness readiness = FakeDrivingReadiness(current: const DrivingCheck(notificationsOff: true));
      addTearDown(readiness.dispose);
      await _pumpHome(tester, readiness);
      expect(find.byKey(const Key('home.locationBanner')), findsNothing);
      expect(find.byKey(const Key('home.nearby')), findsOneWidget);
    });

    for (final GateItem item in <GateItem>[GateItem.service, GateItem.permission, GateItem.precise]) {
      testWidgets('shown when ${item.name} is missing; the steps show location items only', (WidgetTester tester) async {
        final FakeDrivingReadiness readiness = FakeDrivingReadiness(current: DrivingCheck(missing: <GateItem>{item}, notificationsOff: true));
        addTearDown(readiness.dispose);
        await _pumpHome(tester, readiness);
        expect(find.byKey(const Key('home.locationBanner')), findsOneWidget);
        expect(find.text('Location is off'), findsOneWidget);
        expect(find.text('Needed on your driving day.'), findsOneWidget);

        await tester.tap(find.text('Steps'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('gate.screen')), findsOneWidget);
        expect(find.text('Turn on location'), findsOneWidget);
        expect(find.byKey(Key('gate.item.${item.name}')), findsOneWidget);

        // Fixed in Settings: back in the app the steps close and the banner goes.
        readiness.current = const DrivingCheck(notificationsOff: true);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('gate.screen')), findsNothing);
        expect(find.byKey(const Key('home.locationBanner')), findsNothing);
      });
    }

    testWidgets('the steps can be closed; the app stays usable', (WidgetTester tester) async {
      final FakeDrivingReadiness readiness = FakeDrivingReadiness(current: const DrivingCheck(missing: <GateItem>{GateItem.permission}));
      addTearDown(readiness.dispose);
      await _pumpHome(tester, readiness);
      await tester.tap(find.text('Steps'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gate.openSettings')));
      await tester.pumpAndSettle();
      expect(readiness.settingsOpened, 1);
      await tester.tap(find.byKey(const Key('gate.close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gate.screen')), findsNothing);
      expect(find.byKey(const Key('home.locationBanner')), findsOneWidget);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('[${locale.languageCode}] banner and steps at text x$scale', (WidgetTester tester) async {
          final bool normal = scale == 1;
          final FakeDrivingReadiness readiness = FakeDrivingReadiness(
            current: const DrivingCheck(missing: <GateItem>{GateItem.service, GateItem.permission, GateItem.precise}, notificationsOff: true),
          );
          addTearDown(readiness.dispose);
          await _pumpHome(tester, readiness, locale: locale, width: 320, textScale: scale);
          expectOneLine(find.descendant(of: find.byKey(const Key('home.locationBanner')), matching: find.byType(OneLineText)), 'banner title', allowEllipsis: !normal);
          await tester.tap(find.descendant(of: find.byKey(const Key('home.locationBanner')), matching: find.byType(AppButton)));
          await tester.pumpAndSettle();
          expectOneLine(find.byType(AppBarTitle), 'steps title');
          expectOneLine(find.byType(AppButton), 'steps button', allowEllipsis: !normal);
          for (final GateItem item in <GateItem>[GateItem.service, GateItem.permission, GateItem.precise]) {
            expectOneLine(find.descendant(of: find.byKey(Key('gate.item.${item.name}')), matching: find.byType(OneLineText)), 'item ${item.name}', allowEllipsis: !normal);
          }
        });
      }

      testWidgets('[${locale.languageCode}] every gate label fits on one line', (WidgetTester tester) async {
        tester.view
          ..devicePixelRatio = 2
          ..physicalSize = const Size(640, 2400);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          buildTestApp(
            Builder(
              builder: (BuildContext context) {
                final AppLocalizations l10n = context.l10n;
                return Column(
                  children: <Widget>[
                    for (final String label in <String>[
                      l10n.gateTitle,
                      l10n.gateLocationTitle,
                      l10n.gateServiceTitle,
                      l10n.gatePermissionTitle,
                      l10n.gatePreciseTitle,
                      l10n.gateNotifWarnTitle,
                      l10n.gateNotifWarnContinue,
                      l10n.locationBannerTitle,
                      l10n.locationBannerAction,
                      l10n.locationOpenSettings,
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: OneLineText(label, style: Theme.of(context).textTheme.titleMedium),
                      ),
                  ],
                );
              },
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expectOneLine(find.byType(OneLineText), 'gate labels');
      });
    }
  });
}
