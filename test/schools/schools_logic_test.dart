import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/schools/other_school_screen.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/schools/school_search.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';

import '../helpers/school_fakes.dart';

void main() {
  group('normalizeText (same cases as the server and the import tool)', () {
    test('Arabic forms, diacritics, tatweel and digits', () {
      expect(normalizeText('مَدْرَسَةُ'), 'مدرسه');
      expect(normalizeText('أحمد إبراهيم آمال ٱلنور'), 'احمد ابراهيم امال النور');
      expect(normalizeText('مستشفى'), 'مستشفي');
      expect(normalizeText('مدرســـة'), 'مدرسه');
      expect(normalizeText('مدرسة ٦ أكتوبر'), 'مدرسه 6 اكتوبر');
      expect(normalizeText("  St. Mark's   College "), 'st mark s college');
      expect(normalizeText('مدرسة النيل الدولية'), normalizeText('مدرسه النيل الدوليه'));
    });

    test('one-letter differences', () {
      expect(withinOneEdit('victoria', 'victorai'), isFalse);
      expect(withinOneEdit('victoria', 'victoira'), isFalse);
      expect(withinOneEdit('college', 'collage'), isTrue);
      expect(withinOneEdit('nile', 'niles'), isTrue);
      expect(withinOneEdit('nile', 'nle'), isTrue);
      expect(withinOneEdit('nile', 'lie'), isFalse);
    });
  });

  group('SchoolMatcher (fake search and own pending schools)', () {
    final SchoolMatcher matcher = SchoolMatcher(testSchools);
    List<String> ids(String q, {String? governorate}) =>
        matcher.search(q, governorate: governorate).map((SchoolOption s) => s.id).toList();

    test('finds part of a name in Arabic or English', () {
      expect(ids('النيل'), <String>['nile']);
      expect(ids('نيل'), <String>['nile']);
      expect(ids('Nile'), <String>['nile']);
      expect(ids('vict'), <String>['victoria']);
      expect(ids('مدرسه الاورمان'), <String>['orman']);
    });

    test('tolerates spelling differences', () {
      expect(ids('الدوليه'), <String>['nile']);
      expect(ids('Victorya'), <String>['victoria']);
      expect(ids('فكتوريا'), <String>['victoria']);
      expect(ids('Intrnasional'), isEmpty, reason: 'two letters wrong is too far');
    });

    test('matches the place too, and filters by governorate', () {
      expect(ids('المعادي'), <String>['nile']);
      expect(ids('school'), <String>['orman', 'nile']);
      expect(ids('school', governorate: 'giza'), <String>['orman']);
      expect(ids('Nile', governorate: 'giza'), isEmpty);
    });

    test('every word must match; empty queries find nothing', () {
      expect(ids('Nile Victoria'), isEmpty);
      expect(ids('   '), isEmpty);
    });
  });

  group('SchoolOption', () {
    test('name and place in the app language, falling back to the other', () {
      const SchoolOption s = SchoolOption(id: 'x', nameAr: 'مدرسة', nameEn: '', governorate: 'cairo', city: 'Maadi');
      expect(s.name('en'), 'مدرسة');
      expect(s.name('ar'), 'مدرسة');
      expect(s.place('ar'), 'Maadi');
      expect(SchoolOption.fromMap('p1', const <String, Object?>{'nameAr': 'x', 'status': 'awaiting_review'}).pending, isTrue);
    });
  });

  group('AlgoliaSchoolSearch', () {
    test('sends the query, limit and governorate filter with the secured key; reads names and places', () async {
      final List<(Uri, Map<String, String>, String)> sent = <(Uri, Map<String, String>, String)>[];
      int keys = 0;
      DateTime now = DateTime(2026, 11, 13, 10);
      final AlgoliaSchoolSearch search = AlgoliaSchoolSearch(
        fetchKey: () async {
          keys++;
          return SearchKey(
            provider: 'algolia',
            appId: 'APP',
            indexName: 'schools',
            key: 'secured-$keys',
            validUntil: now.add(const Duration(hours: 1)),
          );
        },
        transport: (Uri url, Map<String, String> headers, String body) async {
          sent.add((url, headers, body));
          return <String, Object?>{
            'hits': <Object?>[
              <String, Object?>{'objectID': 'osm-n1', 'nameAr': 'مدرسة النيل', 'nameEn': 'Nile School', 'governorate': 'cairo'},
              <String, Object?>{'nameAr': 'no id'},
            ],
          };
        },
        now: () => now,
      );
      final List<SchoolOption> found = await search.search(' nile ', governorate: 'cairo');
      expect(found.single.id, 'osm-n1');
      expect(found.single.pending, isFalse);
      final (Uri url, Map<String, String> headers, String body) = sent.single;
      expect(url.toString(), 'https://APP-dsn.algolia.net/1/indexes/schools/query');
      expect(headers['X-Algolia-API-Key'], 'secured-1');
      final String params = (jsonDecode(body) as Map<String, Object?>)['params']! as String;
      expect(Uri.splitQueryString(params), <String, String>{'query': 'nile', 'hitsPerPage': '20', 'filters': 'governorate:cairo'});

      // The key is reused, then fetched again shortly before it expires.
      await search.search('nile');
      expect(keys, 1);
      now = now.add(const Duration(minutes: 59, seconds: 30));
      await search.search('nile');
      expect(keys, 2);
      expect(sent.last.$2['X-Algolia-API-Key'], 'secured-2');
    });

    test('the server picks the fake search until Algolia is set up', () async {
      final FakeSchoolSearch fake = FakeSchoolSearch();
      final ServerSelectedSchoolSearch search = ServerSelectedSchoolSearch(
        fetchKey: () async => const SearchKey(provider: 'fake'),
        fallback: fake,
      );
      expect((await search.search('Nile')).single.id, 'nile');
      expect(fake.queries.single, ('Nile', null));
    });
  });

  group('"Other" school', () {
    test('name rule matches the server', () {
      expect(isValidSchoolName('مدرسة الزهور'), isTrue);
      expect(isValidSchoolName("St. Mary's School (Zamalek)"), isTrue);
      expect(isValidSchoolName('ab'), isFalse);
      expect(isValidSchoolName('...'), isFalse);
      expect(isValidSchoolName('<b>School</b>'), isFalse);
      expect(isValidSchoolName('x' * 121), isFalse);
    });

    test('server reasons become messages the parent can act on', () {
      OtherSchoolFailureKind kind(String reason, [String code = 'invalid-argument']) => OtherSchoolFailure.from(
        FirebaseFunctionsException(message: reason, code: code, details: <String, Object?>{'reason': reason}),
      ).kind;
      expect(kind('invalid-name'), OtherSchoolFailureKind.invalidName);
      expect(kind('invalid-location'), OtherSchoolFailureKind.invalidPin);
      expect(kind('too-many-pending', 'resource-exhausted'), OtherSchoolFailureKind.tooMany);
      expect(kind('suspended', 'permission-denied'), OtherSchoolFailureKind.suspended);
      expect(
        OtherSchoolFailure.from(FirebaseFunctionsException(message: 'x', code: 'unavailable')).kind,
        OtherSchoolFailureKind.offline,
      );
      expect(OtherSchoolFailure.from(Exception('x')).kind, OtherSchoolFailureKind.unknown);
    });
  });
}
