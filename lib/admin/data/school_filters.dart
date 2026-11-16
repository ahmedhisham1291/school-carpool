import 'package:flutter/foundation.dart';
import 'package:school_carpool/admin/data/admin_models.dart';

/// Which schools the admin search shows by visibility in the parents' search.
enum SchoolVisibility {
  /// Shown in the parents' search (not hidden).
  inSearch('in_search'),

  /// Taken out of search (the sample schools once a real list is loaded).
  hidden('hidden');

  const SchoolVisibility(this.code);

  final String code;

  static SchoolVisibility? fromCode(String? code) {
    for (final SchoolVisibility v in values) {
      if (v.code == code) {
        return v;
      }
    }
    return null;
  }
}

/// Sort order of the schools list.
enum SchoolSort {
  nameAr('ar', 'nameAr'),
  nameEn('en', 'nameEn');

  const SchoolSort(this.code, this.wire);

  /// In the URL.
  final String code;

  /// What adminSearchSchools takes.
  final String wire;

  static SchoolSort? fromCode(String? code) {
    for (final SchoolSort s in values) {
      if (s.code == code) {
        return s;
      }
    }
    return null;
  }
}

/// Sources the source filter offers (the URL may carry any other one,
/// for example a list file's `list_<name>`).
const List<String> kSchoolSources = <String>['osm', 'wikidata', 'admin', 'parent', 'seed'];

/// The admin schools search: text, City -> Area -> District, and (with
/// [includeAll]) status, visibility and source. Kept in the URL as go_router
/// query parameters so a filtered view can be bookmarked:
/// `/schools?q=nasr&city=cairo&area=a1&district=d1&all=1&status=active&vis=hidden&source=osm&sort=en`.
@immutable
class SchoolFilters {
  const SchoolFilters({
    this.query = '',
    this.city,
    this.areaId,
    this.districtId,
    this.includeAll = false,
    this.status,
    this.visibility,
    this.source,
    this.sort,
  });

  /// Reads the URL. Anything unknown is dropped, and a child without its
  /// parent (an area without a city, a district without an area) too.
  factory SchoolFilters.fromQuery(Map<String, String> q) {
    String? id(String key) {
      final String? v = q[key]?.trim();
      return v != null && _docId.hasMatch(v) ? v : null;
    }

    final String? cityValue = q['city'];
    final String? city = cityValue != null && kGovernorates.contains(cityValue) ? cityValue : null;
    final String? area = city == null ? null : id('area');
    final String? district = area == null ? null : id('district');
    final bool all = q['all'] == '1';
    final String? statusCode = q['status'];
    final String? sourceValue = q['source'];
    final String text = q['q'] ?? '';
    return SchoolFilters(
      query: text.length > maxQueryLength ? text.substring(0, maxQueryLength) : text,
      city: city,
      areaId: area,
      districtId: district,
      includeAll: all,
      status: all && statusCode != null ? SchoolStatus.values.where((SchoolStatus s) => s.code == statusCode).firstOrNull : null,
      visibility: all ? SchoolVisibility.fromCode(q['vis']) : null,
      source: all && sourceValue != null && _source.hasMatch(sourceValue) ? sourceValue : null,
      sort: SchoolSort.fromCode(q['sort']),
    );
  }

  static final RegExp _docId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final RegExp _source = RegExp(r'^[a-z0-9_.-]{1,80}$');

  /// The function refuses longer text.
  static const int maxQueryLength = 80;

  final String query;

  /// Governorate code (City).
  final String? city;
  final String? areaId;
  final String? districtId;

  /// Also hidden, sample, awaiting review and merged schools.
  final bool includeAll;
  final SchoolStatus? status;
  final SchoolVisibility? visibility;
  final String? source;

  /// Null: by the panel's language.
  final SchoolSort? sort;

  /// Sort to use for the panel's [languageCode].
  SchoolSort sortFor(String languageCode) => sort ?? (languageCode == 'ar' ? SchoolSort.nameAr : SchoolSort.nameEn);

  /// Whether anything narrows the list (the "Clear filters" button).
  bool get isFiltered =>
      query.trim().isNotEmpty || city != null || includeAll || status != null || visibility != null || source != null;

