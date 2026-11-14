import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/maps/driving_schools_screen.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/location_permission_screen.dart';
import 'package:school_carpool/features/maps/location_service.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_settings_section.dart';
import 'package:school_carpool/features/maps/nearby_parents_screen.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_picker_screen.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/fonts.dart';
import '../helpers/map_fakes.dart';
import '../helpers/one_line.dart';
import '../helpers/school_fakes.dart';
import '../helpers/test_app.dart';
import '../helpers/verification_fakes.dart';

const ChildRecord _nileChild = ChildRecord(
  id: 'c1',
  firstName: 'Adam',
  age: 8,
  grade: Grade.g3,
  schoolName: 'Nile International School',
  status: ReviewStatus.approved,
  schoolId: 'nile',
);

const ChildRecord _pendingChild = ChildRecord(
  id: 'c2',
  firstName: 'Jana',
  age: 6,
  grade: Grade.g1,
  schoolName: 'Orman Experimental Language School',
  status: ReviewStatus.pending,
  schoolId: 'orman',
);

const HomeLocation _savedHome = HomeLocation(location: testHome, label: 'Road 9, Maadi');

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  Locale locale = AppLocales.english,
  FakeMapRepository? maps,
  FakePlacesRepository? places,
  FakeLocationService? location,
  List<ChildRecord> children = const <ChildRecord>[_nileChild],
  double width = 400,
  double height = 900,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, height * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestApp(
      screen,
      locale: locale,
      extraOverrides: <Override>[
        ...authOverrides(maps: maps, places: places, location: location),
        ...verificationOverrides(repository: FakeVerificationRepository(), children: children),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens [screen] from a button so it can pop.
class _Opener extends StatelessWidget {
  const _Opener(this.screen);

  final Widget screen;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('open'),
        onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => screen)),
        child: const Text('open'),
      ),
    ),
  );
}

FirebaseFunctionsException _functionsError(String code, String reason) =>
    FirebaseFunctionsException(code: code, message: reason, details: <String, Object?>{'reason': reason});

