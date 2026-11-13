import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/admin/data/admin_models.dart' show GeoPin;
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/schools/school_search.dart';

/// A few schools for widget tests (names of real schools, fake IDs).
const List<SchoolOption> testSchools = <SchoolOption>[
  SchoolOption(
    id: 'nile',
    nameAr: 'مدرسة النيل الدولية',
    nameEn: 'Nile International School',
    governorate: 'cairo',
    city: 'Maadi',
    cityAr: 'المعادي',
  ),
  SchoolOption(
    id: 'victoria',
    nameAr: 'كلية فيكتوريا',
    nameEn: 'Victoria College',
    governorate: 'alexandria',
    city: 'Alexandria',
    cityAr: 'الإسكندرية',
  ),
  SchoolOption(
    id: 'orman',
    nameAr: 'مدرسة الأورمان التجريبية للغات',
    nameEn: 'Orman Experimental Language School',
    governorate: 'giza',
    city: 'Dokki',
    cityAr: 'الدقي',
  ),
];

/// Answers from [schools], or fails with [failure] while it is set.
class FakeSchoolSearch implements SchoolSearch {
  FakeSchoolSearch([List<SchoolOption> schools = testSchools]) : _inner = InMemorySchoolSearch(schools);

  final InMemorySchoolSearch _inner;
  final List<(String, String?)> queries = <(String, String?)>[];
  SchoolSearchFailure? failure;

  @override
  Future<List<SchoolOption>> search(String query, {String? governorate}) async {
    queries.add((query, governorate));
    final SchoolSearchFailure? f = failure;
    if (f != null) {
      throw f;
    }
    return _inner.search(query, governorate: governorate);
  }
}

/// Records "Other" schools and streams them as the parent's pending list.
class FakeSchoolRepository implements SchoolRepository {
  final List<SchoolOption> added = <SchoolOption>[];
  final StreamController<List<SchoolOption>> _pending = StreamController<List<SchoolOption>>.broadcast();
  OtherSchoolFailure? failure;
  List<SchoolOption> initialPending = const <SchoolOption>[];

  @override
  Future<SchoolOption> addOther({required String name, required String governorate, GeoPin? pin}) async {
    final OtherSchoolFailure? f = failure;
    if (f != null) {
      throw f;
    }
    final SchoolOption school = SchoolOption(
      id: 'other-${added.length + 1}',
      nameAr: name,
      nameEn: name,
      governorate: governorate,
      pending: true,
    );
    added.add(school);
    _pending.add(<SchoolOption>[...initialPending, ...added]);
    return school;
  }

  @override
  Stream<List<SchoolOption>> pending(String uid) async* {
    yield <SchoolOption>[...initialPending, ...added];
    yield* _pending.stream;
  }

  Future<void> dispose() => _pending.close();
}

/// Overrides that keep Firebase and Algolia out of widget tests.
List<Override> schoolOverrides({SchoolSearch? search, SchoolRepository? repository}) => <Override>[
  schoolSearchProvider.overrideWithValue(search ?? FakeSchoolSearch()),
  schoolRepositoryProvider.overrideWithValue(repository ?? FakeSchoolRepository()),
];
