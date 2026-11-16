import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/firebase/callable_error.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Trust (Prompt 11, F17): ratings and vouching, the yearly check, guardian
/// links and the phone change. Same codes as the server
/// (functions/src/trust/model.ts).

/// Fixed rating tags; the first four are praise, the last three concerns.
enum RatingTag {
  onTime('on-time'),
  safeDriving('safe-driving'),
  friendly('friendly'),
  clear('clear'),
  late('late'),
  unsafeDriving('unsafe-driving'),
  rude('rude');

  const RatingTag(this.wire);

  final String wire;

  bool get concern => this == RatingTag.late || this == RatingTag.unsafeDriving || this == RatingTag.rude;
}

/// The rules of a rating the app checks before sending (the server checks again).
abstract final class RatingRules {
  /// Vouching means "I trust this parent": 4 or 5 stars and no concern.
  static bool canVouch(int stars, Set<RatingTag> tags) => stars >= 4 && !tags.any((RatingTag t) => t.concern);

  /// Low stars or a safety concern reach the admins.
  static bool goesToAdmins(int stars, Set<RatingTag> tags) => stars <= 2 || tags.contains(RatingTag.unsafeDriving);
}

int? _int(Object? v) => v is num ? v.toInt() : null;
String _str(Object? v) => v is String ? v : '';
Map<Object?, Object?> _map(Object? v) => v is Map<Object?, Object?> ? v : const <Object?, Object?>{};
List<Object?> _list(Object? v) => v is List<Object?> ? v : const <Object?>[];