  Map<String, String> toQuery() => <String, String>{
    if (query.trim().isNotEmpty) 'q': query.trim(),
    'city': ?city,
    if (city != null) 'area': ?areaId,
    if (areaId != null) 'district': ?districtId,
    if (includeAll) 'all': '1',
    if (includeAll) 'status': ?status?.code,
    if (includeAll) 'vis': ?visibility?.code,
    if (includeAll) 'source': ?source,
    'sort': ?sort?.code,
  };

  /// What adminSearchSchools takes.
  Map<String, Object?> toRequest({required String languageCode, String? afterId}) => <String, Object?>{
    if (query.trim().isNotEmpty) 'query': query.trim(),
    'includeAll': includeAll,
    'governorate': ?city,
    'placeAreaId': ?areaId,
    'placeDistrictId': ?districtId,
    if (includeAll) 'status': ?status?.code,
    if (includeAll) 'visibility': ?visibility?.code,
    if (includeAll) 'source': ?source,
    'sort': sortFor(languageCode).wire,
    'afterId': ?afterId,
  };

  SchoolFilters withQuery(String value) =>
      _copy(query: value.length > maxQueryLength ? value.substring(0, maxQueryLength) : value);

  /// A new city clears its area and district.
  SchoolFilters withCity(String? value) => SchoolFilters(
    query: query,
    city: value,
    includeAll: includeAll,
    status: status,
    visibility: visibility,
    source: source,
    sort: sort,
  );

  /// A new area clears its district.
  SchoolFilters withArea(String? value) => SchoolFilters(
    query: query,
    city: city,
    areaId: value,
    includeAll: includeAll,
    status: status,
    visibility: visibility,
    source: source,
    sort: sort,
  );

  SchoolFilters withDistrict(String? value) => SchoolFilters(
    query: query,
    city: city,
    areaId: areaId,
    districtId: value,
    includeAll: includeAll,
    status: status,
    visibility: visibility,
    source: source,
    sort: sort,
  );

  /// Turning "show all" off drops the filters only it offers.
  SchoolFilters withIncludeAll(bool value) => value
      ? _copy(includeAll: true)
      : SchoolFilters(query: query, city: city, areaId: areaId, districtId: districtId, sort: sort);

  SchoolFilters withStatus(SchoolStatus? value) => SchoolFilters(
    query: query,
    city: city,
    areaId: areaId,
    districtId: districtId,
    includeAll: includeAll,
    status: value,
    visibility: visibility,
    source: source,
    sort: sort,
  );

  SchoolFilters withVisibility(SchoolVisibility? value) => SchoolFilters(
    query: query,
    city: city,
    areaId: areaId,
    districtId: districtId,
    includeAll: includeAll,
    status: status,
    visibility: value,
    source: source,
    sort: sort,
  );

  SchoolFilters withSource(String? value) => SchoolFilters(
    query: query,
    city: city,
    areaId: areaId,
    districtId: districtId,
    includeAll: includeAll,
    status: status,
    visibility: visibility,
    source: value,
    sort: sort,
  );

  SchoolFilters withSort(SchoolSort value) => _copy(sort: value);

  /// Clears every filter; keeps the sort.
  SchoolFilters cleared() => SchoolFilters(sort: sort);

  SchoolFilters _copy({String? query, bool? includeAll, SchoolSort? sort}) => SchoolFilters(
    query: query ?? this.query,
    city: city,
    areaId: areaId,
    districtId: districtId,
    includeAll: includeAll ?? this.includeAll,
    status: status,
    visibility: visibility,
    source: source,
    sort: sort ?? this.sort,
  );

  @override
  bool operator ==(Object other) =>
      other is SchoolFilters &&
      other.query == query &&
      other.city == city &&
      other.areaId == areaId &&
      other.districtId == districtId &&
      other.includeAll == includeAll &&
      other.status == status &&
      other.visibility == visibility &&
      other.source == source &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(query, city, areaId, districtId, includeAll, status, visibility, source, sort);
}

/// One page of adminSearchSchools.
@immutable
class SchoolSearchPage {
  const SchoolSearchPage({
    required this.items,
    required this.nextAfterId,
    this.total,
    this.totalExact = true,
    this.degraded = false,
  });

  final List<School> items;
  final String? nextAfterId;

  /// First page only: how many match; null when unknown.
  final int? total;

  /// false: [total] is a lower bound.
  final bool totalExact;

  /// An index was missing: the search ran in a slower way.
  final bool degraded;
}
