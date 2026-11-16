import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/firebase/callable_error.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Carpools (F5, F6, F25, F26, F31, F32, F36, F39). Codes match
/// functions/src/carpools/model.ts. Everything here is read from Firestore
/// or returned by Cloud Functions; the app never writes it.

String _text(Object? value) => value is String ? value : '';

String? _textOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;

int _int(Object? value) => value is num ? value.toInt() : 0;

List<Object?> _list(Object? value) => value is List<Object?> ? value : const <Object?>[];

Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const <Object?, Object?>{};

DateTime? _date(Object? value) => switch (value) {
  final Timestamp t => t.toDate(),
  final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
  _ => null,
};

/// Days of the week, Saturday first as in Egypt. School days are Sunday to Thursday.
enum Weekday {
  sat,
  sun,
  mon,
  tue,
  wed,
  thu,
  fri;

  static const List<Weekday> schoolDays = <Weekday>[sun, mon, tue, wed, thu];

  static List<Weekday> listFrom(Object? value) {
    final List<Object?> raw = _list(value);
    return Weekday.values.where((Weekday d) => raw.contains(d.name)).toList();
  }
}

/// F36: the fixed list of rules (codes shared with the server).
enum CarpoolRule {
  noSmoking('no_smoking'),
  mothersOnly('mothers_only'),
  seatBelts('seat_belts'),
  childSeats('child_seats'),
  wait5Min('wait_5_min'),
  noPhone('no_phone'),
  noFood('no_food'),
  girlsOnly('girls_only');

  const CarpoolRule(this.code);

  final String code;

  static List<CarpoolRule> listFrom(Object? value) {
    final List<Object?> raw = _list(value);
    return CarpoolRule.values.where((CarpoolRule r) => raw.contains(r.code)).toList();
  }
}

enum ContributionPeriod {
  trip,
  week,
  month;

  static ContributionPeriod? fromName(Object? name) {
    for (final ContributionPeriod p in values) {
      if (p.name == name) {
        return p;
      }
    }
    return null;
  }
}

enum CarpoolKind { school, activity }

enum MembershipStatus {
  requested,
  approved,
  declined,
  left;

  static MembershipStatus? fromName(Object? name) {
    for (final MembershipStatus s in values) {
      if (s.name == name) {
        return s;
      }
    }
    return null;
  }
}

/// F25: optional amount per child, agreed between parents. The app never takes it.
@immutable
class Contribution {
  const Contribution({required this.amount, required this.period, this.note = ''});

  static Contribution? fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    final Object? amount = m['amount'];
    final ContributionPeriod? period = ContributionPeriod.fromName(m['period']);
    if (amount is! num || period == null) {
      return null;
    }
    return Contribution(amount: amount.toInt(), period: period, note: _text(m['note']));
  }

  /// Whole Egyptian pounds per child.
  final int amount;
  final ContributionPeriod period;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{'amount': amount, 'period': period.name, 'note': note};
}

/// "HH:MM" helpers. Times are local Cairo times as the parents agreed them.
abstract final class RunTime {
  static int? minutes(String? time) {
    if (time == null) {
      return null;
    }
    final RegExpMatch? m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(time);
    return m == null ? null : int.parse(m[1]!) * 60 + int.parse(m[2]!);
  }

  static String fromMinutes(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

  /// Choices for a run time: every 15 minutes from [from] to [to] (same bounds as the server).
  static List<String> choices({int from = 6 * 60, int to = 18 * 60}) => <String>[
    for (int m = from; m <= to; m += 15) fromMinutes(m),
  ];

  static const String defaultMorning = '07:30';
  static const String defaultAfternoon = '14:30';
}

/// carpools/{id}: the public summary every verified parent may read by ID,
/// or one search result (searchCarpools), which adds [seatsLeft],
/// [myStatus] and [distanceKm].
@immutable
class Carpool {
  const Carpool({
    required this.id,
    required this.kind,
    required this.schoolId,
    required this.schoolNameAr,
    required this.schoolNameEn,
    required this.areaNameAr,
    required this.areaNameEn,
    required this.activityName,
    required this.activityLabel,
    required this.morning,
    required this.afternoon,
    required this.days,
    required this.seats,
    required this.childrenCount,
    required this.memberCount,
    required this.rules,
    required this.contribution,
    required this.creatorFirstName,
    this.areaId,
    this.active = true,
    this.myStatus,
    this.distanceKm,
  });

