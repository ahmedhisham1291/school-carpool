import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Trips (Prompt 10: F15, F16, F20, F29, F33, F34, F35, F38, F41). Codes
/// match functions/src/trips/model.ts. Everything here is read from
/// Firestore or returned by Cloud Functions; the app never writes a trip.

String _text(Object? value) => value is String ? value : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

List<Object?> _list(Object? value) => value is List<Object?> ? value : const <Object?>[];

Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const <Object?, Object?>{};

/// An instant, always in UTC.
DateTime? tripInstant(Object? value) => switch (value) {
  final Timestamp t => t.toDate().toUtc(),
  final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true),
  _ => null,
};

/// active: tracking; handover: every child dropped, afternoon handovers
/// wait for the parents; ended: done.
enum TripStatus {
  active,
  handover,
  ended;

  static TripStatus fromName(Object? name) => switch (name) {
    'handover' => handover,
    'ended' => ended,
    _ => active,
  };
}

/// One child's place on the run.
enum StopState {
  waiting,
  arrived,
  onBoard,
  dropped,
  received,
  absent;

  static StopState fromName(Object? name) {
    for (final StopState s in values) {
      if (s.name == name) {
        return s;
      }
    }
    return waiting;
  }
}

/// Who an adult on the handover list is to the child (F29).
enum Relation {
  mother,
  father,
  grandparent,
  sibling,
  relative,
  nanny,
  other;

  static Relation fromName(Object? name) {
    for (final Relation r in values) {
      if (r.name == name) {
        return r;
      }
    }
    return other;
  }
}

/// The driver's one-tap messages (F35).
enum QuickKind {
  late,
  gate,
  allIn;

  static QuickKind? fromName(Object? name) {
    for (final QuickKind k in values) {
      if (k.name == name) {
        return k;
      }
    }
    return null;
  }
}

/// What the driver does at a stop (F16, F41); notComing: the child did not come.
enum StopAction { arrived, pickedUp, dropped, notComing }

@immutable
class HandoverAdult {
  const HandoverAdult({required this.name, required this.relation, this.phone});

  factory HandoverAdult.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    final Object? phone = m['phone'];
    return HandoverAdult(
      name: _text(m['name']),
      relation: Relation.fromName(m['relation']),
      phone: phone is String && phone.isNotEmpty ? phone : null,
    );
  }

  final String name;
  final Relation relation;

  /// Only on the parent's own list, never on a trip.
  final String? phone;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'relation': relation.name, 'phone': ?phone};
}

@immutable
class TripStop {
  const TripStop({
    required this.childId,
    required this.firstName,
    required this.parentUid,
    required this.state,
    this.arrivedCount = 0,
    this.arrivedAt,
    this.droppedAt,
    this.handover = const <HandoverAdult>[],
  });

  factory TripStop.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return TripStop(
      childId: _text(m['childId']),
      firstName: _text(m['firstName']),
      parentUid: _text(m['parentUid']),
      state: StopState.fromName(m['state']),
      arrivedCount: _int(m['arrivedCount']),
      arrivedAt: tripInstant(m['arrivedAt']),
      droppedAt: tripInstant(m['droppedAt']),
      handover: <HandoverAdult>[for (final Object? a in _list(m['handover'])) HandoverAdult.fromMap(a)],
    );
  }

  final String childId;
  final String firstName;
  final String parentUid;
  final StopState state;
  final int arrivedCount;
  final DateTime? arrivedAt;
  final DateTime? droppedAt;
  final List<HandoverAdult> handover;
}

@immutable
class TripCar {
  const TripCar({required this.model, required this.color, required this.plate});

  factory TripCar.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return TripCar(model: _text(m['model']), color: _text(m['color']), plate: _text(m['plate']));
  }

  final String model;
  final String color;
  final String plate;
}

/// trips/{carpoolId}_{runId}: readable by the driver and the parents of the
/// children on that run only (firestore.rules).
@immutable
class Trip {
  const Trip({
    required this.id,
    required this.carpoolId,
    required this.runId,
    required this.direction,
    required this.driverUid,
    required this.driverFirstName,
    required this.status,
    required this.stops,
    this.car,
    this.startedAt,
    this.last,
    this.lastPointAt,
    this.messages = const <(QuickKind, DateTime)>[],
  });

