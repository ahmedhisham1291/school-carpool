import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';

/// A school whose nearby map the parent may open: a child's school
/// (approved children only, as the server counts them) or a driving school.
@immutable
class MySchool {
  const MySchool({required this.school, required this.fromChild});

  /// A child's school carries the name saved with the child in both fields.
  final SchoolRef school;
  final bool fromChild;

  String get id => school.id;

  String name(String languageCode) => school.name(languageCode);
}

/// The schools the nearby map can filter by (same rule as the server's
/// searchNearbyParents: children's schools plus driving schools).
List<MySchool> mySchools(List<ChildRecord> children, HomeLocation? home) {
  final Map<String, MySchool> out = <String, MySchool>{};
  for (final ChildRecord c in children) {
    if (c.status == ReviewStatus.approved && c.schoolId.isNotEmpty) {
      out.putIfAbsent(
        c.schoolId,
        () => MySchool(school: SchoolRef(id: c.schoolId, nameAr: c.schoolName, nameEn: c.schoolName), fromChild: true),
      );
    }
  }
  for (final SchoolRef s in home?.drivingSchools ?? const <SchoolRef>[]) {
    out.putIfAbsent(s.id, () => MySchool(school: s, fromChild: false));
  }
  return out.values.toList();
}

/// Loads both inputs of [mySchools]: data, loading or the first error.
final Provider<AsyncValue<List<MySchool>>> mySchoolsProvider = Provider<AsyncValue<List<MySchool>>>((Ref ref) {
  final AsyncValue<List<ChildRecord>> children = ref.watch(childrenProvider);
  final AsyncValue<HomeLocation?> home = ref.watch(myHomeProvider);
  if (children is AsyncError<List<ChildRecord>>) {
    return AsyncError<List<MySchool>>(children.error, children.stackTrace);
  }
  if (home is AsyncError<HomeLocation?>) {
    return AsyncError<List<MySchool>>(home.error, home.stackTrace);
  }
  final List<ChildRecord>? c = children.value;
  if (c == null || !home.hasValue) {
    return const AsyncLoading<List<MySchool>>();
  }
  return AsyncData<List<MySchool>>(mySchools(c, home.value));
});
