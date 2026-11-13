import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';

/// Schedule (Prompt 7: F7, F11, F27, F28, F30, F37). Codes match
/// functions/src/schedule/model.ts. Everything here is read from Firestore
/// or returned by Cloud Functions; the app never writes it.

String _text(Object? value) => value is String ? value : '';

String? _textOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;

int _int(Object? value) => value is num ? value.toInt() : 0;

List<Object?> _list(Object? value) => value is List<Object?> ? value : const <Object?>[];

Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const <Object?, Object?>{};

DateTime? _instant(Object? value) => switch (value) {
  final Timestamp t => t.toDate(),
  final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
  _ => null,
};

/// Calendar dates as the server keeps them ("YYYY-MM-DD", Cairo dates).
/// The app uses the phone's calendar day, which is the Cairo day for
/// parents in Egypt; the server decides every deadline in Cairo time.
abstract final class ScheduleDates {
  static String key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime? parse(Object? value) {
    if (value is! String) {
      return null;
    }
    final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// The weekday code of [d] (Saturday first, as in Egypt).
  static Weekday weekdayOf(DateTime d) => Weekday.values[(d.weekday + 1) % 7];

  /// The Saturday that starts the Egyptian week of [d].
  static DateTime weekStart(DateTime d) {
    final DateTime x = day(d);
    return DateTime(x.year, x.month, x.day - (x.weekday + 1) % 7);
  }

  static DateTime addDays(DateTime d, int days) => DateTime(d.year, d.month, d.day + days);

  /// Whole calendar days from [a] to [b] (UTC dates, so a clock change never counts).
  static int daysBetween(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

  /// School term of [d]: "2026-t1" is September 2026 to January 2027,
  /// "2026-t2" February to August 2027 (same as the server).
  static String termId(DateTime d) {
    if (d.month >= 9) {
      return '${d.year}-t1';
    }
    if (d.month == 1) {
      return '${d.year - 1}-t1';
    }
    return '${d.year - 1}-t2';
  }
}

enum RunDirection {
  toSchool,
  toHome;

  static RunDirection fromName(Object? name) => name == 'toHome' ? toHome : toSchool;
}

/// See functions/src/schedule/model.ts (RunStatus).
enum RunStatus {
  planned,
  confirmed,
  open,
  missed,
  cancelled,
  completed;

  static RunStatus fromName(Object? name) {
    for (final RunStatus s in values) {
      if (s.name == name) {
        return s;
      }
    }
    return open;
  }
}

/// A child on a run's pickup list: first name only.
@immutable
class Rider {
  const Rider({required this.id, required this.firstName, required this.parentUid});

  factory Rider.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return Rider(id: _text(m['id']), firstName: _text(m['firstName']), parentUid: _text(m['parentUid']));
  }

  final String id;
  final String firstName;
  final String parentUid;
}

List<Rider> _riders(Object? value) => <Rider>[for (final Object? r in _list(value)) Rider.fromMap(r)];

/// carpools/{id}/schedule/{date}_{am|pm}: one run.
@immutable
class ScheduleRun {
  const ScheduleRun({
    required this.id,
    required this.date,
    required this.direction,
    required this.time,
    required this.status,
    this.driverUid,
    this.driverFirstName = '',
    this.fallback = false,
    this.swapped = false,
    this.swapId,
    this.swapBy,
    this.riders = const <Rider>[],
    this.absent = const <Rider>[],
    this.start,
    this.confirmBy,
  });

  factory ScheduleRun.fromDoc(String id, Map<String, Object?> d) => ScheduleRun(
    id: id,
    date: ScheduleDates.parse(d['date']) ?? DateTime(2000),
    direction: RunDirection.fromName(d['direction']),
    time: _text(d['time']),
    status: RunStatus.fromName(d['status']),
    driverUid: _textOrNull(d['driverUid']),
    driverFirstName: _text(d['driverFirstName']),
    fallback: d['fallback'] == true,
    swapped: d['swapped'] == true,
    swapId: _textOrNull(d['swapId']),
    swapBy: _textOrNull(d['swapBy']),
    riders: _riders(d['riders']),
    absent: _riders(d['absent']),
    start: _instant(d['startAt']),
    confirmBy: _instant(d['confirmBy']),
  );

  final String id;
  final DateTime date;
  final RunDirection direction;

