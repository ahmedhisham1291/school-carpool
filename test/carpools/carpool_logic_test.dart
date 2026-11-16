// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_logic.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

import '../helpers/test_app.dart';

CarpoolMember _member(String uid, List<String> children, {int? seats, DateTime? until}) => CarpoolMember(
  uid: uid,
  firstName: uid,
  children: <CarpoolChild>[for (final String id in children) CarpoolChild(id: id, firstName: id, grade: Grade.g1)],
  car: seats == null ? null : CarpoolCar(seats: seats, validUntil: until ?? DateTime(2030)),
);

DriverConsent _ok(String parent, String driver, {bool accepted = true}) =>
    DriverConsent(parentUid: parent, driverUid: driver, accepted: accepted);

void main() {
  final DateTime today = DateTime(2026, 11, 14);

  group('driver consent (F26), same rules as the server', () {
    test('a member cannot drive other children until each parent accepted', () {
      final List<CarpoolMember> members = <CarpoolMember>[
        _member('alice', <String>['a1'], seats: 4),
        _member('bob', <String>['b1', 'b2'], seats: 6),
        _member('cara', <String>['c1']),
      ];
      DriverStatus s = driverStatus(members[1], members, const <DriverConsent>[], today);
      expect(s.canDrive, isFalse);
      expect(s.waitingFor, <String>['alice', 'cara']);
      s = driverStatus(members[1], members, <DriverConsent>[_ok('alice', 'bob'), _ok('cara', 'bob')], today);
      expect(s.canDrive, isTrue);
      s = driverStatus(members[1], members, <DriverConsent>[_ok('alice', 'bob'), _ok('cara', 'bob', accepted: false)], today);
      expect(s.canDrive, isFalse, reason: 'a withdrawn consent counts as none');
      expect(s.waitingFor, <String>['cara']);
    });

    test('no car, expired papers and too few passenger seats stop driving', () {
      final List<CarpoolMember> members = <CarpoolMember>[
        _member('alice', <String>['a1'], seats: 2),
        _member('bob', <String>['b1', 'b2'], seats: 6, until: DateTime(2026, 11, 13)),
        _member('cara', <String>['c1']),
      ];
      final List<DriverConsent> all = <DriverConsent>[
        for (final String p in <String>['alice', 'bob', 'cara'])
          for (final String d in <String>['alice', 'bob', 'cara'])
            if (p != d) _ok(p, d),
      ];
      expect(driverStatus(members[0], members, all, today).problem, DriverProblem.carTooSmall);
      expect(driverStatus(members[1], members, all, today).problem, DriverProblem.carExpired);
      expect(driverStatus(members[2], members, all, today).problem, DriverProblem.noCar);
    });

    test('a car valid until today still drives today', () {
      final List<CarpoolMember> members = <CarpoolMember>[_member('alice', <String>['a1'], seats: 4, until: today)];
      expect(driverStatus(members[0], members, const <DriverConsent>[], today).canDrive, isTrue);
    });
  });

  group('seats', () {
    test('a creator offers at most the car passenger seats', () {
      expect(seatChoices(4), <int>[1, 2, 3, 4]);
      expect(seatChoices(0), isEmpty);
    });

    test('children must fit the free seats', () {
      expect(fitsSeats(2, 3), isTrue);
      expect(fitsSeats(3, 2), isFalse);
      expect(fitsSeats(0, 2), isFalse);
      expect(childrenIn(<CarpoolMember>[_member('a', <String>['1']), _member('b', <String>['2', '3'])]), 3);
    });

    test('seats left never goes below zero', () {
      final Carpool full = Carpool.fromDoc('k', const <String, Object?>{'seats': 2, 'childrenCount': 3});
      expect(full.seatsLeft, 0);
    });
  });

  group('parsing', () {
    test('a carpool document, closed or active, with rules and contribution', () {
      final Carpool c = Carpool.fromDoc('k1', <String, Object?>{
        'kind': 'school',
        'schoolId': 'nile',
        'schoolNameAr': 'النيل',
        'schoolNameEn': 'Nile',
        'areaId': 'degla',
        'areaNameEn': 'Degla',
        'morning': '07:30',
        'afternoon': null,
        'days': const <Object?>['thu', 'sun', 'xyz'],
        'seats': 4,
        'childrenCount': 1,
        'memberCount': 1,
        'rules': const <Object?>['seat_belts', 'no_smoking', 'loud'],
        'contribution': const <String, Object?>{'amount': 50, 'period': 'week', 'note': 'Fuel'},
        'creatorFirstName': 'Hoda',
        'status': 'closed',
        'createdAt': Timestamp.fromMillisecondsSinceEpoch(0),
      });
      expect(c.days, <Weekday>[Weekday.sun, Weekday.thu]);
      expect(c.rules, <CarpoolRule>[CarpoolRule.noSmoking, CarpoolRule.seatBelts]);
      expect(c.contribution?.amount, 50);
      expect(c.contribution?.period, ContributionPeriod.week);
      expect(c.afternoon, isNull);
      expect(c.active, isFalse);
      expect(c.seatsLeft, 3);
      expect(c.title('ar'), 'النيل');
      expect(c.areaName('ar'), 'Degla', reason: 'falls back to the other language');
    });

    test('a search result', () {
      final Carpool c = Carpool.fromSearch(const <Object?, Object?>{
        'id': 'k2',
        'kind': 'activity',
        'activityName': 'Swimming',
        'seats': 4,
        'seatsLeft': 1,
        'myStatus': 'requested',
        'distanceKm': 2,
      });
      expect(c.kind, CarpoolKind.activity);
      expect(c.title('en'), 'Swimming');
      expect(c.seatsLeft, 1);
      expect(c.myStatus, MembershipStatus.requested);
      expect(c.distanceKm, 2);
    });

    test('members, requests and consents', () {
      final CarpoolMember m = CarpoolMember.fromDoc('bob', const <String, Object?>{
        'firstName': 'Bob',
        'role': 'admin',
        'children': <Object?>[
          <String, Object?>{'id': 'b1', 'firstName': 'Bassel', 'grade': 'kg2'},
        ],
        'car': <String, Object?>{'seats': 6, 'validUntil': '2029-05-01'},
        'pickupShared': true,
      });
      expect(m.isAdmin, isTrue);
      expect(m.children.single.grade, Grade.kg2);
      expect(m.car?.seats, 6);
      expect(m.car?.validUntil, DateTime(2029, 5));
      expect(m.pickupShared, isTrue);
      expect(JoinRequest.fromDoc('cara', const <String, Object?>{'firstName': 'Cara'}).hasCar, isFalse);
      expect(DriverConsent.fromDoc(const <String, Object?>{'parentUid': 'a', 'driverUid': 'b', 'status': 'withdrawn'}).accepted, isFalse);
      expect(Membership.fromDoc(const <String, Object?>{'carpoolId': 'k', 'status': 'weird'}).status, MembershipStatus.left);
    });

    test('a draft sends what createCarpool expects', () {
      const CarpoolDraft draft = CarpoolDraft(
        kind: CarpoolKind.activity,
        activity: ActivityPlace(name: 'Swimming', label: 'Club', lat: 29.96, lng: 31.27),
        morning: '07:30',
        days: <Weekday>[Weekday.sun, Weekday.tue],
        driveDays: <Weekday>[Weekday.sun],
        seats: 3,
        childIds: <String>['c1'],
        rules: <CarpoolRule>[CarpoolRule.wait5Min],
        contribution: Contribution(amount: 20, period: ContributionPeriod.trip),
      );
      final Map<String, Object?> json = draft.toJson();
      expect(json['kind'], 'activity');
      expect(json.containsKey('schoolId'), isFalse);
      expect(json['afternoon'], isNull);
      expect(json['days'], <String>['sun', 'tue']);
      expect(json['rules'], <String>['wait_5_min']);
      expect((json['activity']! as Map<String, Object?>)['name'], 'Swimming');
      expect((json['contribution']! as Map<String, Object?>)['period'], 'trip');
    });
  });

  group('times', () {
    test('choices every 15 minutes from 06:00 to 18:00', () {
      final List<String> choices = RunTime.choices();
      expect(choices.first, '06:00');
      expect(choices.last, '18:00');
      expect(choices, contains('07:30'));
      expect(choices.length, 49);
      expect(RunTime.minutes('07:30'), 450);
      expect(RunTime.minutes('7:30'), isNull);
    });
  });

  group('invite links (F31)', () {
    test('the code comes from /c/<code>, upper case, and nothing else', () {
      expect(inviteCodeFromPath('/c/ABCDEFGH23'), 'ABCDEFGH23');
      expect(inviteCodeFromPath('/c/abcdefgh23/'), 'ABCDEFGH23');
      expect(inviteCodeFromPath('/c/ABCDEFGH2'), isNull);
      expect(inviteCodeFromPath('/c/ABCDEFGH0O'), isNull, reason: 'no 0 or O');
      expect(inviteCodeFromPath('/carpools/k1'), isNull);
      expect(inviteCodeFromPath('/carpools/invite/ABCDEFGH23'), 'ABCDEFGH23');
      expect(CarpoolRoutes.link('ABCDEFGH23'), '/c/ABCDEFGH23');
      expect(CarpoolRoutes.invite('ABCDEFGH23'), '/carpools/invite/ABCDEFGH23');
    });

    test('the link screen is open to signed-in parents (it says to verify first); signed out goes to Welcome', () {
      expect(sessionRedirect(testVerifiedSession, '/c/ABCDEFGH23'), isNull);
      expect(sessionRedirect(testUnverifiedSession, '/c/ABCDEFGH23'), isNull);
      expect(sessionRedirect(testUnverifiedSession, '/carpools/invite/ABCDEFGH23'), isNull);
      expect(sessionRedirect(const SessionSignedOut(), '/c/ABCDEFGH23'), AuthRoutes.welcome);
      expect(sessionRedirect(testEmailStageSession, '/c/ABCDEFGH23'), AuthRoutes.email);
      // The carpool screens themselves stay verified-only.
      expect(sessionRedirect(testUnverifiedSession, '/carpools/k1'), AuthRoutes.verifyFor('/carpools/k1'));
    });

    test('routes for Join and for a match', () {
      expect(
        CarpoolRoutes.searchParent(schoolId: 'nile', parentUid: 'p1', parentName: 'Hoda'),
        '/carpools/search?school=nile&parent=p1&name=Hoda',
      );
      expect(
        CarpoolRoutes.createFrom(schoolId: 'nile', morning: '07:30', days: <Weekday>[Weekday.sun, Weekday.mon]),
        '/carpools/new?school=nile&morning=07%3A30&days=sun%2Cmon',
      );
    });
  });
}