  factory Carpool.fromDoc(String id, Map<String, Object?> d) {
    final Map<Object?, Object?> activity = _map(d['activity']);
    final int seats = _int(d['seats']);
    return Carpool(
      id: id,
      kind: d['kind'] == 'activity' ? CarpoolKind.activity : CarpoolKind.school,
      schoolId: _text(d['schoolId']),
      schoolNameAr: _text(d['schoolNameAr']),
      schoolNameEn: _text(d['schoolNameEn']),
      areaId: _textOrNull(d['areaId']),
      areaNameAr: _text(d['areaNameAr']),
      areaNameEn: _text(d['areaNameEn']),
      activityName: _text(activity['name']),
      activityLabel: _text(activity['label']),
      morning: _textOrNull(d['morning']),
      afternoon: _textOrNull(d['afternoon']),
      days: Weekday.listFrom(d['days']),
      seats: seats,
      childrenCount: _int(d['childrenCount']),
      memberCount: _int(d['memberCount']),
      rules: CarpoolRule.listFrom(d['rules']),
      contribution: Contribution.fromMap(d['contribution']),
      creatorFirstName: _text(d['creatorFirstName']),
      active: d['status'] != 'closed',
    );
  }

  /// One result of searchCarpools.
  factory Carpool.fromSearch(Map<Object?, Object?> m) {
    final int seats = _int(m['seats']);
    final Object? km = m['distanceKm'];
    return Carpool(
      id: _text(m['id']),
      kind: m['kind'] == 'activity' ? CarpoolKind.activity : CarpoolKind.school,
      schoolId: _text(m['schoolId']),
      schoolNameAr: _text(m['schoolNameAr']),
      schoolNameEn: _text(m['schoolNameEn']),
      areaId: _textOrNull(m['areaId']),
      areaNameAr: _text(m['areaNameAr']),
      areaNameEn: _text(m['areaNameEn']),
      activityName: _text(m['activityName']),
      activityLabel: _text(m['activityLabel']),
      morning: _textOrNull(m['morning']),
      afternoon: _textOrNull(m['afternoon']),
      days: Weekday.listFrom(m['days']),
      seats: seats,
      childrenCount: seats - _int(m['seatsLeft']),
      memberCount: _int(m['memberCount']),
      rules: CarpoolRule.listFrom(m['rules']),
      contribution: Contribution.fromMap(m['contribution']),
      creatorFirstName: _text(m['creatorFirstName']),
      myStatus: MembershipStatus.fromName(m['myStatus']),
      distanceKm: km is num ? km.toInt() : null,
    );
  }

  final String id;
  final CarpoolKind kind;
  final String schoolId;
  final String schoolNameAr;
  final String schoolNameEn;
  final String? areaId;
  final String areaNameAr;
  final String areaNameEn;
  final String activityName;
  final String activityLabel;
  final String? morning;
  final String? afternoon;
  final List<Weekday> days;

  /// Children the carpool carries per run (at most a driver's passenger seats).
  final int seats;
  final int childrenCount;
  final int memberCount;
  final List<CarpoolRule> rules;
  final Contribution? contribution;
  final String creatorFirstName;
  final bool active;
  final MembershipStatus? myStatus;
  final int? distanceKm;

  int get seatsLeft => seats - childrenCount < 0 ? 0 : seats - childrenCount;

  /// The school or the activity, in the app's language.
  String title(String languageCode) {
    if (kind == CarpoolKind.activity) {
      return activityName;
    }
    final String preferred = languageCode == 'ar' ? schoolNameAr : schoolNameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? schoolNameEn : schoolNameAr);
  }

  String areaName(String languageCode) {
    final String preferred = languageCode == 'ar' ? areaNameAr : areaNameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? areaNameEn : areaNameAr);
  }
}

