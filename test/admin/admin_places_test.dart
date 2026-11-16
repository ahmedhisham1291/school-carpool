// Admin panel Places (F4 City -> Area -> District, F46 district requests)
// with fake functions. Written, not run here (no Flutter SDK in the build
// workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/dropdown.dart';
import '../helpers/place_fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const AdminSessionState signedIn = AdminSignedIn(testReviewer);

  testWidgets('a city lists its areas with counts; an area lists its districts', (WidgetTester tester) async {
    final FakeAdminPlacesApi places = FakeAdminPlacesApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.places, places: places, locale: 'en');
    await _settle(tester);
    expect(find.byKey(const Key('places.hint')), findsOneWidget);
    await pickFromDropdown(tester, const Key('places.city'), 'Cairo');
    await _settle(tester);
    expect(places.calls, contains('areas:cairo'));
    expect(find.byKey(const Key('places.area.osm-r1')), findsOneWidget);
    expect(find.textContaining('4 schools · 2 addresses'), findsWidgets);
    await tester.tap(find.byKey(const Key('places.area.osm-r1')));
    await _settle(tester);
    expect(places.calls, contains('districts:osm-r1'));
    expect(find.byKey(const Key('places.district.osm-n10')), findsOneWidget);
  });

  testWidgets('rename an area through the actions menu', (WidgetTester tester) async {
    final FakeAdminPlacesApi places = FakeAdminPlacesApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.places, places: places, locale: 'en');
    await _settle(tester);
    await pickFromDropdown(tester, const Key('places.city'), 'Cairo');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('places.menu.osm-r2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('placeName.en')), 'Nasr City East');
    await tester.pump();
    await tester.tap(find.byKey(const Key('placeName.save')));
    await _settle(tester);
    expect(places.calls, contains('saveArea:osm-r2:مدينة نصر:Nasr City East:'));
  });

  testWidgets('deactivating asks first', (WidgetTester tester) async {
    final FakeAdminPlacesApi places = FakeAdminPlacesApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.places, places: places, locale: 'en');
    await _settle(tester);
    await pickFromDropdown(tester, const Key('places.city'), 'Cairo');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('places.menu.osm-r1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deactivate').last);
    await tester.pumpAndSettle();
    expect(find.text('Deactivate this place?'), findsOneWidget);
    expect(places.calls.where((String c) => c.startsWith('setActive')), isEmpty);
    await tester.tap(find.text('Deactivate').last);
    await _settle(tester);
    expect(places.calls, contains('setActive:area:osm-r1:false'));
  });

  testWidgets('a typed district can be dismissed after a confirmation', (WidgetTester tester) async {
    final FakeAdminPlacesApi places = FakeAdminPlacesApi();
    await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.places, places: places, locale: 'en');
    await _settle(tester);
    await tester.tap(find.byKey(const Key('places.tab.requests')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('places.request.q1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('places.requestMenu.q1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss').last);
    await _settle(tester);
    expect(places.calls, contains('resolve:q1:dismiss:::'));
  });
}
