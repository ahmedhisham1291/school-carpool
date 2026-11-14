import 'dart:math' as math;

import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/trip_models.dart';

/// Pure trip rules for the screens (same order as the server,
/// functions/src/trips/model.ts). Unit tested in test/trips.

/// The driver may start from an hour before the run to three hours after
/// (the server checks again).
const Duration kStartEarly = Duration(hours: 1);
const Duration kStartLate = Duration(hours: 3);

/// The run's start screen is for this parent now.
bool canStartRun(ScheduleRun run, String uid, DateTime now) {
  final DateTime? start = run.start;
  if (run.driverUid != uid || start == null) {
    return false;
  }
  if (run.status != RunStatus.confirmed && run.status != RunStatus.completed) {
    return false;
  }
  return !now.isBefore(start.subtract(kStartEarly)) && !now.isAfter(start.add(kStartLate));
}

/// A parent with a child riding this run may follow it today.
bool canFollowRun(ScheduleRun run, String uid, DateTime now) {
  final DateTime? start = run.start;
  if (start == null || run.driverUid == uid) {
    return false;
  }
  if (!run.riders.any((Rider r) => r.parentUid == uid)) {
    return false;
  }
  return !now.isBefore(start.subtract(kStartEarly)) && !now.isAfter(start.add(kStartLate));
}

/// The buttons of one stop on the driver screen, in order; the last one
/// is the step forward (the primary button). Morning: Arrived, Picked up,
/// Dropped at school. Afternoon: Picked up at school, Arrived home,
/// Dropped (handed over). Arrived can be tapped again (F41).
List<StopAction> stopActions(TripStop stop, RunDirection direction) {
  final bool morning = direction == RunDirection.toSchool;
  return switch (stop.state) {
    StopState.waiting =>
      morning
          ? const <StopAction>[StopAction.arrived, StopAction.notComing, StopAction.pickedUp]
          : const <StopAction>[StopAction.notComing, StopAction.pickedUp],
    StopState.arrived =>
      morning
          ? const <StopAction>[StopAction.arrived, StopAction.notComing, StopAction.pickedUp]
          : const <StopAction>[StopAction.arrived, StopAction.dropped],
    StopState.onBoard => morning ? const <StopAction>[StopAction.dropped] : const <StopAction>[StopAction.arrived, StopAction.dropped],
    StopState.dropped || StopState.received || StopState.absent => const <StopAction>[],
  };
}

/// Arrived alerts per stop and the pause between two (same as the server).
const int kMaxArrived = 5;
const Duration kArrivedGap = Duration(seconds: 30);

/// Arrived can be sent now (not just sent, not used up).
bool arrivedAvailable(TripStop stop, DateTime now) {
  if (stop.arrivedCount >= kMaxArrived) {
    return false;
  }
  final DateTime? at = stop.arrivedAt;
  return at == null || now.difference(at) >= kArrivedGap;
}

/// A child is in the car (End run is refused then).
bool childOnBoard(Trip trip) =>
    trip.stops.any((TripStop s) => s.state == StopState.onBoard || (trip.direction == RunDirection.toHome && s.state == StopState.arrived));

/// The stop the driver should look at first: the first one not done.
int currentStopIndex(Trip trip) {
  final List<TripStop> riding = trip.riding;
  for (int i = 0; i < riding.length; i++) {
    if (stopActions(riding[i], trip.direction).isNotEmpty) {
      return i;
    }
  }
  return -1;
}

enum LocationHealth {
  /// No point yet: waiting for the first one.
  waiting,
  live,

  /// No point for longer than the stale time (the server alerts too).
  stale,

  /// Tracking stopped (last drop-off).
  off,
}

LocationHealth locationHealth(Trip trip, DateTime now, {int staleSeconds = 120}) {
  if (!trip.tracking) {
    return LocationHealth.off;
  }
  final DateTime? last = trip.lastPointAt;
  if (last == null) {
    final DateTime? started = trip.startedAt;
    return started != null && now.difference(started).inSeconds > staleSeconds ? LocationHealth.stale : LocationHealth.waiting;
  }
  return now.difference(last).inSeconds > staleSeconds ? LocationHealth.stale : LocationHealth.live;
}

/// Whole minutes until [eta] (0 when due), or null when unknown.
int? minutesUntil(DateTime? eta, DateTime now) {
  if (eta == null) {
    return null;
  }
  final int seconds = eta.difference(now).inSeconds;
  return seconds <= 30 ? 0 : (seconds / 60).ceil();
}

/// The receiving parent can confirm this child (afternoon, dropped, theirs).
bool canConfirmHandover(Trip trip, TripStop stop, String uid) =>
    trip.direction == RunDirection.toHome && stop.state == StopState.dropped && stop.parentUid == uid;

/// The parent's own children on the trip.
List<TripStop> myStops(Trip trip, String uid) => <TripStop>[for (final TripStop s in trip.riding) if (s.parentUid == uid) s];

/// A request ID for one tap (safe to send again while offline: the server
/// applies it once).
String newRequestId([math.Random? random]) {
  const String alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  final math.Random r = random ?? math.Random.secure();
  return List<String>.generate(20, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

/// Name check for the handover list and the emergency contact (same rule
/// as the server): letters, spaces, dots, apostrophes and hyphens, 2 to 40.
bool validPersonName(String value) =>
    RegExp(r"^[\p{L}\p{M}][\p{L}\p{M} .'’-]{0,38}[\p{L}\p{M}.]$", unicode: true).hasMatch(value.trim().replaceAll(RegExp(r'\s+'), ' '));
