import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/admin_app.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_router.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import 'test_app.dart';

/// Fake data only.
const AdminUser testReviewer = AdminUser(
  uid: 'admin1',
  email: 'reviewer@example.com',
  displayName: 'Reviewer Test',
  role: AdminRole.admin,
);
const AdminUser testSuperAdmin = AdminUser(
  uid: 'super1',
  email: 'super@example.com',
  displayName: 'Super Test',
  role: AdminRole.superAdmin,
);

final List<QueueCase> sampleQueue = <QueueCase>[
  QueueCase(
    caseId: 'case1',
    identity: true,
    submittedAt: DateTime(2026, 11, 13, 9, 30),
    kycResult: KycResult.match,
    children: 1,
    driver: false,
  ),
  QueueCase(
    caseId: 'case2',
    identity: true,
    submittedAt: DateTime(2026, 11, 13, 10, 5),
    kycResult: KycResult.noMatch,
    children: 2,
    driver: true,
  ),
];

final CaseDetail sampleCase = CaseDetail(
  caseId: 'case1',
  uid: 'parent1',
  identity: true,
  firstName: 'Mona',
  lastName: 'Hassan Test',
  idExpiry: '2030-01-31',
  liveness: LivenessChallenge.left,
  children: const <CaseChild>[
    CaseChild(childId: 'k1', firstName: 'Omar Hassan Test', age: 8, grade: Grade.g3, schoolName: 'Nile School', imageUrl: null),
  ],
  driver: null,
  kycResult: KycResult.match,
  kycScore: 0.93,
  submittedAt: DateTime(2026, 11, 13, 9, 30),
  images: const <String, String>{},
  decided: false,
);

final List<UserSummary> sampleUsers = <UserSummary>[
  UserSummary(
    uid: 'parent1',
    parentId: 'ABCD2345',
    firstName: 'Mona',
    lastName: 'Test',
    status: AccountStatus.verified,
    banned: false,
    maskedPhone: '+20********01',
    createdAt: DateTime(2026, 11),
  ),
];

const List<School> sampleSchools = <School>[
  School(
    id: 's1',
    nameAr: 'مدرسة النيل (تجريبية)',
    nameEn: 'Nile School (test)',
    governorate: 'cairo',
    city: 'Maadi',
    pin: GeoPin(29.9602, 31.2569),
    status: SchoolStatus.active,
    source: 'seed',
  ),
];

const List<School> sampleOtherSchools = <School>[
  School(
    id: 'p1',
    nameAr: 'مدرسه النيل الدوليه',
    nameEn: 'nile intl school',
    governorate: 'cairo',
    city: 'maadi',
    pin: null,
    status: SchoolStatus.awaitingReview,
    source: 'parent',
  ),
];

/// Records calls; answers with the sample data. [failure] makes every call fail.
class FakeAdminApi implements AdminApi {
  final List<String> calls = <String>[];
  final List<Map<String, Object?>> decisions = <Map<String, Object?>>[];
  final List<SchoolInput> savedSchools = <SchoolInput>[];
  final List<(String, ModerationAction, ModerationReason, String?)> moderations =
      <(String, ModerationAction, ModerationReason, String?)>[];
  AdminFailure? failure;
  List<QueueCase> queueItems = sampleQueue;
  List<UserSummary> users = sampleUsers;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<List<QueueCase>> queue() async {
    await _maybeFail('queue');
    return queueItems;
  }

  @override
  Future<CaseDetail> openCase(String caseId) async {
    await _maybeFail('openCase:$caseId');
    return sampleCase;
  }

  @override
  Future<void> decide({
    required String caseId,
    required bool approve,
    NameCheck? nameCheck,
    RejectionReason? reason,
    String? note,
    bool ban = false,
  }) async {
    await _maybeFail('decide');
    decisions.add(<String, Object?>{
      'caseId': caseId,
      'approve': approve,
      'nameCheck': nameCheck,
      'reason': reason,
      'note': note,
      'ban': ban,
    });
  }

  @override
  Future<List<UserSummary>> searchUsers(String query) async {
    await _maybeFail('search:$query');
    return users;
  }