  /// Cairo wall-clock "HH:MM" (after exceptions such as Ramadan times).
  final String time;
  final RunStatus status;
  final String? driverUid;
  final String driverFirstName;

  /// Proposed on a day the driver did not choose (nobody chose it).
  final bool fallback;
  final bool swapped;
  final String? swapId;

  /// Who asked for the open swap (can take it back).
  final String? swapBy;
  final List<Rider> riders;
  final List<Rider> absent;
  final DateTime? start;
  final DateTime? confirmBy;

  bool get swapOpen => status == RunStatus.open && swapId != null;

  /// Still ahead and changeable (not done, missed or cancelled).
  bool isLive(DateTime now) {
    final DateTime? s = start;
    return (status == RunStatus.planned || status == RunStatus.confirmed || status == RunStatus.open) &&
        (s == null || s.isAfter(now));
  }
}

enum ExceptionKind {
  noSchool,
  times;

  static ExceptionKind fromName(Object? name) => name == 'times' ? times : noSchool;
}

enum ExceptionReason {
  holiday,
  exams,
  early,
  ramadan,
  other;

  static ExceptionReason fromName(Object? name) {
    for (final ExceptionReason r in values) {
      if (r.name == name) {
        return r;
      }
    }
    return other;
  }
}

/// carpools/{id}/exceptions/{id} (F30).
@immutable
class ScheduleException {
  const ScheduleException({
    required this.id,
    required this.kind,
    required this.reason,
    required this.from,
    required this.to,
    this.morning,
    this.afternoon,
  });

  factory ScheduleException.fromDoc(String id, Map<String, Object?> d) {
    final DateTime from = ScheduleDates.parse(d['from']) ?? DateTime(2000);
    return ScheduleException(
      id: id,
      kind: ExceptionKind.fromName(d['kind']),
      reason: ExceptionReason.fromName(d['reason']),
      from: from,
      to: ScheduleDates.parse(d['to']) ?? from,
      morning: _textOrNull(d['morning']),
      afternoon: _textOrNull(d['afternoon']),
    );
  }

  final String id;
  final ExceptionKind kind;
  final ExceptionReason reason;
  final DateTime from;
  final DateTime to;
  final String? morning;
  final String? afternoon;

  bool get oneDay => ScheduleDates.key(from) == ScheduleDates.key(to);
}

/// What saveScheduleException needs (F30). Longest range: 60 days.
@immutable
class ExceptionDraft {
  const ExceptionDraft({required this.kind, required this.reason, required this.from, required this.to, this.morning, this.afternoon});

  static const int maxDays = 60;

  final ExceptionKind kind;
  final ExceptionReason reason;
  final DateTime from;
  final DateTime to;
  final String? morning;
  final String? afternoon;

  Map<String, Object?> toJson(String carpoolId) => <String, Object?>{
    'carpoolId': carpoolId,
    'kind': kind.name,
    'reason': reason.name,
    'from': ScheduleDates.key(from),
    'to': ScheduleDates.key(to),
    if (kind == ExceptionKind.times) 'morning': morning,
    if (kind == ExceptionKind.times) 'afternoon': afternoon,
  };
}

/// One family's runs this term (F37).
@immutable
class FamilyBalance {
  const FamilyBalance({required this.uid, required this.firstName, required this.driven, required this.received});

  final String uid;
  final String firstName;
  final int driven;
  final int received;
}

/// carpools/{id}/balances/{termId}.
@immutable
class DriveBalance {
  const DriveBalance({required this.termId, required this.families});

  factory DriveBalance.fromDoc(String termId, Map<String, Object?> d) {
    final Map<Object?, Object?> raw = _map(d['families']);
    return DriveBalance(
      termId: termId,
      families: <FamilyBalance>[
        for (final MapEntry<Object?, Object?> e in raw.entries)
          if (e.key case final String uid)
            FamilyBalance(
              uid: uid,
              firstName: _text(_map(e.value)['firstName']),
              driven: _int(_map(e.value)['driven']),
              received: _int(_map(e.value)['received']),
            ),
      ],
    );
  }

  final String termId;
  final List<FamilyBalance> families;
}

/// What planScheduleWeek returns.
@immutable
class PlanResult {
  const PlanResult({required this.planned, required this.open});

  factory PlanResult.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return PlanResult(planned: _int(m['planned']), open: _int(m['open']));
  }

  final int planned;
  final int open;
}
