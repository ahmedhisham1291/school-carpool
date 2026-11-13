import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';

/// Schedule rules on the phone (Prompt 7). The server decides; the app
/// uses these to show the right action and the balance.

/// What the signed-in parent can do with a run.
enum RunAction {
  /// The proposed driver confirms (F28) or asks for a swap.
  confirm,

  /// The confirmed driver can still ask for a swap (F11).
  cantDrive,

  /// The parent who asked for the swap drives after all.
  takeBack,

  /// An open run: an eligible member takes it (accepts the swap).
  take,

  none,
}

RunAction runAction(ScheduleRun run, String uid, DateTime now, {required bool hasCar}) {
  if (!run.isLive(now)) {
    return RunAction.none;
  }
  final DateTime? deadline = run.confirmBy;
  final bool beforeDeadline = deadline == null || now.isBefore(deadline);
  switch (run.status) {
    case RunStatus.planned when run.driverUid == uid:
      return beforeDeadline ? RunAction.confirm : RunAction.none;
    case RunStatus.confirmed when run.driverUid == uid:
      return RunAction.cantDrive;
    case RunStatus.open when run.swapOpen && run.swapBy == uid:
      return beforeDeadline ? RunAction.takeBack : RunAction.none;
    case RunStatus.open when run.driverUid == null:
      return beforeDeadline && hasCar ? RunAction.take : RunAction.none;
    default:
      return RunAction.none;
  }
}

/// Runs the parent still has to confirm.
int runsToConfirm(List<ScheduleRun> runs, String uid, DateTime now) =>
    runs.where((ScheduleRun r) => r.status == RunStatus.planned && r.driverUid == uid && r.isLive(now)).length;

/// Runs grouped by date, in date order, each day morning first.
List<(DateTime, List<ScheduleRun>)> runsByDay(List<ScheduleRun> runs) {
  final Map<String, List<ScheduleRun>> byDay = <String, List<ScheduleRun>>{};
  for (final ScheduleRun r in runs) {
    byDay.putIfAbsent(ScheduleDates.key(r.date), () => <ScheduleRun>[]).add(r);
  }
  final List<String> keys = byDay.keys.toList()..sort();
  return <(DateTime, List<ScheduleRun>)>[
    for (final String k in keys)
      (
        ScheduleDates.parse(k)!,
        byDay[k]!..sort((ScheduleRun a, ScheduleRun b) => a.direction.index - b.direction.index),
      ),
  ];
}

/// The parent's own children on a run: riding, then away.
List<(Rider, bool)> myChildrenOn(ScheduleRun run, String uid) => <(Rider, bool)>[
  for (final Rider r in run.riders)
    if (r.parentUid == uid) (r, false),
  for (final Rider r in run.absent)
    if (r.parentUid == uid) (r, true),
];

/// Families ordered for the balance screen (F37): furthest behind their
/// fair share first. The fair share follows the number of children each
/// family brings, as in the server's rotation.
List<FamilyBalance> balanceOrder(DriveBalance? balance, List<CarpoolMember> members) {
  final Map<String, FamilyBalance> byUid = <String, FamilyBalance>{
    for (final FamilyBalance f in balance?.families ?? const <FamilyBalance>[]) f.uid: f,
  };
  final List<FamilyBalance> rows = <FamilyBalance>[
    for (final CarpoolMember m in members)
      byUid[m.uid] ?? FamilyBalance(uid: m.uid, firstName: m.firstName, driven: 0, received: 0),
  ];
  final Map<String, double> debt = driveDebts(rows, members);
  return rows..sort((FamilyBalance a, FamilyBalance b) {
    final int byDebt = (debt[a.uid] ?? 0).compareTo(debt[b.uid] ?? 0);
    return byDebt != 0 ? byDebt : a.firstName.compareTo(b.firstName);
  });
}

/// Driven minus the fair share (negative: behind).
Map<String, double> driveDebts(List<FamilyBalance> rows, List<CarpoolMember> members) {
  final Map<String, int> children = <String, int>{
    for (final CarpoolMember m in members) m.uid: m.children.isEmpty ? 1 : m.children.length,
  };
  final int total = rows.fold<int>(0, (int n, FamilyBalance f) => n + f.driven);
  final int kids = rows.fold<int>(0, (int n, FamilyBalance f) => n + (children[f.uid] ?? 1));
  return <String, double>{
    for (final FamilyBalance f in rows) f.uid: kids == 0 ? 0 : f.driven - total * (children[f.uid] ?? 1) / kids,
  };
}

/// The family furthest behind, when anyone has driven at all.
String? droveLeast(DriveBalance? balance, List<CarpoolMember> members) {
  final List<FamilyBalance> order = balanceOrder(balance, members);
  final bool anyRuns = order.any((FamilyBalance f) => f.driven > 0);
  return anyRuns && order.isNotEmpty ? order.first.uid : null;
}

/// Checks a no-school day or time change as the admin fills it in.
enum ExceptionProblem { range, times }

ExceptionProblem? checkException(ExceptionDraft d) {
  final int days = ScheduleDates.daysBetween(d.from, d.to);
  if (days < 0 || days >= ExceptionDraft.maxDays) {
    return ExceptionProblem.range;
  }
  if (d.kind == ExceptionKind.times && d.morning == null && d.afternoon == null) {
    return ExceptionProblem.times;
  }
  return null;
}