  @override
  Future<UserDetail> user(String uid) async {
    await _maybeFail('user:$uid');
    return UserDetail(summary: users.first, maskedEmail: 'm***@example.com', cases: const <CaseHistory>[], actions: const <ActionHistory>[]);
  }

  @override
  Future<void> moderate({
    required String uid,
    required ModerationAction action,
    required ModerationReason reason,
    String? note,
  }) async {
    await _maybeFail('moderate');
    moderations.add((uid, action, reason, note));
  }

  @override
  Future<PagedResult<School>> schools({required SchoolStatus status, String? governorate, String? afterId}) async {
    await _maybeFail('schools:${status.code}');
    return PagedResult<School>(status == SchoolStatus.active ? sampleSchools : sampleOtherSchools, null);
  }

  @override
  Future<(School, List<Area>)> school(String id) async {
    await _maybeFail('school:$id');
    final School s = <School>[...sampleSchools, ...sampleOtherSchools].firstWhere((School s) => s.id == id);
    return (s, const <Area>[]);
  }

  @override
  Future<String> saveSchool(SchoolInput input) async {
    await _maybeFail('saveSchool');
    savedSchools.add(input);
    return input.id ?? 'new1';
  }

  @override
  Future<String> saveArea({
    required String schoolId,
    required String nameAr,
    required String nameEn,
    required GeoPin center,
    String? id,
  }) async {
    await _maybeFail('saveArea');
    return 'a1';
  }

  @override
  Future<void> approveSchool(SchoolInput input) async {
    await _maybeFail('approveSchool');
    savedSchools.add(input);
  }

  @override
  Future<int> mergeSchool({required String schoolId, required String intoId}) async {
    await _maybeFail('merge:$schoolId>$intoId');
    return 1;
  }

  @override
  Future<List<ReportItem>> reports() async {
    await _maybeFail('reports');
    return <ReportItem>[
      ReportItem(id: 'r1', targetType: 'user', targetId: 'p2', reason: 'spam', createdAt: DateTime(2026, 11, 13, 8)),
      ReportItem(id: 'r2', targetType: 'message', targetId: 'm2', reason: 'dangerousDriving', createdAt: DateTime(2026, 11, 13, 9), urgent: true, kind: 'carpool'),
    ];
  }

  /// Prompt 9: the chat report the report screen shows (fake data only).
  ReportDetail reportDetail = ReportDetail(
    id: 'r1',
    targetType: 'message',
    reason: 'dangerousDriving',
    urgent: true,
    open: true,
    kind: 'carpool',
    note: 'Speeding',
    subjectUid: 'p2',
    pausedDriving: true,
    outcome: null,
    createdAt: DateTime(2026, 11, 13, 8),
    context: <ReportContextMessage>[
      ReportContextMessage(id: 'm1', authorName: 'Hoda', authorParentId: 'HDAB2345', text: 'Before', attachment: null, createdAt: DateTime(2026, 11, 13, 7, 58), reported: false),
      ReportContextMessage(id: 'm2', authorName: 'Badr', authorParentId: 'BDRC2345', text: 'The reported one', attachment: null, createdAt: DateTime(2026, 11, 13, 7, 59), reported: true),
      ReportContextMessage(id: 'm3', authorName: 'Hoda', authorParentId: 'HDAB2345', text: '', attachment: 'image', createdAt: DateTime(2026, 11, 13, 8), reported: false),
    ],
  );

  ReportDetail _closed(String outcome) => ReportDetail(
    id: reportDetail.id,
    targetType: reportDetail.targetType,
    reason: reportDetail.reason,
    urgent: reportDetail.urgent,
    open: false,
    kind: reportDetail.kind,
    note: reportDetail.note,
    subjectUid: reportDetail.subjectUid,
    pausedDriving: reportDetail.pausedDriving,
    outcome: outcome,
    createdAt: reportDetail.createdAt,
    context: reportDetail.context,
  );

  @override
  Future<ReportDetail> report(String id) async {
    await _maybeFail('report:$id');
    return reportDetail;
  }

  @override
  Future<ReportDetail> removeReportedMessage(String id) async {
    await _maybeFail('removeMessage:$id');
    return reportDetail = _closed('message-removed');
  }

  @override
  Future<ReportDetail> removeReportedMember(String id) async {
    await _maybeFail('removeMember:$id');
    return reportDetail = _closed('member-removed');
  }

