// Trust logic (Prompt 11, F17): rating rules, papers notices, the yearly
// check's answers, parsing and failures. Written, not run here (no Flutter
// SDK in the build workspace). CI runs it.
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

TrustFailure _failure(String reason, {String code = 'failed-precondition', Map<String, Object?> extra = const <String, Object?>{}}) =>
    TrustFailure.from(FirebaseFunctionsException(message: reason, code: code, details: <String, Object?>{'reason': reason, ...extra}));

void main() {
  group('ratings', () {
    test('vouching only with 4 or 5 stars and no concern; low stars or unsafe driving reach the admins', () {
      expect(RatingRules.canVouch(5, <RatingTag>{RatingTag.onTime}), isTrue);
      expect(RatingRules.canVouch(4, <RatingTag>{}), isTrue);
      expect(RatingRules.canVouch(3, <RatingTag>{}), isFalse);
      expect(RatingRules.canVouch(5, <RatingTag>{RatingTag.late}), isFalse);
      expect(RatingRules.goesToAdmins(2, <RatingTag>{}), isTrue);
      expect(RatingRules.goesToAdmins(5, <RatingTag>{RatingTag.unsafeDriving}), isTrue);
      expect(RatingRules.goesToAdmins(4, <RatingTag>{RatingTag.late}), isFalse);
    });

    test('tag codes match the server (functions/src/trust/model.ts)', () {
      expect(RatingTag.values.map((RatingTag t) => t.wire), <String>['on-time', 'safe-driving', 'friendly', 'clear', 'late', 'unsafe-driving', 'rude']);
      expect(RatingTag.values.where((RatingTag t) => t.concern), <RatingTag>[RatingTag.late, RatingTag.unsafeDriving, RatingTag.rude]);
    });

    test('a rating sends stars, tag codes and the vouch only', () {
      const RatingDraft d = RatingDraft(uid: 'uid-hoda', stars: 5, tags: <RatingTag>{RatingTag.onTime, RatingTag.clear}, vouch: true);
      expect(d.toJson(), <String, Object?>{
        'uid': 'uid-hoda',
        'stars': 5,
        'tags': <String>['on-time', 'clear'],
        'vouch': true,
      });
    });

    test('summary line: count until 3 ratings, then the average', () {
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(summaryLine(en, const TrustSummary()), 'No ratings yet');
      expect(summaryLine(en, const TrustSummary(ratings: 2, vouches: 1)), '2 ratings · 1 vouch');
      expect(summaryLine(en, const TrustSummary(ratings: 5, average: 4.6)), '4.6 from 5 ratings · no vouches');
    });
  });

  group('parsing', () {
    test('overview, year check and family from the functions', () {
      final TrustOverview o = TrustOverview.fromMap(const <Object?, Object?>{
        'summary': <Object?, Object?>{'ratings': 3, 'average': 4.3, 'vouches': 1},
        'toRate': 2,
        'requests': 1,
        'yearCheck': <Object?, Object?>{
          'state': 'overdue',
          'year': 2027,
          'deadline': '2027-09-15',
          'children': <Object?>[
            <Object?, Object?>{'id': 'k1', 'firstName': 'Omar', 'grade': 'g3', 'schoolName': 'Nile'},
          ],
        },
      });
      expect(o.summary.average, 4.3);
      expect(o.toRate, 2);
      expect(o.requests, 1);
      expect(o.yearCheck.state, YearCheckState.overdue);
      expect(o.yearCheck.open, isTrue);
      expect(o.yearCheck.deadline, DateTime.utc(2027, 9, 15));
      expect(o.yearCheck.children.single.grade, Grade.g3);
      expect(TrustOverview.fromMap(const <Object?, Object?>{}).yearCheck.state, YearCheckState.none);
      final FamilyView f = FamilyView.fromMap(const <Object?, Object?>{
        'incoming': <Object?>[<Object?, Object?>{'id': 'a_b', 'guardianFirstName': 'Dina', 'relation': 'mother'}],
        'linked': <Object?>[<Object?, Object?>{'id': 'k1_b', 'childFirstName': 'Omar', 'status': 'review', 'relation': 'uncle'}],
      });
      expect(f.incoming.single.relation, Relation.mother);
      expect(f.linked.single.status, LinkStatus.review);
      expect(f.linked.single.relation, Relation.guardian);
      expect(f.isEmpty, isFalse);
      expect(const FamilyView().isEmpty, isTrue);
      final RateableParent p = RateableParent.fromMap(const <Object?, Object?>{'uid': 'u', 'firstName': 'Hoda', 'role': 'driver', 'date': '2026-11-12'});
      expect(p.drove, isTrue);
      expect(p.date, DateTime.utc(2026, 11, 12));
    });
  });

  group('papers (spec section 3)', () {
    final DateTime today = DateTime.utc(2026, 11, 14);
    test('fine, soon within 30 days of the earlier date, expired after the last valid day', () {
      expect(papersNotice(null, null, today), isA<PapersFine>());
      expect(papersNotice(DateTime(2027, 6), DateTime(2027, 8), today), isA<PapersFine>());
      final PapersNotice soon = papersNotice(DateTime(2027, 6), DateTime(2026, 11, 21), today);
      expect(soon, isA<PapersExpireSoon>());
      expect((soon as PapersExpireSoon).days, 7);
      expect((papersNotice(DateTime(2026, 11, 14), null, today) as PapersExpireSoon).days, 0);
      expect(papersNotice(DateTime(2026, 11, 13), DateTime(2030), today), isA<PapersExpired>());
    });
  });

  group('yearly check', () {
    const List<YearChild> kids = <YearChild>[
      YearChild(id: 'k1', firstName: 'Omar', grade: Grade.g3, schoolName: 'Nile'),
      YearChild(id: 'k2', firstName: 'Mai', grade: Grade.g12, schoolName: 'Nile'),
    ];

    test('every child answered, with a grade for each who stays', () {
      expect(yearAnswersComplete(kids, const <String, YearAnswer>{}), isFalse);
      expect(
        yearAnswersComplete(kids, const <String, YearAnswer>{
          'k1': YearAnswer(childId: 'k1', stays: true, grade: Grade.g4),
          'k2': YearAnswer(childId: 'k2', stays: false),
        }),
        isTrue,
      );
      expect(
        yearAnswersComplete(kids, const <String, YearAnswer>{
          'k1': YearAnswer(childId: 'k1', stays: true),
          'k2': YearAnswer(childId: 'k2', stays: false),
        }),
        isFalse,
      );
      expect(yearAnswersComplete(const <YearChild>[], const <String, YearAnswer>{}), isFalse);
    });

    test('the next grade is preselected; grade 12 stays', () {
      expect(nextGrade(Grade.kg2), Grade.g1);
      expect(nextGrade(Grade.g12), Grade.g12);
      expect(const YearAnswer(childId: 'k2', stays: false, grade: Grade.g4).toJson(), <String, Object?>{'childId': 'k2', 'stays': false});
      expect(const YearAnswer(childId: 'k1', stays: true, grade: Grade.g4).toJson(), <String, Object?>{'childId': 'k1', 'stays': true, 'grade': 'g4'});
    });

    test('school year label', () {
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(schoolYearLabel(en, 2027), 'School year 2027/28');
      expect(schoolYearLabel(en, 2099), 'School year 2099/00');
    });
  });

  group('failures', () {
    test('server reasons map to kinds with a message; code problems use the sign-in messages', () {
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(_failure('already-rated').kind, TrustFailureKind.alreadyRated);
      expect(_failure('no-shared-trip').kind, TrustFailureKind.noSharedTrip);
      expect(_failure('children-changed').kind, TrustFailureKind.changed);
      expect(_failure('selfie-mismatch').kind, TrustFailureKind.selfieMismatch);
      expect(_failure('phone-taken').kind, TrustFailureKind.phoneTaken);
      final TrustFailure code = _failure('wrong-code', code: 'invalid-argument', extra: <String, Object?>{'attemptsLeft': 2});
      expect(code.kind, TrustFailureKind.code);
      expect(code.auth?.kind, AuthFailureKind.wrongCode);
      expect(code.message(en), AuthFailure.from(FirebaseFunctionsException(message: 'x', code: 'invalid-argument', details: <String, Object?>{'reason': 'wrong-code', 'attemptsLeft': 2})).message(en));
      expect(TrustFailure.from(FirebaseFunctionsException(message: 'x', code: 'unavailable')).isOffline, isTrue);
      expect(TrustFailure.from(StateError('x')).kind, TrustFailureKind.unknown);
      for (final TrustFailureKind k in TrustFailureKind.values) {
        expect(TrustFailure(k).message(en), isNotEmpty, reason: k.name);
      }
    });
  });
}