/// A child as other members see it: first name and grade only.
@immutable
class CarpoolChild {
  const CarpoolChild({required this.id, required this.firstName, required this.grade});

  factory CarpoolChild.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return CarpoolChild(id: _text(m['id']), firstName: _text(m['firstName']), grade: Grade.fromName(m['grade']));
  }

  final String id;
  final String firstName;
  final Grade? grade;
}

List<CarpoolChild> _children(Object? value) => <CarpoolChild>[
  for (final Object? c in _list(value)) CarpoolChild.fromMap(c),
];

/// A member's car as others need it: passenger seats and validity.
@immutable
class CarpoolCar {
  const CarpoolCar({required this.seats, required this.validUntil});

  static CarpoolCar? fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    final Object? seats = m['seats'];
    final DateTime? until = parseIsoDate(m['validUntil']);
    return seats is num && until != null ? CarpoolCar(seats: seats.toInt(), validUntil: until) : null;
  }

  final int seats;
  final DateTime validUntil;
}

/// carpools/{id}/members/{uid}.
@immutable
class CarpoolMember {
  const CarpoolMember({
    required this.uid,
    required this.firstName,
    required this.children,
    this.isAdmin = false,
    this.car,
    this.drivingDays = const <Weekday>[],
    this.pickupShared = false,
  });

  factory CarpoolMember.fromDoc(String uid, Map<String, Object?> d) => CarpoolMember(
    uid: uid,
    firstName: _text(d['firstName']),
    children: _children(d['children']),
    isAdmin: d['role'] == 'admin',
    car: CarpoolCar.fromMap(d['car']),
    drivingDays: Weekday.listFrom(d['drivingDays']),
    pickupShared: d['pickupShared'] == true,
  );

  final String uid;
  final String firstName;
  final List<CarpoolChild> children;
  final bool isAdmin;
  final CarpoolCar? car;
  final List<Weekday> drivingDays;
  final bool pickupShared;
}

/// carpools/{id}/requests/{uid}: seen by the admin before deciding.
@immutable
class JoinRequest {
  const JoinRequest({required this.uid, required this.firstName, required this.children, this.hasCar = false, this.requestedAt});

  factory JoinRequest.fromDoc(String uid, Map<String, Object?> d) => JoinRequest(
    uid: uid,
    firstName: _text(d['firstName']),
    children: _children(d['children']),
    hasCar: CarpoolCar.fromMap(d['car']) != null,
    requestedAt: _date(d['requestedAt']),
  );

  final String uid;
  final String firstName;
  final List<CarpoolChild> children;
  final bool hasCar;
  final DateTime? requestedAt;
}

/// carpools/{id}/driverConsents/{parentUid}_{driverUid} (F26).
@immutable
class DriverConsent {
  const DriverConsent({required this.parentUid, required this.driverUid, required this.accepted});

  factory DriverConsent.fromDoc(Map<String, Object?> d) =>
      DriverConsent(parentUid: _text(d['parentUid']), driverUid: _text(d['driverUid']), accepted: d['status'] == 'accepted');

  final String parentUid;
  final String driverUid;
  final bool accepted;
}

/// memberships/{carpoolId}_{uid}: the parent's own.
@immutable
class Membership {
  const Membership({required this.carpoolId, required this.status, this.isAdmin = false});

  factory Membership.fromDoc(Map<String, Object?> d) => Membership(
    carpoolId: _text(d['carpoolId']),
    status: MembershipStatus.fromName(d['status']) ?? MembershipStatus.left,
    isAdmin: d['role'] == 'admin',
  );

  final String carpoolId;
  final MembershipStatus status;
  final bool isAdmin;

  bool get isActive => status == MembershipStatus.approved || status == MembershipStatus.requested;
}

/// An area of a school (areas/{id}).
@immutable
class SchoolArea {
  const SchoolArea({required this.id, required this.nameAr, required this.nameEn});

  final String id;
  final String nameAr;
  final String nameEn;