  factory Trip.fromDoc(String id, Map<String, dynamic> d) {
    final Map<Object?, Object?> last = _map(d['last']);
    final Object? location = last['location'];
    return Trip(
      id: id,
      carpoolId: _text(d['carpoolId']),
      runId: _text(d['runId']),
      direction: RunDirection.fromName(d['direction']),
      driverUid: _text(d['driverUid']),
      driverFirstName: _text(d['driverFirstName']),
      status: TripStatus.fromName(d['status']),
      stops: <TripStop>[for (final Object? s in _list(d['stops'])) TripStop.fromMap(s)],
      car: d['car'] == null ? null : TripCar.fromMap(d['car']),
      startedAt: tripInstant(d['startedAt']),
      last: location is GeoPoint ? GeoPin(location.latitude, location.longitude) : null,
      lastPointAt: tripInstant(d['lastPointAt']),
      messages: <(QuickKind, DateTime)>[
        for (final Object? m in _list(d['messages']))
          if (QuickKind.fromName(_map(m)['kind']) case final QuickKind k)
            if (tripInstant(_map(m)['at']) case final DateTime at) (k, at),
      ],
    );
  }

  static String idOf(String carpoolId, String runId) => '${carpoolId}_$runId';

  final String id;
  final String carpoolId;
  final String runId;
  final RunDirection direction;
  final String driverUid;
  final String driverFirstName;
  final TripStatus status;
  final List<TripStop> stops;
  final TripCar? car;
  final DateTime? startedAt;

  /// The car's last point while tracking; null after the last drop-off.
  final GeoPin? last;
  final DateTime? lastPointAt;
  final List<(QuickKind, DateTime)> messages;

  bool get tracking => status == TripStatus.active;

  List<TripStop> get riding => <TripStop>[for (final TripStop s in stops) if (s.state != StopState.absent) s];
}

/// trips/{id}/eta/{parentUid}: expected arrival per child of that parent.
@immutable
class TripEta {
  const TripEta({required this.stops, this.updatedAt});

  factory TripEta.fromDoc(Map<String, dynamic> d) {
    final Map<String, DateTime> stops = <String, DateTime>{};
    _map(d['stops']).forEach((Object? k, Object? v) {
      final DateTime? at = tripInstant(v);
      if (k is String && at != null) {
        stops[k] = at;
      }
    });
    return TripEta(stops: stops, updatedAt: tripInstant(d['updatedAt']));
  }

  final Map<String, DateTime> stops;
  final DateTime? updatedAt;
}

/// What the start screen needs to know before the run (F38).
@immutable
class TripPreparation {
  const TripPreparation({required this.tripId, required this.selfieRequired, required this.active});

  factory TripPreparation.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return TripPreparation(tripId: _text(m['tripId']), selfieRequired: m['selfieRequired'] == true, active: m['active'] == true);
  }

  final String tripId;
  final bool selfieRequired;

  /// The run was started already (the app was restarted): resume.
  final bool active;
}

/// The upload token for the location plugin, for this trip only.
@immutable
class TripSession {
  const TripSession({required this.tripId, required this.token, required this.expiresAt, required this.staleSeconds});

  factory TripSession.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    return TripSession(
      tripId: _text(m['tripId']),
      token: _text(m['token']),
      expiresAt: tripInstant(m['expiresAtMs']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      staleSeconds: _int(m['staleSeconds']) == 0 ? 120 : _int(m['staleSeconds']),
    );
  }

  final String tripId;
  final String token;
  final DateTime expiresAt;
  final int staleSeconds;
}

enum SelfieResult { passed, failed, error }

/// F33: today's driver card of one run.
@immutable
class DriverCard {
  const DriverCard({
    required this.runId,
    required this.direction,
    required this.time,
    required this.driverFirstName,
    this.car,
    this.photoUrl,
  });

  factory DriverCard.fromMap(Object? value) {
    final Map<Object?, Object?> m = _map(value);
    final Object? photo = m['photoUrl'];
    return DriverCard(
      runId: _text(m['runId']),
      direction: RunDirection.fromName(m['direction']),
      time: _text(m['time']),
      driverFirstName: _text(m['driverFirstName']),
      car: m['car'] == null ? null : TripCar.fromMap(m['car']),
      photoUrl: photo is String && photo.startsWith('https://') ? photo : null,
    );
  }

  final String runId;
  final RunDirection direction;
  final String time;
  final String driverFirstName;
  final TripCar? car;
  final String? photoUrl;
}

/// carpools/{id}/emergencies/{id} (F20).
@immutable
class EmergencyAlert {
  const EmergencyAlert({required this.id, required this.driverFirstName, required this.at, this.point});