  @override
  Future<ReportDetail> resolveReport(String id, ReportOutcome outcome) async {
    await _maybeFail('resolve:$id:${outcome.name}');
    return reportDetail = _closed(outcome.name);
  }

  @override
  Future<ReportDetail> liftDrivingPause(String id) async {
    await _maybeFail('liftPause:$id');
    return reportDetail;
  }

  @override
  Future<PagedResult<AuditEntry>> audit({String? afterId}) async {
    await _maybeFail('audit');
    return PagedResult<AuditEntry>(<AuditEntry>[
      AuditEntry(
        id: 'l1',
        actorUid: 'admin1',
        actorName: 'Reviewer Test',
        action: 'verification.approve',
        target: 'verifications/case1',
        ip: null,
        time: DateTime(2026, 11, 13, 10),
      ),
      AuditEntry(
        id: 'l2',
        actorUid: 'admin1',
        actorName: 'Reviewer Test',
        action: 'school.create',
        target: 'schools/s1',
        ip: null,
        time: DateTime(2026, 11, 13, 10, 5),
      ),
    ], null);
  }

  @override
  Future<List<AdminAccount>> admins() async {
    await _maybeFail('admins');
    return const <AdminAccount>[
      AdminAccount(uid: 'super1', email: 'super@example.com', displayName: 'Super Test', role: AdminRole.superAdmin, disabled: false),
      AdminAccount(uid: 'admin1', email: 'reviewer@example.com', displayName: 'Reviewer Test', role: AdminRole.admin, disabled: false),
    ];
  }

  @override
  Future<String> createAdmin({required String email, required String displayName, required AdminRole role}) async {
    await _maybeFail('createAdmin');
    return 'https://example.test/setup';
  }

  @override
  Future<void> setAdminDisabled({required String uid, required bool disabled}) async {
    await _maybeFail('disable:$uid:$disabled');
  }

  int pings = 0;

  @override
  Future<void> ping() async {
    pings += 1;
  }
}

/// Two-step sign-in without Firebase.
class FakeAdminAuthRepository implements AdminAuthRepository {
  final List<String> calls = <String>[];
  bool needsCode = true;
  AdminFailure? failure;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<AdminSignInStep> signIn({required String email, required String password}) async {
    await _maybeFail('signIn:$email');
    return needsCode ? const AdminSignInNeedsCode() : const AdminSignInDone();
  }

  @override
  Future<void> verifyCode(String code) => _maybeFail('verifyCode:$code');

  @override
  Future<TotpSetup> startTotpSetup() async {
    await _maybeFail('startTotpSetup');
    return const TotpSetup(secretKey: 'JBSWY3DPEHPK3PXP', uri: 'otpauth://totp/test');
  }

  @override
  Future<void> finishTotpSetup(String code) => _maybeFail('finishTotpSetup:$code');

  @override
  Future<void> signOut() => _maybeFail('signOut');
}

/// The whole panel (AdminApp) at [location] with a fixed session and fakes.
Future<GoRouter> pumpAdminPanel(
  WidgetTester tester, {
  required AdminSessionState session,
  required String location,
  FakeAdminApi? api,
  FakeAdminAuthRepository? auth,
  String locale = 'ar',
  String themeMode = 'light',
  Size size = const Size(1280, 800),
  List<Override> extraOverrides = const <Override>[],
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.reset);
  final ValueNotifier<AdminSessionState> gate = ValueNotifier<AdminSessionState>(session);
  addTearDown(gate.dispose);
  final GoRouter router = buildAdminRouter(showDevTools: true, initialLocation: location, session: gate);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flavorConfigProvider.overrideWithValue(testDevConfig),
        settingsStoreProvider.overrideWithValue(
          InMemorySettingsStore(<String, String>{
            LocaleController.storageKey: locale,
            ThemeModeController.storageKey: themeMode,
          }),
        ),
        adminRouterProvider.overrideWithValue(router),
        adminSessionProvider.overrideWithValue(session),
        adminApiProvider.overrideWithValue(api ?? FakeAdminApi()),
        adminAuthRepositoryProvider.overrideWithValue(auth ?? FakeAdminAuthRepository()),
        ...extraOverrides,
      ],
      child: const AdminApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}