  String name(String languageCode) {
    final String preferred = languageCode == 'ar' ? nameAr : nameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? nameEn : nameAr);
  }
}

/// The place of an activity carpool (F39), picked by address search.
@immutable
class ActivityPlace {
  const ActivityPlace({required this.name, required this.label, required this.lat, required this.lng});

  final String name;
  final String label;
  final double lat;
  final double lng;
}

/// Everything createCarpool needs, collected by the create steps.
@immutable
class CarpoolDraft {
  const CarpoolDraft({
    required this.kind,
    required this.days,
    required this.seats,
    required this.childIds,
    this.schoolId,
    this.areaId,
    this.activity,
    this.morning,
    this.afternoon,
    this.driveDays = const <Weekday>[],
    this.rules = const <CarpoolRule>[],
    this.contribution,
  });

  final CarpoolKind kind;
  final String? schoolId;
  final String? areaId;
  final ActivityPlace? activity;
  final String? morning;
  final String? afternoon;
  final List<Weekday> days;
  final List<Weekday> driveDays;
  final int seats;
  final List<String> childIds;
  final List<CarpoolRule> rules;
  final Contribution? contribution;

  Map<String, Object?> toJson() {
    final ActivityPlace? a = activity;
    return <String, Object?>{
      'kind': kind.name,
      'schoolId': ?schoolId,
      'areaId': ?areaId,
      if (a != null)
        'activity': <String, Object?>{
          'name': a.name,
          'label': a.label,
          'location': <String, Object?>{'lat': a.lat, 'lng': a.lng},
        },
      'morning': morning,
      'afternoon': afternoon,
      'days': <String>[for (final Weekday d in days) d.name],
      'driveDays': <String>[for (final Weekday d in driveDays) d.name],
      'seats': seats,
      'childIds': childIds,
      'rules': <String>[for (final CarpoolRule r in rules) r.code],
      'contribution': contribution?.toJson(),
      // The last create step sends only after the volunteer box is ticked.
      'acceptVolunteer': true,
    };
  }
}

/// A search (searchCarpools).
@immutable
class CarpoolQuery {
  const CarpoolQuery({
    this.kind = CarpoolKind.school,
    this.schoolId,
    this.areaId,
    this.morning,
    this.afternoon,
    this.radiusKm,
    this.parentUid,
    this.activityName,
  });

  final CarpoolKind kind;
  final String? schoolId;
  final String? areaId;
  final String? morning;
  final String? afternoon;
  final int? radiusKm;

  /// Only this parent's carpools (the nearby map's Join button).
  final String? parentUid;

  /// R9: an activity search names one activity (the server shows only
  /// carpools of that activity).
  final String? activityName;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'schoolId': ?schoolId,
    'areaId': ?areaId,
    'morning': ?morning,
    'afternoon': ?afternoon,
    'radiusKm': ?radiusKm,
    'parentUid': ?parentUid,
    'activityName': ?activityName,
  };
}

/// A link to share (F31).
@immutable
class CarpoolInvite {
  const CarpoolInvite({required this.code, required this.url});

  final String code;
  final String url;
}

/// F32: one "Looking for a carpool" post.
@immutable
class WantedPost {
  const WantedPost({
    required this.id,
    required this.firstName,
    required this.days,
    required this.childrenCount,
    this.areaNameAr = '',
    this.areaNameEn = '',
    this.morning,
    this.afternoon,
    this.mine = false,
  });

  factory WantedPost.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return WantedPost(
      id: _text(m['id']),
      firstName: _text(m['firstName']),
      areaNameAr: _text(m['areaNameAr']),
      areaNameEn: _text(m['areaNameEn']),
      morning: _textOrNull(m['morning']),
      afternoon: _textOrNull(m['afternoon']),
      days: Weekday.listFrom(m['days']),
      childrenCount: _int(m['childrenCount']),
      mine: m['mine'] == true,
    );
  }

  final String id;
  final String firstName;
  final String areaNameAr;
  final String areaNameEn;
  final String? morning;
  final String? afternoon;
  final List<Weekday> days;
  final int childrenCount;
  final bool mine;

  String areaName(String languageCode) {
    final String preferred = languageCode == 'ar' ? areaNameAr : areaNameEn;
    return preferred.isNotEmpty ? preferred : (languageCode == 'ar' ? areaNameEn : areaNameAr);
  }
}

