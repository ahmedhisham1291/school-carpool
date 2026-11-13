import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

import 'schedule_fakes.dart';

/// Fake carpools for widget tests (fake data only). Calls are recorded in
/// [calls]; [failure] makes every call fail; streams follow [emit].
const Carpool testCarpool = Carpool(
  id: 'k1',
  kind: CarpoolKind.school,
  schoolId: 'nile',
  schoolNameAr: 'مدرسة النيل الدولية',
  schoolNameEn: 'Nile International School',
  areaId: 'degla',
  areaNameAr: 'دجلة',
  areaNameEn: 'Degla',
  activityName: '',
  activityLabel: '',
  morning: '07:30',
  afternoon: '14:30',
  days: Weekday.schoolDays,
  seats: 4,
  childrenCount: 1,
  memberCount: 1,
  rules: <CarpoolRule>[CarpoolRule.noSmoking, CarpoolRule.seatBelts],
  contribution: Contribution(amount: 50, period: ContributionPeriod.week, note: 'Fuel share'),
  creatorFirstName: 'Hoda',
);

const CarpoolMember testMe = CarpoolMember(
  uid: 'uid-1',
  firstName: 'Mona',
  children: <CarpoolChild>[CarpoolChild(id: 'c1', firstName: 'Adam', grade: Grade.g3)],
);

class FakeCarpoolRepository implements CarpoolRepository {
  FakeCarpoolRepository({
    List<Carpool> carpools = const <Carpool>[testCarpool],
    this.results = const <Carpool>[testCarpool],
    List<Membership> memberships = const <Membership>[],
    this.members = const <CarpoolMember>[],
    this.consents = const <DriverConsent>[],
    this.requests = const <JoinRequest>[],
    this.areaList = const <SchoolArea>[SchoolArea(id: 'degla', nameAr: 'دجلة', nameEn: 'Degla')],
    this.wanted = const WantedList(posts: <WantedPost>[]),
  }) : _carpools = <String, Carpool>{for (final Carpool c in carpools) c.id: c},
       _memberships = List<Membership>.of(memberships);

  final Map<String, Carpool> _carpools;
  final List<Membership> _memberships;
  List<Carpool> results;
  List<CarpoolMember> members;
  List<DriverConsent> consents;
  List<JoinRequest> requests;
  List<SchoolArea> areaList;
  WantedList wanted;
  CarpoolFailure? failure;
  CarpoolFailure? searchFailure;
  final List<String> calls = <String>[];
  final List<CarpoolQuery> searches = <CarpoolQuery>[];
  CarpoolDraft? created;
  WantedDraft? savedWanted;
  String inviteCarpoolId = 'k1';
  final StreamController<int> _changes = StreamController<int>.broadcast();

  void _maybeFail(String call) {
    calls.add(call);
    final CarpoolFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  /// Notifies every open stream (after a test changes the fields).
  void emit() => _changes.add(0);

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    await for (final int _ in _changes.stream) {
      yield read();
    }
  }

  void _setMembership(String carpoolId, MembershipStatus status) {
    _memberships
      ..removeWhere((Membership m) => m.carpoolId == carpoolId)
      ..add(Membership(carpoolId: carpoolId, status: status));
    emit();
  }

  @override
  Stream<List<Membership>> myMemberships(String uid) => _watch(() => List<Membership>.of(_memberships));

  @override
  Stream<Carpool?> watchCarpool(String carpoolId) => _watch(() => _carpools[carpoolId]);

  @override
  Stream<List<CarpoolMember>> watchMembers(String carpoolId) => _watch(() => members);

  @override
  Stream<List<DriverConsent>> watchConsents(String carpoolId) => _watch(() => consents);

  @override
  Stream<List<JoinRequest>> watchRequests(String carpoolId) => _watch(() => requests);

  @override
  Stream<Membership?> watchMyMembership(String carpoolId, String uid) =>
      _watch(() => _memberships.where((Membership m) => m.carpoolId == carpoolId).firstOrNull);