  factory EmergencyAlert.fromDoc(String id, Map<String, dynamic> d) {
    final Object? location = d['location'];
    return EmergencyAlert(
      id: id,
      driverFirstName: _text(d['driverFirstName']),
      at: tripInstant(d['at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      point: location is GeoPoint ? GeoPin(location.latitude, location.longitude) : null,
    );
  }

  final String id;
  final String driverFirstName;
  final DateTime at;
  final GeoPin? point;
}

/// emergencyContacts/{uid} (F20): the parent's own contact.
@immutable
class EmergencyContact {
  const EmergencyContact({required this.name, required this.phone, required this.relation});

  factory EmergencyContact.fromDoc(Map<String, dynamic> d) =>
      EmergencyContact(name: _text(d['name']), phone: _text(d['phone']), relation: Relation.fromName(d['relation']));

  final String name;
  final String phone;
  final Relation relation;
}

enum TripFailureKind {
  offline,
  rateLimited,
  notVerified,
  notDriver,
  notMember,
  notParent,
  notConfirmed,
  tooEarly,
  tooLate,
  drivingPaused,
  selfieRequired,
  noReference,
  notActive,
  wrongState,
  noChildren,
  childrenOnBoard,
  invalid,
  locationOff,
  unknown,
}

/// Every trip call throws this. [message] says what happened and how to fix it.
class TripFailure implements Exception {
  const TripFailure(this.kind, {this.demo});

  factory TripFailure.from(Object error) {
    if (error is TripFailure) {
      return error;
    }
    // App Review demo parents: a friendly sentence, not the generic error.
    final DemoRefusal? demo = demoRefusalOf(error);
    if (demo != null) {
      return TripFailure(TripFailureKind.unknown, demo: demo);
    }
    if (error is FirebaseFunctionsException) {
      final Object? details = error.details;
      final Object? reason = details is Map<Object?, Object?> ? details['reason'] : null;
      return TripFailure(switch (reason) {
        'rate-limited' => TripFailureKind.rateLimited,
        'not-verified' || 'suspended' => TripFailureKind.notVerified,
        'not-driver' => TripFailureKind.notDriver,
        'not-member' => TripFailureKind.notMember,
        'not-parent' => TripFailureKind.notParent,
        'not-confirmed' => TripFailureKind.notConfirmed,
        'too-early' => TripFailureKind.tooEarly,
        'too-late' => TripFailureKind.tooLate,
        'driving-paused' => TripFailureKind.drivingPaused,
        'selfie-required' => TripFailureKind.selfieRequired,
        'no-reference' => TripFailureKind.noReference,
        'trip-not-active' => TripFailureKind.notActive,
        'wrong-state' => TripFailureKind.wrongState,
        'no-children' => TripFailureKind.noChildren,
        'children-on-board' => TripFailureKind.childrenOnBoard,
        'invalid-request' || 'not-found' || 'no-contact' => TripFailureKind.invalid,
        _ => switch (error.code) {
          'unavailable' || 'deadline-exceeded' => TripFailureKind.offline,
          _ => TripFailureKind.unknown,
        },
      });
    }
    if (error is FirebaseException && error.code == 'unavailable') {
      return const TripFailure(TripFailureKind.offline);
    }
    return const TripFailure(TripFailureKind.unknown);
  }

  final TripFailureKind kind;

  /// Set when the server refused an App Review demo parent.
  final DemoRefusal? demo;

  bool get isOffline => kind == TripFailureKind.offline;

  String message(AppLocalizations l10n) => demoRefusalText(l10n, demo) ?? _kindMessage(l10n);

  String _kindMessage(AppLocalizations l10n) => switch (kind) {
    TripFailureKind.offline => l10n.errorOfflineShort,
    TripFailureKind.rateLimited => l10n.tripErrorTooMany,
    TripFailureKind.notVerified => l10n.mapErrorNotVerified,
    TripFailureKind.notDriver => l10n.tripErrorNotDriver,
    TripFailureKind.notMember || TripFailureKind.notParent => l10n.tripErrorNotYours,
    TripFailureKind.notConfirmed => l10n.tripErrorNotConfirmed,
    TripFailureKind.tooEarly => l10n.tripErrorTooEarly,
    TripFailureKind.tooLate => l10n.tripErrorTooLate,
    TripFailureKind.drivingPaused => l10n.tripErrorPaused,
    TripFailureKind.selfieRequired => l10n.tripErrorSelfie,
    TripFailureKind.noReference => l10n.tripErrorNoPhoto,
    TripFailureKind.notActive => l10n.tripErrorEnded,
    TripFailureKind.wrongState => l10n.tripErrorWrongStep,
    TripFailureKind.noChildren => l10n.tripErrorNoChildren,
    TripFailureKind.childrenOnBoard => l10n.tripErrorOnBoard,
    TripFailureKind.locationOff => l10n.tripErrorLocationOff,
    TripFailureKind.invalid || TripFailureKind.unknown => l10n.stateErrorBody,
  };

  @override
  String toString() => 'TripFailure(${kind.name})';
}
