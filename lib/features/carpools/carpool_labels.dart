import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Words for carpool codes, in the app's language. Labels are short so
/// chips and titles stay on one line at 320 dp (DESIGN.md, one-line wording).

String dayShort(AppLocalizations l10n, Weekday d) => switch (d) {
  Weekday.sat => l10n.daySat,
  Weekday.sun => l10n.daySun,
  Weekday.mon => l10n.dayMon,
  Weekday.tue => l10n.dayTue,
  Weekday.wed => l10n.dayWed,
  Weekday.thu => l10n.dayThu,
  Weekday.fri => l10n.dayFri,
};

/// "Sun to Thu" for the school week, otherwise the days in order.
String daysText(AppLocalizations l10n, List<Weekday> days) {
  if (days.length == Weekday.schoolDays.length && Weekday.schoolDays.every(days.contains)) {
    return l10n.carpoolSchoolWeek;
  }
  return days.map((Weekday d) => dayShort(l10n, d)).join(l10n.listSeparator);
}

String ruleLabel(AppLocalizations l10n, CarpoolRule r) => switch (r) {
  CarpoolRule.noSmoking => l10n.ruleNoSmoking,
  CarpoolRule.mothersOnly => l10n.ruleMothersOnly,
  CarpoolRule.seatBelts => l10n.ruleSeatBelts,
  CarpoolRule.childSeats => l10n.ruleChildSeats,
  CarpoolRule.wait5Min => l10n.ruleWait5Min,
  CarpoolRule.noPhone => l10n.ruleNoPhone,
  CarpoolRule.noFood => l10n.ruleNoFood,
  CarpoolRule.girlsOnly => l10n.ruleGirlsOnly,
};

String periodLabel(AppLocalizations l10n, ContributionPeriod p) => switch (p) {
  ContributionPeriod.trip => l10n.periodTrip,
  ContributionPeriod.week => l10n.periodWeek,
  ContributionPeriod.month => l10n.periodMonth,
};

/// "50 EGP per child a week".
String contributionText(AppLocalizations l10n, Contribution c) => switch (c.period) {
  ContributionPeriod.trip => l10n.contributionPerTrip(c.amount),
  ContributionPeriod.week => l10n.contributionPerWeek(c.amount),
  ContributionPeriod.month => l10n.contributionPerMonth(c.amount),
};

/// "In 07:30 · Out 14:30".
String timesText(AppLocalizations l10n, String? morning, String? afternoon) => <String>[
  if (morning != null) l10n.carpoolMorningAt(morning),
  if (afternoon != null) l10n.carpoolAfternoonAt(afternoon),
].join(l10n.dotSeparator);

/// "Adam, grade 3".
String childText(AppLocalizations l10n, CarpoolChild c) {
  final grade = c.grade;
  return grade == null ? c.firstName : l10n.childWithGrade(c.firstName, gradeLabel(l10n, grade));
}

String childrenText(AppLocalizations l10n, List<CarpoolChild> children) =>
    children.map((CarpoolChild c) => childText(l10n, c)).join(l10n.listSeparator);