/// F32: three or more families match: start a group with these settings.
@immutable
class WantedSuggestion {
  const WantedSuggestion({required this.families, required this.days, this.areaId, this.morning, this.afternoon});

  static WantedSuggestion? fromMap(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    return WantedSuggestion(
      families: _int(value['families']),
      areaId: _textOrNull(value['areaId']),
      morning: _textOrNull(value['morning']),
      afternoon: _textOrNull(value['afternoon']),
      days: Weekday.listFrom(value['days']),
    );
  }

  final int families;
  final String? areaId;
  final String? morning;
  final String? afternoon;
  final List<Weekday> days;
}

@immutable
class WantedList {
  const WantedList({required this.posts, this.suggestion});

  final List<WantedPost> posts;
  final WantedSuggestion? suggestion;

  WantedPost? get mine {
    for (final WantedPost p in posts) {
      if (p.mine) {
        return p;
      }
    }
    return null;
  }
}

/// What saveCarpoolWanted needs.
@immutable
class WantedDraft {
  const WantedDraft({required this.schoolId, required this.days, required this.childIds, this.areaId, this.morning, this.afternoon});

  final String schoolId;
  final String? areaId;
  final String? morning;
  final String? afternoon;
  final List<Weekday> days;
  final List<String> childIds;

  Map<String, Object?> toJson() => <String, Object?>{
    'schoolId': schoolId,
    'areaId': ?areaId,
    'morning': morning,
    'afternoon': afternoon,
    'days': <String>[for (final Weekday d in days) d.name],
    'childIds': childIds,
  };
}

enum CarpoolFailureKind {
  offline,
  rateLimited,
  notVerified,
  noCar,
  carExpired,
  carTooSmall,
  tooManyChildren,
  noSeats,
  alreadyMember,
  alreadyRequested,
  notMember,
  mustAccept,
  tooManyCarpools,
  noHome,
  inviteInvalid,
  adminMustStay,
  closed,
  wrongSchool,
  notYourSchool,
  notFound,
  suspended,
  // Prompt 7 (schedule)
  noConsent,
  notDriver,
  tooLate,
  runTaken,
  notPlannable,
  tooManyExceptions,
  // Prompt 11 review item 1: a linked parent picked a child the other
  // parent already brought into this carpool.
  childInCarpool,
  invalid,
  unknown,
}

/// Why a carpool call failed, from `details.reason` (functions/src/carpools).
class CarpoolFailure implements AppFailure {
  const CarpoolFailure(this.kind, {this.demo});

  factory CarpoolFailure.from(Object error) {
    if (error is CarpoolFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return CarpoolFailure(CarpoolFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final String? reason = callableReason(error);
      final CarpoolFailureKind kind = switch (reason) {
        'rate-limited' => CarpoolFailureKind.rateLimited,
        'not-verified' => CarpoolFailureKind.notVerified,
        'no-car' => CarpoolFailureKind.noCar,
        'car-expired' => CarpoolFailureKind.carExpired,
        'car-too-small' => CarpoolFailureKind.carTooSmall,
        'too-many-children' => CarpoolFailureKind.tooManyChildren,
        'no-seats' => CarpoolFailureKind.noSeats,
        'already-member' => CarpoolFailureKind.alreadyMember,
        'already-requested' => CarpoolFailureKind.alreadyRequested,
        'not-member' || 'not-admin' || 'not-requested' => CarpoolFailureKind.notMember,
        'must-accept' => CarpoolFailureKind.mustAccept,
        'too-many-carpools' => CarpoolFailureKind.tooManyCarpools,
        'no-home' => CarpoolFailureKind.noHome,
        'invite-invalid' => CarpoolFailureKind.inviteInvalid,
        'admin-must-stay' => CarpoolFailureKind.adminMustStay,
        'closed' => CarpoolFailureKind.closed,
        'wrong-school' => CarpoolFailureKind.wrongSchool,
        'not-your-school' => CarpoolFailureKind.notYourSchool,
        'not-found' => CarpoolFailureKind.notFound,
        'suspended' => CarpoolFailureKind.suspended,
        'no-consent' => CarpoolFailureKind.noConsent,
        'not-driver' => CarpoolFailureKind.notDriver,
        'too-late' => CarpoolFailureKind.tooLate,
        'run-taken' => CarpoolFailureKind.runTaken,
        'not-plannable' => CarpoolFailureKind.notPlannable,
        'too-many-exceptions' => CarpoolFailureKind.tooManyExceptions,
        'child-in-carpool' => CarpoolFailureKind.childInCarpool,
        'invalid-request' || 'invalid-school' || 'invalid-area' || 'no-children' || 'not-your-child' || 'self-consent' =>
          CarpoolFailureKind.invalid,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => CarpoolFailureKind.offline,
          _ => CarpoolFailureKind.unknown,
        },
      };
      return CarpoolFailure(kind);
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const CarpoolFailure(CarpoolFailureKind.offline);
    }
    return const CarpoolFailure(CarpoolFailureKind.unknown);
  }