/// Cairo calendar date "YYYY-MM-DD" as a UTC midnight, or null.
DateTime? parseDay(Object? v) {
  if (v is! String) {
    return null;
  }
  final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
  return m == null ? null : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// Ratings and vouches of one parent.
@immutable
class TrustSummary {
  const TrustSummary({this.ratings = 0, this.average, this.vouches = 0});

  factory TrustSummary.fromMap(Map<Object?, Object?> m) => TrustSummary(
    ratings: _int(m['ratings']) ?? 0,
    average: m['average'] is num ? (m['average']! as num).toDouble() : null,
    vouches: _int(m['vouches']) ?? 0,
  );

  final int ratings;

  /// Shown from 3 ratings (one rating stays private).
  final double? average;
  final int vouches;
}

enum YearCheckState { none, due, overdue, done }

/// A child to confirm for the new school year.
@immutable
class YearChild {
  const YearChild({required this.id, required this.firstName, required this.grade, required this.schoolName});

  factory YearChild.fromMap(Map<Object?, Object?> m) => YearChild(
    id: _str(m['id']),
    firstName: _str(m['firstName']),
    grade: Grade.fromName(m['grade']),
    schoolName: _str(m['schoolName']),
  );

  final String id;
  final String firstName;
  final Grade? grade;
  final String schoolName;
}

@immutable
class YearCheck {
  const YearCheck({this.state = YearCheckState.none, this.year, this.deadline, this.children = const <YearChild>[]});

  factory YearCheck.fromMap(Map<Object?, Object?> m) => YearCheck(
    state: switch (m['state']) {
      'due' => YearCheckState.due,
      'overdue' => YearCheckState.overdue,
      'done' => YearCheckState.done,
      _ => YearCheckState.none,
    },
    year: _int(m['year']),
    deadline: parseDay(m['deadline']),
    children: <YearChild>[for (final Object? c in _list(m['children'])) YearChild.fromMap(_map(c))],
  );

  final YearCheckState state;

  /// The calendar year the school year starts in (2027 = 2027-28).
  final int? year;
  final DateTime? deadline;
  final List<YearChild> children;

  bool get open => state == YearCheckState.due || state == YearCheckState.overdue;
}

/// getTrustOverview: what Profile shows.
@immutable
class TrustOverview {
  const TrustOverview({this.summary = const TrustSummary(), this.toRate = 0, this.yearCheck = const YearCheck(), this.requests = 0});

  factory TrustOverview.fromMap(Map<Object?, Object?> m) => TrustOverview(
    summary: TrustSummary.fromMap(_map(m['summary'])),
    toRate: _int(m['toRate']) ?? 0,
    yearCheck: YearCheck.fromMap(_map(m['yearCheck'])),
    requests: _int(m['requests']) ?? 0,
  );

  final TrustSummary summary;
  final int toRate;
  final YearCheck yearCheck;

  /// Link requests waiting for this parent's answer.
  final int requests;
}

/// A parent the caller shared a finished trip with and may rate.
@immutable
class RateableParent {
  const RateableParent({required this.uid, required this.firstName, required this.drove, required this.date});

  factory RateableParent.fromMap(Map<Object?, Object?> m) => RateableParent(
    uid: _str(m['uid']),
    firstName: _str(m['firstName']),
    drove: m['role'] == 'driver',
    date: parseDay(m['date']),
  );

  final String uid;
  final String firstName;

  /// True when this parent drove the shared trip.
  final bool drove;
  final DateTime? date;
}

/// What a rating sends.
@immutable
class RatingDraft {
  const RatingDraft({required this.uid, required this.stars, this.tags = const <RatingTag>{}, this.vouch = false});

  final String uid;
  final int stars;
  final Set<RatingTag> tags;
  final bool vouch;

  Map<String, Object?> toJson() => <String, Object?>{
    'uid': uid,
    'stars': stars,
    'tags': <String>[for (final RatingTag t in tags) t.wire],
    'vouch': vouch,
  };
}

/// GuardianRelation of a linked parent to the children (spec section 9).
enum GuardianRelation {
  father,
  mother,
  guardian;

  static GuardianRelation fromName(Object? name) {
    for (final GuardianRelation r in values) {
      if (r.name == name) {
        return r;
      }
    }
    return GuardianRelation.guardian;
  }
}

enum LinkStatus { review, active, other }

@immutable
class GuardianRequest {
  const GuardianRequest({required this.id, required this.guardianFirstName, required this.relation});

  factory GuardianRequest.fromMap(Map<Object?, Object?> m) =>
      GuardianRequest(id: _str(m['id']), guardianFirstName: _str(m['guardianFirstName']), relation: GuardianRelation.fromName(m['relation']));

  final String id;
  final String guardianFirstName;
  final GuardianRelation relation;
}

@immutable
class GuardianLink {
  const GuardianLink({
    required this.id,
    required this.childFirstName,
    required this.ownerFirstName,
    required this.guardianFirstName,
    required this.relation,
    required this.status,
    this.childId = '',
    this.childGrade,
    this.childSchoolId = '',
    this.childSchoolName = '',
  });

  factory GuardianLink.fromMap(Map<Object?, Object?> m) => GuardianLink(
    id: _str(m['id']),
    childId: _str(m['childId']),
    childGrade: Grade.fromName(m['childGrade']),
    childSchoolId: _str(m['childSchoolId']),
    childSchoolName: _str(m['childSchoolName']),
    childFirstName: _str(m['childFirstName']),
    ownerFirstName: _str(m['ownerFirstName']),
    guardianFirstName: _str(m['guardianFirstName']),
    relation: GuardianRelation.fromName(m['relation']),
    status: switch (m['status']) {
      'review' => LinkStatus.review,
      'active' => LinkStatus.active,
      _ => LinkStatus.other,
    },
  );

  final String id;
  final String childFirstName;
  final String ownerFirstName;
  final String guardianFirstName;
  final GuardianRelation relation;
  final LinkStatus status;

  /// For links that give me another parent's child (active): what a carpool needs.
  final String childId;
  final Grade? childGrade;
  final String childSchoolId;
  final String childSchoolName;

  /// The linked child as a child record for carpool pickers, or null while
  /// the link waits for review or the child has no details.
  ChildRecord? get asChild {
    final Grade? grade = childGrade;
    if (status != LinkStatus.active || childId.isEmpty || grade == null) {
      return null;
    }
    return ChildRecord(
      id: childId,
      firstName: childFirstName,
      age: 0,
      grade: grade,
      schoolName: childSchoolName,
      schoolId: childSchoolId,
      status: ReviewStatus.approved,
    );
  }
}

/// getFamily.
@immutable
class FamilyView {
  const FamilyView({
    this.incoming = const <GuardianRequest>[],
    this.outgoing = const <GuardianRequest>[],
    this.shared = const <GuardianLink>[],
    this.linked = const <GuardianLink>[],
  });

  factory FamilyView.fromMap(Map<Object?, Object?> m) => FamilyView(
    incoming: <GuardianRequest>[for (final Object? r in _list(m['incoming'])) GuardianRequest.fromMap(_map(r))],
    outgoing: <GuardianRequest>[for (final Object? r in _list(m['outgoing'])) GuardianRequest.fromMap(_map(r))],
    shared: <GuardianLink>[for (final Object? l in _list(m['shared'])) GuardianLink.fromMap(_map(l))],
    linked: <GuardianLink>[for (final Object? l in _list(m['linked'])) GuardianLink.fromMap(_map(l))],
  );

  final List<GuardianRequest> incoming;
  final List<GuardianRequest> outgoing;

  /// My children shared with another parent.
  final List<GuardianLink> shared;

  /// Another parent's children shared with me.
  final List<GuardianLink> linked;

  bool get isEmpty => incoming.isEmpty && outgoing.isEmpty && shared.isEmpty && linked.isEmpty;
}

/// One answer of the yearly check.
@immutable
class YearAnswer {
  const YearAnswer({required this.childId, required this.stays, this.grade});

  final String childId;
  final bool stays;
  final Grade? grade;

  Map<String, Object?> toJson() => <String, Object?>{'childId': childId, 'stays': stays, if (stays) 'grade': grade?.name};
}

/// The yearly check can be sent: every child answered, a grade for each who stays.
bool yearAnswersComplete(List<YearChild> children, Map<String, YearAnswer> answers) =>
    children.isNotEmpty &&
    children.every((YearChild c) {
      final YearAnswer? a = answers[c.id];
      return a != null && (!a.stays || a.grade != null);
    });

/// The next grade (the usual answer for a child who stays); grade 12 stays.
Grade nextGrade(Grade g) => g.index + 1 < Grade.values.length ? Grade.values[g.index + 1] : g;

/// Driving papers (spec section 3): remind before expiry, block after it.
sealed class PapersNotice {
  const PapersNotice();
}

final class PapersFine extends PapersNotice {
  const PapersFine();
}

final class PapersExpireSoon extends PapersNotice {
  const PapersExpireSoon(this.days);

  final int days;
}

final class PapersExpired extends PapersNotice {
  const PapersExpired();
}

/// Within [warnDays] of the earlier expiry: soon; past it: expired. Dates
/// are calendar days (the last day is still valid).
PapersNotice papersNotice(DateTime? licence, DateTime? carLicence, DateTime today, {int warnDays = 30}) {
  final List<DateTime> dates = <DateTime>[?licence, ?carLicence]..sort();
  if (dates.isEmpty) {
    return const PapersFine();
  }
  final DateTime first = DateTime.utc(dates.first.year, dates.first.month, dates.first.day);
  final int days = first.difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  if (days < 0) {
    return const PapersExpired();
  }
  return days <= warnDays ? PapersExpireSoon(days) : const PapersFine();
}

enum TrustFailureKind {
  notVerified,
  suspended,
  notFound,
  self,
  noSharedTrip,
  alreadyRated,
  notAllowed,
  alreadyLinked,
  alreadyRequested,
  tooManyGuardians,
  changed,
  rateLimited,
  phoneSame,
  phoneTaken,
  noSelfie,
  noReference,
  selfieMismatch,
  checkUnavailable,

  /// A code problem (wrong, expired, locked...): see [TrustFailure.auth].
  code,
  offline,
  unknown,
}

class TrustFailure implements AppFailure {
  const TrustFailure(this.kind, {this.demo, this.auth});

  factory TrustFailure.from(Object error) {
    if (error is TrustFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return TrustFailure(TrustFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final String? reason = callableReason(error);
      const Set<String> otp = <String>{'invalid-phone', 'wrong-code', 'expired', 'too-many-attempts', 'locked', 'too-soon', 'send-failed'};
      if (reason is String && otp.contains(reason)) {
        return TrustFailure(TrustFailureKind.code, auth: AuthFailure.from(error));
      }
      return TrustFailure(switch (reason) {
        'not-verified' || 'no-account' => TrustFailureKind.notVerified,
        'suspended' => TrustFailureKind.suspended,
        'not-found' || 'not-your-child' => TrustFailureKind.notFound,
        'self' => TrustFailureKind.self,
        'no-shared-trip' => TrustFailureKind.noSharedTrip,
        'already-rated' => TrustFailureKind.alreadyRated,
        'not-allowed' => TrustFailureKind.notAllowed,
        'already-linked' => TrustFailureKind.alreadyLinked,
        'already-requested' => TrustFailureKind.alreadyRequested,
        'too-many-guardians' => TrustFailureKind.tooManyGuardians,
        'invalid-state' || 'children-changed' || 'year-not-open' => TrustFailureKind.changed,
        'rate-limited' => TrustFailureKind.rateLimited,
        'phone-same' => TrustFailureKind.phoneSame,
        'phone-taken' => TrustFailureKind.phoneTaken,
        'no-selfie' => TrustFailureKind.noSelfie,
        'no-reference' => TrustFailureKind.noReference,
        'selfie-mismatch' => TrustFailureKind.selfieMismatch,
        'check-unavailable' => TrustFailureKind.checkUnavailable,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => TrustFailureKind.offline,
          _ => TrustFailureKind.unknown,
        },
      });
    }
    if (error is FirebaseException && (error.code == 'unavailable' || error.code == 'retry-limit-exceeded')) {
      return const TrustFailure(TrustFailureKind.offline);
    }
    return const TrustFailure(TrustFailureKind.unknown);
  }

  final TrustFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;
  final AuthFailure? auth;

  @override
  bool get isOffline => kind == TrustFailureKind.offline;

  /// One short sentence that says what happened and what to do.
  @override
  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    TrustFailureKind.notVerified => l10n.trustErrorNotVerified,
    TrustFailureKind.suspended => l10n.errorSuspended,
    TrustFailureKind.notFound => l10n.trustErrorNotFound,
    TrustFailureKind.self => l10n.trustErrorSelf,
    TrustFailureKind.noSharedTrip => l10n.trustErrorNoTrip,
    TrustFailureKind.alreadyRated => l10n.trustErrorAlreadyRated,
    TrustFailureKind.notAllowed => l10n.trustErrorNotAllowed,
    TrustFailureKind.alreadyLinked => l10n.trustErrorAlreadyLinked,
    TrustFailureKind.alreadyRequested => l10n.trustErrorAlreadyRequested,
    TrustFailureKind.tooManyGuardians => l10n.trustErrorTooManyGuardians,
    TrustFailureKind.changed => l10n.trustErrorChanged,
    TrustFailureKind.rateLimited => l10n.trustErrorRateLimited,
    TrustFailureKind.phoneSame => l10n.phoneChangeErrorSame,
    TrustFailureKind.phoneTaken => l10n.phoneChangeErrorTaken,
    TrustFailureKind.noSelfie => l10n.phoneChangeErrorSelfie,
    TrustFailureKind.noReference => l10n.phoneChangeErrorNoReference,
    TrustFailureKind.selfieMismatch => l10n.phoneChangeErrorMismatch,
    TrustFailureKind.checkUnavailable => l10n.phoneChangeErrorUnavailable,
    TrustFailureKind.code => auth?.message(l10n) ?? l10n.errorGeneric,
    TrustFailureKind.offline => l10n.errorOfflineShort,
    TrustFailureKind.unknown => l10n.errorGeneric,
  };

  @override
  String toString() => 'TrustFailure(${kind.name})';
}