void main() {
  setUpAll(loadAppFonts);

  group('home picker (F21)', () {
    testWidgets('with no home yet it opens on Cairo, the parent moves the map and saves', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository();
      await _pump(tester, const _Opener(HomeLocationScreen()), maps: maps);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(find.text('Move the map to put the pin on your home. Other parents only see an area of about 500 m.'), findsOneWidget);
      await tester.drag(find.byKey(const Key('map.surface')), const Offset(-120, 80));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home.save')));
      await tester.pumpAndSettle();

      final GeoPin? saved = maps.savedHome;
      expect(saved, isNotNull);
      expect(Geo.same(saved, Geo.cairo), isFalse);
      expect(Geo.inEgypt(saved!), isTrue);
      expect(find.text('Home saved'), findsOneWidget);
      // Saved and closed.
      expect(find.byType(HomeLocationScreen), findsNothing);
    });

    testWidgets('address search waits for typing, uses one session token, and moves the pin', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository();
      final FakePlacesRepository places = FakePlacesRepository();
      await _pump(tester, const HomeLocationScreen(), maps: maps, places: places);

      await tester.enterText(find.byKey(const Key('home.search')), 'Ma');
      await tester.pump(const Duration(milliseconds: 500));
      expect(places.inputs, isEmpty, reason: 'fewer than 3 letters');
      await tester.enterText(find.byKey(const Key('home.search')), 'Maa');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byKey(const Key('home.search')), 'Maadi');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(places.inputs, <String>['Maadi'], reason: 'debounced: one request');

      await tester.tap(find.byKey(const Key('home.suggestion.fake-maadi')));
      await tester.pumpAndSettle();
      expect(places.tokens.toSet(), hasLength(1), reason: 'autocomplete and details share the session token');
      expect(find.byKey(const Key('home.label')), findsOneWidget);

      await tester.tap(find.byKey(const Key('home.save')));
      await tester.pumpAndSettle();
      expect(Geo.same(maps.savedHome, FakePlacesRepository.maadi.location), isTrue);
      expect(maps.savedLabel, FakePlacesRepository.maadi.label);

      // A new search starts a new session.
      await tester.enterText(find.byKey(const Key('home.search')), 'Maadi 2');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(places.tokens.toSet(), hasLength(2));
    });

    testWidgets('"use my location" explains first, then asks the phone, then moves the pin', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository();
      final FakeLocationService location = FakeLocationService();
      await _pump(tester, const HomeLocationScreen(), maps: maps, location: location);

      await tester.tap(find.byKey(const Key('home.myLocation')));
      await tester.pumpAndSettle();
      expect(find.byType(LocationPermissionScreen), findsOneWidget);
      expect(location.requests, 0, reason: 'our explanation comes before the system prompt');
      await tester.tap(find.byKey(const Key('location.continue')));
      await tester.pumpAndSettle();
      expect(location.requests, 1);

      await tester.tap(find.byKey(const Key('home.save')));
      await tester.pumpAndSettle();
      expect(Geo.same(maps.savedHome, location.here), isTrue);
    });

    testWidgets('"Not now" asks nothing; refused for good opens Settings', (WidgetTester tester) async {
      final FakeLocationService location = FakeLocationService();
      await _pump(tester, const HomeLocationScreen(), location: location);
      await tester.tap(find.byKey(const Key('home.myLocation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location.notNow')));
      await tester.pumpAndSettle();
      expect(location.requests, 0);

      location.accessValue = LocationAccess.deniedForever;
      await tester.tap(find.byKey(const Key('home.myLocation')));
      await tester.pumpAndSettle();
      expect(find.text('Open Settings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location.continue')));
      await tester.pumpAndSettle();
      expect(location.settingsOpened, 1);
      expect(location.requests, 0);
    });

    testWidgets('too many moves: says so and keeps the screen', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome)
        ..failure = const MapFailure(MapFailureKind.rateLimited);
      await _pump(tester, const HomeLocationScreen(), maps: maps);
      expect(find.text('Road 9, Maadi'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home.save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home.error')), findsOneWidget);
      expect(find.text('Too many tries. Try again later.'), findsOneWidget);
    });

    testWidgets('error and offline states with retry', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository()..homeError = StateError('boom');
      await _pump(tester, const HomeLocationScreen(), maps: maps);
      expect(find.byType(ErrorStateView), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      final FakeMapRepository offline = FakeMapRepository()
        ..homeError = _functionsError('unavailable', 'unknown');
      await _pump(tester, const HomeLocationScreen(), maps: offline);
      expect(find.byType(OfflineStateView), findsOneWidget);
    });
  });

  group('nearby parents (F22)', () {
    testWidgets('shows blurred discs only, and a card with first name, Verified, school, Join and Message', (
      WidgetTester tester,
    ) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome);
      await _pump(tester, const NearbyParentsScreen(), maps: maps);

      expect(maps.searches, <(String, int)>[('nile', 3)]);
      expect(find.text('2 parents nearby'), findsOneWidget);
      expect(find.byKey(const Key('map.area.p1')), findsOneWidget);
      expect(find.byKey(const Key('map.area.p2')), findsOneWidget);
      // Other parents are never pins; the only pin is the parent's own home.
      expect(find.byKey(const Key('map.marker.p1')), findsNothing);
      expect(find.byKey(const Key('map.marker.home')), findsOneWidget);
      // F40: the selected school's pin is on the map too.
      expect(find.byKey(const Key('map.marker.school.nile')), findsOneWidget);

      await tester.tap(find.byKey(const Key('map.area.p1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('parent.card.p1')), findsOneWidget);
      expect(find.text('Hoda'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Nile International School'), findsWidgets);
      // Prompt 9: Message sends a private chat request and closes the card.
      await tester.tap(find.byKey(const Key('parent.message')));
      await tester.pumpAndSettle();
      expect(find.text('Request sent to Hoda'), findsOneWidget);
      expect(find.byKey(const Key('parent.card.p1')), findsNothing);
      // Join (Prompt 6) closes the card and opens that parent's carpools
      // (router test in test/carpools/carpool_screens_test.dart).
      await tester.tap(find.byKey(const Key('map.area.p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('parent.join')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('parent.card.p1')), findsNothing);
    });

    testWidgets('list view shows the same parents', (WidgetTester tester) async {
      await _pump(tester, const NearbyParentsScreen(), maps: FakeMapRepository(home: _savedHome));
      await tester.tap(find.byKey(const Key('nearby.toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nearby.row.p1')), findsOneWidget);
      expect(find.byKey(const Key('nearby.row.p2')), findsOneWidget);
    });

    testWidgets('the radius slider searches again and is remembered', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome);
      await _pump(tester, const NearbyParentsScreen(), maps: maps);
      await tester.tap(find.byKey(const Key('nearby.radiusChip')));
      await tester.pumpAndSettle();
      // Slide to the far end (LTR in English): 10 km.
      await tester.drag(find.byKey(const Key('nearby.radiusSlider')), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nearby.radiusValue')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('nearby.radiusValue')), matching: find.text('10 km')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nearby.radiusDone')));
      await tester.pumpAndSettle();
      expect(maps.searches.last, ('nile', 10));
      expect(maps.calls, contains('updateSettings:null:null:10'));
    });

    testWidgets('only approved children\'s schools and driving schools can be searched', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome);
      await _pump(tester, const NearbyParentsScreen(), maps: maps, children: const <ChildRecord>[_pendingChild]);
      expect(find.byKey(const Key('nearby.noSchool')), findsOneWidget);
      expect(maps.searches, isEmpty);
    });

    testWidgets('no home yet: asks for it first and searches nothing', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository();
      await _pump(tester, const NearbyParentsScreen(), maps: maps);
      expect(find.byKey(const Key('nearby.noHome')), findsOneWidget);
      expect(maps.searches, isEmpty);
    });

    testWidgets('nobody nearby, too many searches and offline', (WidgetTester tester) async {
      await _pump(
        tester,
        const NearbyParentsScreen(),
        maps: FakeMapRepository(home: _savedHome, parents: const <NearbyParent>[]),
      );
      expect(find.byKey(const Key('nearby.empty')), findsOneWidget);
      expect(find.text('Widen distance'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pump(
        tester,
        const NearbyParentsScreen(),
        maps: FakeMapRepository(home: _savedHome)..nearbyFailure = const MapFailure(MapFailureKind.rateLimited),
      );
      expect(find.byKey(const Key('nearby.limited')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pump(
        tester,
        const NearbyParentsScreen(),
        maps: FakeMapRepository(home: _savedHome)..nearbyFailure = const MapFailure(MapFailureKind.offline),
      );
      expect(find.byType(OfflineStateView), findsOneWidget);
    });

    testWidgets('a hidden parent is told they are hidden and can still search', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(
        home: const HomeLocation(location: testHome, showOnMap: false),
      );
      await _pump(tester, const NearbyParentsScreen(), maps: maps);
      expect(find.byKey(const Key('nearby.hidden')), findsOneWidget);
      expect(maps.searches, hasLength(1));
    });
  });

  group('settings and driving schools', () {
    testWidgets('hide me from the map and new-parent alerts save at once', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome);
      await _pump(tester, const Scaffold(body: SingleChildScrollView(child: MapSettingsSection())), maps: maps);
      await tester.tap(find.byKey(const Key('settings.showOnMap')));
      await tester.pumpAndSettle();
      expect(maps.calls, contains('updateSettings:false:null:null'));
      expect(find.text("You're hidden. You can still search and join."), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings.newParentAlerts')));
      await tester.pumpAndSettle();
      expect(maps.calls, contains('updateSettings:null:false:null'));
    });

    testWidgets('a failed save puts the switch back', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome)
        ..failure = const MapFailure(MapFailureKind.offline);
      await _pump(tester, const Scaffold(body: SingleChildScrollView(child: MapSettingsSection())), maps: maps);
      await tester.tap(find.byKey(const Key('settings.showOnMap')));
      await tester.pumpAndSettle();
      final Switch s = tester.widget<Switch>(
        find.descendant(of: find.byKey(const Key('settings.showOnMap')), matching: find.byType(Switch)),
      );
      expect(s.value, isTrue);
      expect(find.text('No connection. Try again.'), findsOneWidget);
    });

    testWidgets('driving schools: children\'s schools listed, add from the picker, remove', (WidgetTester tester) async {
      final FakeMapRepository maps = FakeMapRepository(home: _savedHome);
      await _pump(tester, const DrivingSchoolsScreen(), maps: maps);
      expect(find.byKey(const Key('driving.child.nile')), findsOneWidget);
      expect(find.byKey(const Key('driving.empty')), findsOneWidget);

      await tester.tap(find.byKey(const Key('driving.add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('school.search')), 'Orman');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('school.result.orman')));
      await tester.pumpAndSettle();
      expect(maps.calls, contains('setDrivingSchools:orman'));
      expect(find.byKey(const Key('driving.school.orman')), findsOneWidget);

      await tester.tap(find.byKey(const Key('driving.remove.orman')));
      await tester.pumpAndSettle();
      expect(maps.calls.last, 'setDrivingSchools:');
    });
  });

  group('school picker with a home (F40)', () {
    testWidgets('nearest schools first, and pick one on the map', (WidgetTester tester) async {
      final FakeSchoolSearch search = FakeSchoolSearch();
      SchoolOption? picked;
      tester.view
        ..devicePixelRatio = 2
        ..physicalSize = const Size(800, 1800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        buildTestApp(
          Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () async => picked = await openSchoolPicker(context),
                child: const Text('open'),
              ),
            ),
          ),
          locale: AppLocales.english,
          extraOverrides: <Override>[
            ...authOverrides(maps: FakeMapRepository(home: _savedHome)),
            ...schoolOverrides(search: search),
          ],
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      expect(search.nearestCalls, hasLength(1));
      expect(find.text('Nearest to your home'), findsOneWidget);
      final double nile = tester.getTopLeft(find.byKey(const Key('school.result.nile'))).dy;
      final double orman = tester.getTopLeft(find.byKey(const Key('school.result.orman'))).dy;
      expect(nile, lessThan(orman), reason: 'Maadi is nearer to the home than Dokki');

      await tester.tap(find.byKey(const Key('school.mapToggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map.marker.home')), findsOneWidget);
      await tester.tap(find.byKey(const Key('map.marker.nile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('school.mapChoose')));
      await tester.pumpAndSettle();
      expect(picked?.id, 'nile');
    });
  });

  group('one line at 320 dp', () {
    Finder oneLineIn(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.byType(OneLineText));

    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;

      testWidgets('[$lang] home picker and location screen', (WidgetTester tester) async {
        await _pump(tester, const HomeLocationScreen(), locale: locale, width: 320, height: 720);
        expectOneLine(find.byType(AppBarTitle), 'home title');
        expectOneLine(oneLineIn('home.search'), 'search label');
        expectOneLine(oneLineIn('home.save'), 'save');
        await tester.tap(find.byKey(const Key('home.myLocation')));
        await tester.pumpAndSettle();
        expectOneLine(find.byType(AppBarTitle), 'location title');
        expectOneLine(oneLineIn('location.continue'), 'continue');
        expectOneLine(oneLineIn('location.notNow'), 'not now');
      });

      testWidgets('[$lang] nearby map, chips, card and radius sheet', (WidgetTester tester) async {
        await _pump(tester, const NearbyParentsScreen(), locale: locale, maps: FakeMapRepository(home: _savedHome), width: 320, height: 720);
        expectOneLine(find.byType(AppBarTitle), 'nearby title');
        expectOneLine(find.byKey(const Key('nearby.radiusChip')), 'radius chip');
        // A school name is data: a long one may end in an ellipsis but never wraps.
        expectOneLine(find.byKey(const Key('nearby.schoolChip')), 'school chip', allowEllipsis: true);
        await tester.tap(find.byKey(const Key('map.area.p1')));
        await tester.pumpAndSettle();
        expectOneLine(oneLineIn('parent.join'), 'join');
        expectOneLine(oneLineIn('parent.message'), 'message');
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nearby.radiusChip')));
        await tester.pumpAndSettle();
        expectOneLine(find.byKey(const Key('nearby.radiusValue')), 'radius value');
        expectOneLine(oneLineIn('nearby.radiusDone'), 'apply');
      });

      testWidgets('[$lang] nearby empty states', (WidgetTester tester) async {
        await _pump(tester, const NearbyParentsScreen(), locale: locale, width: 320, height: 720);
        expectOneLine(find.descendant(of: find.byKey(const Key('nearby.noHome')), matching: find.byType(OneLineText)), 'no home');
        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          const NearbyParentsScreen(),
          locale: locale,
          maps: FakeMapRepository(home: _savedHome, parents: const <NearbyParent>[]),
          width: 320,
          height: 720,
        );
        expectOneLine(find.descendant(of: find.byKey(const Key('nearby.empty')), matching: find.byType(OneLineText)), 'empty');
      });

      testWidgets('[$lang] settings switches and driving schools', (WidgetTester tester) async {
        await _pump(tester, const DrivingSchoolsScreen(), locale: locale, maps: FakeMapRepository(home: _savedHome), width: 320, height: 720);
        expectOneLine(find.byType(AppBarTitle), 'driving title');
        expectOneLine(find.byType(AppSectionHeader), 'sections');
        expectOneLine(oneLineIn('driving.add'), 'add');
        expectOneLine(oneLineIn('driving.child.nile'), 'child school');

        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          const Scaffold(body: SingleChildScrollView(child: MapSettingsSection())),
          locale: locale,
          maps: FakeMapRepository(home: _savedHome),
          width: 320,
        );
        expectOneLine(oneLineIn('settings.showOnMap'), 'show on map');
        expectOneLine(oneLineIn('settings.newParentAlerts'), 'alerts');
        expectOneLine(find.byType(AppSectionHeader), 'map section');
      });
    }
  });
}
