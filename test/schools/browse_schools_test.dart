import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/places/place_repository.dart';
import 'package:school_carpool/features/schools/browse_schools_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/dropdown.dart';
import '../helpers/one_line.dart';
import '../helpers/place_fakes.dart';
import '../helpers/test_app.dart';

Future<FakePlaceRepository> _pump(WidgetTester tester, {Locale locale = AppLocales.english, FakePlaceRepository? repo, double width = 400}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 900 * 2);
  addTearDown(tester.view.reset);
  final FakePlaceRepository places = repo ?? FakePlaceRepository();
  await tester.pumpWidget(
    buildTestApp(const BrowseSchoolsScreen(), locale: locale, extraOverrides: <Override>[...placeOverrides(repository: places)]),
  );
  await tester.pumpAndSettle();
  return places;
}

void main() {
  testWidgets('City -> Area -> the area\'s schools, alphabetical', (WidgetTester tester) async {
    final FakePlaceRepository places = await _pump(tester);
    expect(find.byKey(const Key('browse.hint')), findsOneWidget);
    expect(dropdownEnabled(tester, const Key('browse.area.')), isFalse);

    await pickFromDropdown(tester, const Key('browse.city'), 'Cairo');
    expect(places.calls, contains('areas:cairo'));
    await pickFromDropdown(tester, const Key('browse.area.cairo'), 'Maadi');
    expect(places.calls, contains('schools:osm-r1'));
    // Amal before Zohour (English names in English).
    final double amal = tester.getTopLeft(find.byKey(const Key('browse.school.a'))).dy;
    final double zohour = tester.getTopLeft(find.byKey(const Key('browse.school.z'))).dy;
    expect(amal, lessThan(zohour));
    expect(find.byKey(const Key('browse.school.n')), findsNothing); // Nasr City school
  });

  testWidgets('a new city clears the area and its schools', (WidgetTester tester) async {
    await _pump(tester);
    await pickFromDropdown(tester, const Key('browse.city'), 'Cairo');
    await pickFromDropdown(tester, const Key('browse.area.cairo'), 'Maadi');
    expect(find.byKey(const Key('browse.school.a')), findsOneWidget);
    await pickFromDropdown(tester, const Key('browse.city'), 'Giza');
    expect(dropdownText(tester, const Key('browse.area.giza')), isEmpty);
    expect(find.byKey(const Key('browse.school.a')), findsNothing);
    expect(find.byKey(const Key('browse.hint')), findsOneWidget);
  });

  testWidgets('empty area, city without areas, and offline', (WidgetTester tester) async {
    final FakePlaceRepository places = await _pump(tester);
    await pickFromDropdown(tester, const Key('browse.city'), 'Giza');
    await pickFromDropdown(tester, const Key('browse.area.giza'), 'Sheikh Zayed');
    expect(find.byKey(const Key('browse.empty')), findsOneWidget);

    await pickFromDropdown(tester, const Key('browse.city'), 'Luxor');
    expect(find.text('No areas for this city yet. Use search.'), findsOneWidget);

    places.failure = const PlaceFailure(PlaceFailureKind.offline);
    await pickFromDropdown(tester, const Key('browse.city'), 'Aswan');
    expect(find.byKey(const Key('places.error')), findsOneWidget);
  });

  for (final Locale locale in <Locale>[AppLocales.arabic, AppLocales.english]) {
    testWidgets('labels fit one line at 320 dp (${locale.languageCode})', (WidgetTester tester) async {
      await _pump(tester, locale: locale, width: 320);
      await pickFromDropdown(tester, const Key('browse.city'), locale == AppLocales.arabic ? 'القاهرة' : 'Cairo');
      await pickFromDropdown(tester, const Key('browse.area.cairo'), locale == AppLocales.arabic ? 'المعادي' : 'Maadi');
      expectOneLine(find.byType(AppBarTitle), 'browse title');
      expectOneLine(find.byKey(const Key('browse.city')), 'city dropdown', allowEllipsis: true);
      expectOneLine(find.byKey(const Key('browse.area.cairo')), 'area dropdown', allowEllipsis: true);
      for (final String id in <String>['a', 'z']) {
        expectOneLine(
          find.descendant(of: find.byKey(Key('browse.school.$id')), matching: find.byType(OneLineText)),
          'school row $id',
          allowEllipsis: true,
        );
      }
    });
  }
}
