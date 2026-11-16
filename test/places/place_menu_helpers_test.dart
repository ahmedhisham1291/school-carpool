// A child place menu says why it cannot open (owner, 16 Nov 2026): "Choose a
// city first", "No areas for this city yet", "No districts for this area
// yet", in the admin Schools search, the app's browse and the address
// form; a city with no areas lets the parent go on in the address form.
// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/features/places/address_screen.dart';
import 'package:school_carpool/features/schools/browse_schools_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/dropdown.dart';
import '../helpers/place_fakes.dart';
import '../helpers/test_app.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpApp(WidgetTester tester, Widget screen, {Locale locale = AppLocales.english, FakeAddressRepository? address}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = const Size(320 * 2, 900 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestApp(
      screen,
      locale: locale,
      // addressOverrides carries the places too (one override per provider).
      extraOverrides: <Override>[if (address != null) ...addressOverrides(address: address) else ...placeOverrides()],
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('admin Schools search: helpers instead of silently disabled Area and District', (WidgetTester tester) async {
    await pumpAdminPanel(
      tester,
      session: const AdminSignedIn(testReviewer),
      location: AdminRoutes.schools,
      api: FakeAdminApi(),
      places: FakeAdminPlacesApi(),
      locale: 'en',
      size: const Size(1280, 1400),
    );
    await _settle(tester);
    expect(find.text('Choose a city first'), findsNWidgets(2));
    await pickFromDropdown(tester, const Key('schools.city'), 'Luxor');
    await _settle(tester);
    expect(find.text('No areas for this city yet'), findsOneWidget);
    expect(find.text('Choose an area first'), findsOneWidget);
    expect(dropdownEnabled(tester, const Key('schools.area.luxor')), isFalse);
  });

  testWidgets('app browse: "Choose a city first", then "No areas for this city yet" (Arabic too)', (WidgetTester tester) async {
    await _pumpApp(tester, const BrowseSchoolsScreen());
    expect(find.text('Choose a city first'), findsOneWidget);
    await pickFromDropdown(tester, const Key('browse.city'), 'Luxor');
    expect(find.text('No areas for this city yet'), findsOneWidget);

    await _pumpApp(tester, const BrowseSchoolsScreen(), locale: AppLocales.arabic);
    expect(find.text('اختر المدينة أولاً'), findsOneWidget);
  });

  testWidgets('address form: a city with no areas goes on with an optional typed district', (WidgetTester tester) async {
    final FakeAddressRepository repo = FakeAddressRepository();
    await _pumpApp(tester, const AddressScreen(), address: repo);
    expect(find.text('Choose a city first'), findsNWidgets(2));
    await pickFromDropdown(tester, const Key('address.city'), 'Luxor');
    expect(find.text('No areas for this city yet'), findsOneWidget);
    expect(find.byKey(const Key('address.districtFree')), findsOneWidget);
    expect(find.byKey(const Key('address.district.')), findsNothing);

    await tester.tap(find.byKey(const Key('address.next1')));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 3'), findsOneWidget, reason: 'no area and no district are needed here');

    await tester.enterText(find.byKey(const Key('address.street')), 'Karnak Street');
    await tester.enterText(find.byKey(const Key('address.building')), '12');
    await tester.pump();
    await tester.tap(find.byKey(const Key('address.next2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address.save')));
    await tester.pumpAndSettle();
    final (HomeAddress saved, GeoPin _) = repo.saved.single;
    expect((saved.governorate, saved.placeAreaId, saved.placeDistrictId), ('luxor', '', null));
  });

  testWidgets('address form: an area with no districts says so, and "not listed" stays', (WidgetTester tester) async {
    await _pumpApp(tester, const AddressScreen(), address: FakeAddressRepository());
    await pickFromDropdown(tester, const Key('address.city'), 'Cairo');
    await pickFromDropdown(tester, const Key('address.area.cairo'), 'Nasr City');
    expect(find.text('No districts for this area yet'), findsOneWidget);
    expect(dropdownEnabled(tester, const Key('address.district.osm-r2')), isTrue);
  });

  test('a stored address without an area (a city with none) is read back', () {
    final HomeAddress? a = HomeAddress.fromMap(<String, Object?>{'governorate': 'luxor', 'placeAreaId': '', 'street': 'Karnak Street', 'building': '12'});
    expect(a?.placeAreaId, '');
    expect(HomeAddress.fromMap(<String, Object?>{'placeAreaId': ''}), isNull);
  });
}
