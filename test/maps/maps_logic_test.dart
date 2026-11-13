import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart' show GeoPoint;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_style.dart';
import 'package:school_carpool/features/maps/my_schools.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_search.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

import '../helpers/school_fakes.dart';

void main() {
  group('map style from tokens', () {
    test('is valid JSON built from the theme colors and follows light and dark', () {
      String styleFor(Brightness b) {
        final ThemeData theme = AppTheme.build(DesignDirection.a, b);
        return mapStyleJson(theme.colorScheme, theme.extension<AppColors>()!);
      }

      final String light = styleFor(Brightness.light);
      final String dark = styleFor(Brightness.dark);
      expect(jsonDecode(light), isA<List<Object?>>());
      expect(light, isNot(dark));
      final ThemeData lightTheme = AppTheme.build(DesignDirection.a, Brightness.light);
      expect(light, contains(mapHex(lightTheme.colorScheme.surface)));
      expect(light, contains(mapHex(lightTheme.colorScheme.primaryContainer)));
      // Businesses and transit are hidden: our markers are the only accents.
      expect(light, contains('"featureType":"poi","stylers":[{"visibility":"off"}]'));
      expect(mapHex(const Color(0xFF0E5E58)), '#0e5e58');
    });
  });

  group('models', () {
    test('home from Firestore', () {
      final HomeLocation home = HomeLocation.fromMap(<String, Object?>{
        'location': const GeoPoint(29.96, 31.25),
        'label': 'Road 9',
        'showOnMap': false,
        'radiusKm': 5,
        'drivingSchools': <Object?>[
          <String, Object?>{'id': 'orman', 'nameAr': 'الأورمان', 'nameEn': 'Orman'},
          <String, Object?>{'nameAr': 'no id'},
        ],
      });
      expect(Geo.same(home.location, const GeoPin(29.96, 31.25)), isTrue);
      expect(home.showOnMap, isFalse);
      expect(home.notifyNewParents, isTrue);
      expect(home.radiusKm, 5);
      expect(home.drivingSchools, const <SchoolRef>[SchoolRef(id: 'orman', nameAr: 'الأورمان', nameEn: 'Orman')]);
      expect(HomeLocation.fromMap(const <String, Object?>{}).hasHome, isFalse);
    });

    test('failures from the functions', () {
      MapFailure from(String code, String reason, [int retry = 0]) => MapFailure.from(
        FirebaseFunctionsException(
          code: code,
          message: reason,
          details: <Object?, Object?>{'reason': reason, 'retryAfterSeconds': retry},
        ),
      );
      final MapFailure limited = from('resource-exhausted', 'rate-limited', 600);
      expect(limited.kind, MapFailureKind.rateLimited);
      expect(limited.retryAfter, const Duration(minutes: 10));
      expect(from('permission-denied', 'not-verified').kind, MapFailureKind.notVerified);
      expect(from('failed-precondition', 'no-home').kind, MapFailureKind.noHome);
      expect(from('invalid-argument', 'outside-egypt').kind, MapFailureKind.outsideEgypt);
      expect(from('unavailable', 'x').isOffline, isTrue);
      expect(MapFailure.from(StateError('x')).kind, MapFailureKind.unknown);
    });

    test('session tokens look like UUIDs and pass the server check', () {
      final String a = newPlacesSessionToken(math.Random(1));
      final String b = newPlacesSessionToken(math.Random(2));
      expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')));
      expect(a, isNot(b));
    });
  });

  group('geo', () {
    test('distance and Egypt', () {
      final double km = Geo.distanceKm(const GeoPin(30.0444, 31.2357), const GeoPin(31.2001, 29.9187));
      expect(km, closeTo(180, 5));
      expect(Geo.inEgypt(Geo.cairo), isTrue);
      expect(Geo.inEgypt(const GeoPin(48.85, 2.35)), isFalse);
      expect(Geo.radiusChoicesKm, contains(Geo.defaultRadiusKm));
    });
  });

  group('my schools (map filter)', () {
    ChildRecord child(String id, String school, ReviewStatus status) => ChildRecord(
      id: id,
      firstName: 'A',
      age: 8,
      grade: Grade.g3,
      schoolName: 'School $school',
      status: status,
      schoolId: school,
    );

    test('approved children\'s schools and driving schools, once each', () {
      final List<MySchool> schools = mySchools(
        <ChildRecord>[
          child('c1', 'nile', ReviewStatus.approved),
          child('c2', 'nile', ReviewStatus.approved),
          child('c3', 'orman', ReviewStatus.pending),
        ],
        const HomeLocation(
          drivingSchools: <SchoolRef>[
            SchoolRef(id: 'victoria', nameAr: 'فيكتوريا', nameEn: 'Victoria'),
            SchoolRef(id: 'nile', nameAr: 'النيل', nameEn: 'Nile'),
          ],
        ),
      );
      expect(schools.map((MySchool s) => s.id), <String>['nile', 'victoria']);
      expect(schools.first.fromChild, isTrue);
      expect(schools.last.name('ar'), 'فيكتوريا');
    });
  });

  group('schools with pins (F40)', () {
    test('a school\'s pin comes from Firestore or from Algolia', () {
      expect(
        Geo.same(SchoolOption.fromMap('a', const <String, Object?>{'location': GeoPoint(30, 31)}).location, const GeoPin(30, 31)),
        isTrue,
      );
      expect(
        Geo.same(
          SchoolOption.fromMap('a', <String, Object?>{
            '_geoloc': <String, Object?>{'lat': 30.5, 'lng': 31.5},
          }).location,
          const GeoPin(30.5, 31.5),
        ),
        isTrue,
      );
      expect(SchoolOption.fromMap('a', const <String, Object?>{}).location, isNull);
    });

    test('nearest first, schools without a pin left out', () async {
      final InMemorySchoolSearch search = InMemorySchoolSearch(<SchoolOption>[
        ...testSchools,
        const SchoolOption(id: 'nopin', nameAr: 'بلا', nameEn: 'No pin', governorate: 'cairo'),
      ]);
      final List<SchoolOption> near = await search.nearest(const GeoPin(29.96123, 31.25671));
      expect(near.map((SchoolOption s) => s.id), <String>['nile', 'orman', 'victoria']);
    });

    test('Algolia nearest is one geo search with no text', () async {
      final List<String> bodies = <String>[];
      final AlgoliaSchoolSearch search = AlgoliaSchoolSearch(
        fetchKey: () async => SearchKey(
          provider: 'algolia',
          appId: 'APP',
          indexName: 'schools',
          key: 'k',
          validUntil: DateTime.now().add(const Duration(hours: 1)),
        ),
        transport: (Uri url, Map<String, String> headers, String body) async {
          bodies.add(body);
          return <String, Object?>{
            'hits': <Object?>[
              <String, Object?>{
                'objectID': 'nile',
                'nameAr': 'النيل',
                'nameEn': 'Nile',
                'governorate': 'cairo',
                '_geoloc': <String, Object?>{'lat': 29.96, 'lng': 31.25},
              },
            ],
          };
        },
      );
      final List<SchoolOption> found = await search.nearest(const GeoPin(29.9, 31.2));
      expect(found.single.id, 'nile');
      expect(found.single.location, isNotNull);
      final String params = (jsonDecode(bodies.single) as Map<String, Object?>)['params'] as String;
      final Map<String, String> q = Uri.splitQueryString(params);
      expect(q['query'], '');
      expect(q['aroundLatLng'], '29.9,31.2');
      expect(q['aroundRadius'], 'all');
    });
  });
}