  final CarpoolFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  @override
  bool get isOffline => kind == CarpoolFailureKind.offline;

  /// One short sentence that says what happened and how to fix it.
  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    CarpoolFailureKind.offline => l10n.errorOfflineShort,
    CarpoolFailureKind.rateLimited => l10n.carpoolErrorTooMany,
    CarpoolFailureKind.notVerified => l10n.mapErrorNotVerified,
    CarpoolFailureKind.noCar => l10n.carpoolErrorNoCar,
    CarpoolFailureKind.carExpired => l10n.carpoolErrorCarExpired,
    CarpoolFailureKind.carTooSmall => l10n.carpoolErrorCarTooSmall,
    CarpoolFailureKind.tooManyChildren => l10n.carpoolErrorTooManyChildren,
    CarpoolFailureKind.noSeats => l10n.carpoolErrorNoSeats,
    CarpoolFailureKind.alreadyMember => l10n.carpoolErrorAlreadyMember,
    CarpoolFailureKind.alreadyRequested => l10n.carpoolErrorAlreadyRequested,
    CarpoolFailureKind.notMember => l10n.carpoolErrorNotMember,
    CarpoolFailureKind.mustAccept => l10n.carpoolErrorMustAccept,
    CarpoolFailureKind.tooManyCarpools => l10n.carpoolErrorTooManyCarpools,
    CarpoolFailureKind.noHome => l10n.mapErrorNoHome,
    CarpoolFailureKind.inviteInvalid => l10n.carpoolErrorInviteInvalid,
    CarpoolFailureKind.adminMustStay => l10n.carpoolErrorAdminMustStay,
    CarpoolFailureKind.closed => l10n.carpoolErrorClosed,
    CarpoolFailureKind.wrongSchool => l10n.carpoolErrorWrongSchool,
    CarpoolFailureKind.notYourSchool => l10n.mapErrorNotYourSchool,
    CarpoolFailureKind.notFound => l10n.carpoolErrorNotFound,
    CarpoolFailureKind.suspended => l10n.errorSuspended,
    CarpoolFailureKind.noConsent => l10n.carpoolErrorNoConsent,
    CarpoolFailureKind.notDriver => l10n.carpoolErrorNotDriver,
    CarpoolFailureKind.tooLate => l10n.carpoolErrorTooLate,
    CarpoolFailureKind.runTaken => l10n.carpoolErrorRunTaken,
    CarpoolFailureKind.notPlannable => l10n.carpoolErrorNotPlannable,
    CarpoolFailureKind.tooManyExceptions => l10n.carpoolErrorTooManyExceptions,
    CarpoolFailureKind.childInCarpool => l10n.carpoolErrorChildInCarpool,
    CarpoolFailureKind.invalid || CarpoolFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'CarpoolFailure(${kind.name})';
}
