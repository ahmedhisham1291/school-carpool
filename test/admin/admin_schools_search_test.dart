// Admin panel Schools list (F14): search by name, City -> Area -> District
// filters (dependent dropdowns), "show hidden and unapproved", clear all,
// and the filters in the URL. Written, not run here (no Flutter SDK in the
// build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/school_filters.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/dropdown.dart';
import '../helpers/place_fakes.dart';

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Uri _uri(GoRouter router) => router.routerDelegate.currentConfiguration.uri;

void main() {
  const AdminSessionState signedIn = AdminSignedIn(testReviewer);
  const Size wide = Size(1280, 1400);

  group('SchoolFilters (URL)', () {
    test('round-trips through the query parameters', () {
      const SchoolFilters f = SchoolFilters(
        query: 'النصر',
        city: 'cairo',
        areaId: 'osm-r1',
        districtId: 'osm-n10',
        includeAll: true,
        status: SchoolStatus.awaitingReview,
        visibility: SchoolVisibility.hidden,
        source: 'list_ministry',
        sort: SchoolSort.nameAr,
      );
      expect(SchoolFilters.fromQuery(f.toQuery()), f);
      expect(const SchoolFilters().toQuery(), isEmpty);
    });

    test('drops a child without its parent, unknown values and the "show all" filters without show all', () {
      final SchoolFilters f = SchoolFilters.fromQuery(<String, String>{
        'area': 'osm-r1',
        'district': 'osm-n10',
        'status': 'merged',
        'vis': 'hidden',
        'source': 'osm',
        'sort': 'xx',
        'city': 'atlantis',
      });
      expect(f, const SchoolFilters());
      expect(SchoolFilters.fromQuery(<String, String>{'city': 'cairo', 'district': 'osm-n10'}).districtId, isNull);
      expect(SchoolFilters.fromQuery(<String, String>{'city': 'cairo', 'area': '../x'}).areaId, isNull);
    });

    test('a new city clears area and district; a new area clears the district; clear keeps the sort', () {
      const SchoolFilters f = SchoolFilters(query: 'nile', city: 'cairo', areaId: 'a', districtId: 'd', sort: SchoolSort.nameEn);
      expect(f.withCity('giza'), const SchoolFilters(query: 'nile', city: 'giza', sort: SchoolSort.nameEn));
      expect(f.withArea('b'), const SchoolFilters(query: 'nile', city: 'cairo', areaId: 'b', sort: SchoolSort.nameEn));
      expect(f.cleared(), const SchoolFilters(sort: SchoolSort.nameEn));
      expect(f.cleared().isFiltered, isFalse);
    });

    test('turning "show all" off drops status, visibility and source', () {
      const SchoolFilters f = SchoolFilters(city: 'cairo', includeAll: true, status: SchoolStatus.merged, source: 'osm');
      expect(f.withIncludeAll(false), const SchoolFilters(city: 'cairo'));
    });

    test('the request carries every filter and the sort for the language', () {
      const SchoolFilters f = SchoolFilters(query: ' nile ', city: 'cairo', areaId: 'a1', districtId: 'd1');
      expect(f.toRequest(languageCode: 'en'), <String, Object?>{
        'query': 'nile',
        'includeAll': false,
        'governorate': 'cairo',
        'placeAreaId': 'a1',
        'placeDistrictId': 'd1',
        'sort': 'nameEn',
      });
      expect(f.toRequest(languageCode: 'ar', afterId: 's9')['sort'], 'nameAr');
      expect(f.toRequest(languageCode: 'ar', afterId: 's9')['afterId'], 's9');
    });
  });

  group('Schools screen', () {
    testWidgets('City -> Area -> District are dependent and go to the URL; a new city clears the children', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      final FakeAdminPlacesApi places = FakeAdminPlacesApi();
      final GoRouter router = await pumpAdminPanel(
        tester,
        session: signedIn,
        location: AdminRoutes.schools,
        api: api,
        places: places,
        locale: 'en',
        size: wide,
      );
      await _settle(tester);
      expect(dropdownEnabled(tester, const Key('schools.area.')), isFalse, reason: 'no area before a city');
      expect(dropdownEnabled(tester, const Key('schools.district.')), isFalse);

      await pickFromDropdown(tester, const Key('schools.city'), 'Cairo');
      await _settle(tester);
      expect(_uri(router).queryParameters['city'], 'cairo');
      expect(places.calls, contains('areas:cairo'));
      expect(api.schoolSearches.last.city, 'cairo');

      await pickFromDropdown(tester, const Key('schools.area.cairo'), 'Maadi');
      await _settle(tester);
      expect(_uri(router).queryParameters['area'], 'osm-r1');
      expect(places.calls, contains('districts:osm-r1'));

      await pickFromDropdown(tester, const Key('schools.district.osm-r1'), 'Degla');
      await _settle(tester);
      expect(_uri(router).queryParameters['district'], 'osm-n10');
      expect(api.schoolSearches.last, const SchoolFilters(city: 'cairo', areaId: 'osm-r1', districtId: 'osm-n10'));

      await pickFromDropdown(tester, const Key('schools.city'), 'Giza');
      await _settle(tester);
      expect(_uri(router).queryParameters, <String, String>{'city': 'giza'});
      expect(dropdownText(tester, const Key('schools.area.giza')), 'All areas');
      expect(dropdownText(tester, const Key('schools.district.')), 'All districts');
      expect(api.schoolSearches.last, const SchoolFilters(city: 'giza'));
    });

    testWidgets('a bookmarked URL restores the search and filters', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      await pumpAdminPanel(
        tester,
        session: signedIn,
        location: '/schools?q=nile&city=cairo&area=osm-r1&all=1&status=active&sort=ar',
        api: api,
        locale: 'en',
        size: wide,
      );
      await _settle(tester);
      expect(
        api.schoolSearches.first,
        const SchoolFilters(query: 'nile', city: 'cairo', areaId: 'osm-r1', includeAll: true, status: SchoolStatus.active, sort: SchoolSort.nameAr),
      );
      expect(find.widgetWithText(TextField, 'nile'), findsOneWidget);
      expect(dropdownText(tester, const Key('schools.city')), 'Cairo');
      expect(find.byKey(const Key('schools.status')), findsOneWidget, reason: 'show all is on');
    });

    testWidgets('typing searches after a pause and shows the count and the table', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      final GoRouter router = await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.schools, api: api, locale: 'en', size: wide);
      await _settle(tester);
      final int before = api.schoolSearches.length;
      await tester.enterText(find.byKey(const Key('schools.query')), 'Nile');
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.schoolSearches.length, before, reason: 'waits for the pause');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(_uri(router).queryParameters['q'], 'Nile');
      expect(api.schoolSearches.last.query, 'Nile');
      expect(find.byKey(const Key('schools.count')), findsOneWidget);
      expect(find.text('1 school'), findsOneWidget);
      expect(find.byKey(const Key('schools.s1')), findsOneWidget);
      // The Arabic name reads right to left inside the English panel.
      final Directionality dir = tester.widget<Directionality>(
        find.ancestor(of: find.text('مدرسة النيل (تجريبية)'), matching: find.byType(Directionality)).first,
      );
      expect(dir.textDirection, TextDirection.rtl);
    });

    testWidgets('no match: "No schools match" and clear filters empties the URL', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      final GoRouter router = await pumpAdminPanel(
        tester,
        session: signedIn,
        location: '/schools?q=zzzz&city=cairo',
        api: api,
        locale: 'en',
        size: wide,
      );
      await _settle(tester);
      expect(find.byKey(const Key('schools.noMatch')), findsOneWidget);
      expect(find.text('No schools match'), findsOneWidget);
      await tester.tap(find.text('Clear filters').last);
      await _settle(tester);
      expect(_uri(router).queryParameters, isEmpty);
      expect(api.schoolSearches.last, const SchoolFilters());
      expect(find.byKey(const Key('schools.s1')), findsOneWidget);
    });

    testWidgets('"Show hidden and unapproved" adds the awaiting-review school and the status filter', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi();
      final GoRouter router = await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.schools, api: api, locale: 'en', size: wide);
      await _settle(tester);
      expect(find.byKey(const Key('schools.p1')), findsNothing);
      await tester.tap(find.byKey(const Key('schools.all')));
      await _settle(tester);
      expect(_uri(router).queryParameters['all'], '1');
      expect(find.byKey(const Key('schools.p1')), findsOneWidget);
      await pickFromDropdown(tester, const Key('schools.status'), 'Awaiting review');
      await _settle(tester);
      expect(_uri(router).queryParameters['status'], 'awaiting_review');
      expect(find.byKey(const Key('schools.s1')), findsNothing);
    });

    testWidgets('offline and error states retry', (WidgetTester tester) async {
      final FakeAdminApi api = FakeAdminApi()..failure = const AdminFailure(AdminFailureKind.offline);
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.schools, api: api, locale: 'en', size: wide);
      await _settle(tester);
      expect(find.byType(OfflineStateView), findsOneWidget);
      api.failure = null;
      await tester.tap(find.text('Try again').last);
      await _settle(tester);
      expect(find.byKey(const Key('schools.s1')), findsOneWidget);
    });

    testWidgets('Arabic, narrow: list rows instead of the table', (WidgetTester tester) async {
      await pumpAdminPanel(tester, session: signedIn, location: AdminRoutes.schools, locale: 'ar', size: const Size(600, 1400));
      await _settle(tester);
      expect(find.byKey(const Key('schools.s1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