  @override
  Future<List<SchoolArea>> areas(String schoolId) async => areaList;

  @override
  Future<String> create(CarpoolDraft draft) async {
    _maybeFail('create');
    created = draft;
    _carpools['new1'] = testCarpool;
    _memberships.add(const Membership(carpoolId: 'new1', status: MembershipStatus.approved, isAdmin: true));
    emit();
    return 'new1';
  }

  @override
  Future<List<Carpool>> search(CarpoolQuery query) async {
    searches.add(query);
    final CarpoolFailure? f = searchFailure ?? failure;
    if (f != null) {
      throw f;
    }
    return results;
  }

  @override
  Future<void> requestToJoin({required String carpoolId, required List<String> childIds, required bool acceptContribution}) async {
    _maybeFail('join:$carpoolId:${childIds.join(',')}:$acceptContribution');
    _setMembership(carpoolId, MembershipStatus.requested);
  }

  @override
  Future<void> cancelRequest(String carpoolId) async {
    _maybeFail('cancel:$carpoolId');
    _setMembership(carpoolId, MembershipStatus.left);
  }

  @override
  Future<void> decide({required String carpoolId, required String uid, required bool approve}) async {
    _maybeFail('decide:$uid:$approve');
    requests = requests.where((JoinRequest r) => r.uid != uid).toList();
    emit();
  }

  @override
  Future<void> leave(String carpoolId) async {
    _maybeFail('leave:$carpoolId');
    _setMembership(carpoolId, MembershipStatus.left);
  }

  @override
  Future<void> setConsent({required String carpoolId, required String driverUid, required bool accept}) async {
    _maybeFail('consent:$driverUid:$accept');
    consents = <DriverConsent>[
      for (final DriverConsent c in consents)
        if (!(c.parentUid == 'uid-1' && c.driverUid == driverUid)) c,
      DriverConsent(parentUid: 'uid-1', driverUid: driverUid, accepted: accept),
    ];
    emit();
  }

  @override
  Future<void> setPickupSharing({required String carpoolId, required bool share}) async {
    _maybeFail('pickup:$share');
  }

  @override
  Future<CarpoolInvite> createInvite(String carpoolId) async {
    _maybeFail('invite:$carpoolId');
    return const CarpoolInvite(code: 'ABCDEFGH23', url: 'https://links.example/c/ABCDEFGH23');
  }

  @override
  Future<String> openInvite(String code) async {
    _maybeFail('open:$code');
    return inviteCarpoolId;
  }

  @override
  Future<WantedList> listWanted({required String schoolId, String? areaId}) async {
    _maybeFail('listWanted:$schoolId');
    return wanted;
  }

  @override
  Future<void> saveWanted(WantedDraft draft) async {
    _maybeFail('saveWanted');
    savedWanted = draft;
  }

  @override
  Future<void> deleteWanted() async => _maybeFail('deleteWanted');

  Future<void> dispose() => _changes.close();
}

class FakeLinkSharer implements LinkSharer {
  FakeLinkSharer({this.whatsAppOpens = true});

  bool whatsAppOpens;
  final List<String> shared = <String>[];
  final List<String> copied = <String>[];

  @override
  Future<bool> shareOnWhatsApp(String text) async {
    shared.add(text);
    return whatsAppOpens;
  }

  @override
  Future<void> copy(String text) async => copied.add(text);
}

/// Keeps Firebase and WhatsApp out of widget tests. The schedule fake and
/// a fixed clock ([testNow]) are always part of it (Prompt 7), so the
/// number of overrides never changes between pumps.
List<Override> carpoolOverrides({CarpoolRepository? carpools, LinkSharer? sharer, ScheduleRepository? schedule}) => <Override>[
  carpoolRepositoryProvider.overrideWithValue(carpools ?? FakeCarpoolRepository()),
  linkSharerProvider.overrideWithValue(sharer ?? FakeLinkSharer()),
  scheduleRepositoryProvider.overrideWithValue(schedule ?? FakeScheduleRepository()),
  scheduleClockProvider.overrideWithValue(() => testNow),
];
