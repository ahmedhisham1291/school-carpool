// F46 address steps with fake places and a fake address service. Written,
// not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/features/places/address_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/dropdown.dart';
import '../helpers/one_line.dart';
import '../helpers/place_fakes.dart';
import '../helpers/test_app.dart';

Future<FakeAddressRepository> _pump(
  WidgetTester tester, {
  Locale locale = AppLocales.english,
  FakeAddressRepository? address,
  HomeLocation? home,
  double width = 400,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 900 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final FakeAddressRepository repo = address ?? FakeAddressRepository();
  await tester.pumpWidget(
    buildTestApp(const AddressScreen(), locale: locale, extraOverrides: <Override>[...addressOverrides(address: repo, home: home)]),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _fillPlace(WidgetTester tester) async {
  await pickFromDropdown(tester, const Key('address.city'), 'Cairo');
  await pickFromDropdown(tester, const Key('address.area.cairo'), 'Maadi');
  await pickFromDropdown(tester, const Key('address.district.osm-r1'), 'Degla');
}

void main() {
  testWidgets('Area waits for City and District for Area', (WidgetTester tester) async {
    await _pump(tester);
    expect(find.text('Step 1 of 3'), findsOneWidget);
    expect(dropdownEnabled(tester, const Key('address.area.')), isFalse);
    expect(dropdownEnabled(tester, const Key('address.district.')), isFalse);
    await pickFromDropdown(tester, const Key('address.city'), 'Cairo');
    expect(dropdownEnabled(tester, const Key('address.area.cairo')), isTrue);
    expect(dropdownEnabled(tester, const Key('address.district.')), isFalse);
    await pickFromDropdown(tester, const Key('address.area.cairo'), 'Maadi');
    expect(dropdownEnabled(tester, const Key('address.district.osm-r1')), isTrue);
  });

  testWidgets('a new City clears Area and District; a new Area clears District', (WidgetTester tester) async {
    await _pump(tester);
    await _fillPlace(tester);
    expect(dropdownText(tester, const Key('address.district.osm-r1')), 'Degla');

    await pickFromDropdown(tester, const Key('address.area.cairo'), 'Nasr City');
    expect(dropdownText(tester, const Key('address.area.cairo')), 'Nasr City');
    expect(dropdownText(tester, const Key('address.district.osm-r2')), isEmpty);

    await pickFromDropdown(tester, const Key('address.city'), 'Giza');
    expect(dropdownText(tester, const Key('address.area.giza')), isEmpty);
    expect(dropdownText(tester, const Key('address.district.')), isEmpty);
    expect(dropdownEnabled(tester, const Key('address.district.')), isFalse);
  });

  testWidgets('"My district isn\'t listed" asks for its name, checked as typed', (WidgetTester tester) async {
    await _pump(tester);
    await pickFromDropdown(tester, const Key('address.city'), 'Cairo');
    await pickFromDropdown(tester, const Key('address.area.cairo'), 'Maadi');
    await pickFromDropdown(tester, const Key('address.district.osm-r1'), "My district isn't listed");
    expect(find.byKey(const Key('address.districtText')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('address.districtText')), 'x');
    await tester.pump();
    expect(find.textContaining('at least 2'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('address.districtText')), 'New District');
    await tester.pump();
    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 3'), findsOneWidget);
  });

  testWidgets('Next says what is missing instead of moving on', (WidgetTester tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();
    expect(find.text('Choose the city.'), findsOneWidget);
    expect(find.text('Step 1 of 3'), findsOneWidget);
  });

  testWidgets('street and building are checked; then the pin is found and saved', (WidgetTester tester) async {
    final FakeAddressRepository repo = await _pump(tester);
    await _fillPlace(tester);
    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('address.next2')));
    await tester.pumpAndSettle();
    expect(find.text('Required.'), findsNWidgets(2));
    await tester.enterText(find.byKey(const Key('address.building')), '-1');
    await tester.pump();
    expect(find.textContaining('Digits and letters only'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('address.street')), 'Road 9');
    await tester.enterText(find.byKey(const Key('address.building')), '12B');
    await tester.enterText(find.byKey(const Key('address.landmark')), 'Opposite the pharmacy');
    await tester.pump();
    await tester.tap(find.byKey(const Key('address.next2')));
    await tester.pumpAndSettle();

    expect(find.text('Step 3 of 3'), findsOneWidget);
    expect(repo.geocoded.single.placeDistrictId, 'osm-n10');
    expect(repo.geocoded.single.street, 'Road 9');
    expect(find.text('Move the map if the pin is not on your building.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('address.save')));
    await tester.pumpAndSettle();
    final (HomeAddress saved, GeoPin pin) = repo.saved.single;
    expect(saved.building, '12B');
    expect(saved.landmark, 'Opposite the pharmacy');
    expect(pin, const GeoPin(29.9602, 31.2569));
  });

  testWidgets('nothing found: the pin starts at the district and says to move it', (WidgetTester tester) async {
    final FakeAddressRepository repo = FakeAddressRepository()..found = null;
    await _pump(tester, address: repo);
    await _fillPlace(tester);
    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('address.street')), 'Road 9');
    await tester.enterText(find.byKey(const Key('address.building')), '12');
    await tester.pump();
    await tester.tap(find.byKey(const Key('address.next2')));
    await tester.pumpAndSettle();
    expect(find.textContaining("couldn't find the exact place"), findsOneWidget);
  });

  testWidgets('back goes to the previous step, not out of the screen', (WidgetTester tester) async {
    await _pump(tester);
    await _fillPlace(tester);
    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 3'), findsOneWidget);
    final NavigatorState navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 3'), findsOneWidget);
    expect(dropdownText(tester, const Key('address.district.osm-r1')), 'Degla');
  });

  testWidgets('editing starts from the saved address', (WidgetTester tester) async {
    await _pump(
      tester,
      home: const HomeLocation(
        location: GeoPin(29.96, 31.25),
        address: HomeAddress(governorate: 'cairo', placeAreaId: 'osm-r1', placeDistrictId: 'osm-n11', street: 'Road 9', building: '12'),
      ),
    );
    expect(dropdownText(tester, const Key('address.city')), 'Cairo');
    expect(dropdownText(tester, const Key('address.area.cairo')), 'Maadi');
    expect(dropdownText(tester, const Key('address.district.osm-r1')), 'Sarayat El Maadi');
  });

  for (final Locale locale in <Locale>[AppLocales.arabic, AppLocales.english]) {
    for (final double scale in <double>[1, 2]) {
      testWidgets('one line at 320 dp, text x$scale (${locale.languageCode})', (WidgetTester tester) async {
        await _pump(tester, locale: locale, width: 320, textScale: scale);
        expectOneLine(find.byType(AppBarTitle), 'address title');
        expectOneLine(find.byKey(const Key('address.next1')), 'next button');
        expectOneLine(find.byKey(const Key('address.search')), 'search instead');
        expectOneLine(find.byKey(const Key('address.city')), 'city dropdown', allowEllipsis: true);
      });
    }
  }
}
