import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';

/// Seat and driver-consent rules on the phone (F26, spec section 6
/// "Seats"). The same rules as functions/src/carpools/model.ts, which
/// enforces them; the app uses these to explain what is missing.

enum DriverProblem { noCar, carExpired, carTooSmall }

@immutable
class DriverStatus {
  const DriverStatus({required this.canDrive, required this.waitingFor, this.problem});

  /// True when the member may drive a run with every child of the carpool.
  final bool canDrive;
  final DriverProblem? problem;

  /// Members with children in the carpool who have not accepted this driver.
  final List<String> waitingFor;
}

/// Accepted consents as "parent_driver" keys (withdrawn ones do not count).
Set<String> acceptedConsentKeys(List<DriverConsent> consents) => <String>{
  for (final DriverConsent c in consents)
    if (c.accepted) '${c.parentUid}_${c.driverUid}',
};

/// Children riding in the carpool (all approved members).
int childrenIn(List<CarpoolMember> members) => members.fold<int>(0, (int n, CarpoolMember m) => n + m.children.length);

/// Can [driver] carry every child of the carpool on [today]? A valid car
/// with enough passenger seats, and every other parent's consent.
DriverStatus driverStatus(CarpoolMember driver, List<CarpoolMember> members, List<DriverConsent> consents, DateTime today) {
  final Set<String> accepted = acceptedConsentKeys(consents);
  final List<String> waiting = <String>[
    for (final CarpoolMember m in members)
      if (m.uid != driver.uid && m.children.isNotEmpty && !accepted.contains('${m.uid}_${driver.uid}')) m.uid,
  ];
  final CarpoolCar? car = driver.car;
  final DateTime day = DateTime(today.year, today.month, today.day);
  final DriverProblem? problem = car == null
      ? DriverProblem.noCar
      : car.validUntil.isBefore(day)
      ? DriverProblem.carExpired
      : childrenIn(members) > car.seats
      ? DriverProblem.carTooSmall
      : null;
  return DriverStatus(canDrive: problem == null && waiting.isEmpty, problem: problem, waitingFor: waiting);
}

/// Seats a creator may offer: never more than the car's passenger seats.
List<int> seatChoices(int carSeats) => <int>[for (int s = 1; s <= carSeats; s++) s];

/// True when [childCount] children fit [seatsLeft] (join request and approval).
bool fitsSeats(int childCount, int seatsLeft) => childCount > 0 && childCount <= seatsLeft;
