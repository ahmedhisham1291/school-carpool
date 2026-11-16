import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/admin_app.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/admin_places.dart';
import 'package:school_carpool/admin/data/admin_trust.dart';
import 'package:school_carpool/admin/data/admin_wallet.dart';
import 'package:school_carpool/admin/data/school_filters.dart';
import 'package:school_carpool/admin/router/admin_router.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/settings/app_settings.dart';
import 'package:school_carpool/settings/settings_store.dart';

import 'place_fakes.dart';
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
  /// The area filter of each schools() call.
  final List<String?> schoolAreaFilters = <String?>[];

  /// The filters of each searchSchools() call (first pages and "Load more").
  final List<SchoolFilters> schoolSearches = <SchoolFilters>[];

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
    return UserDetail(
      summary: users.first,
      maskedEmail: 'm***@example.com',
      cases: const <CaseHistory>[],
      actions: const <ActionHistory>[],
      deviceCheckSince: deviceCheckSince,
    );
  }

  /// Prompt 13: an open new-phone check on the user page.
  DateTime? deviceCheckSince;
  final List<(String, DeviceCheckOutcome, AccessReasonCode)> deviceDecisions = <(String, DeviceCheckOutcome, AccessReasonCode)>[];

  @override
  Future<List<AdminPhoto>> userPhotos(String uid, AccessReasonCode reason) async {
    await _maybeFail('photos:$uid:${reason.name}');
    return const <AdminPhoto>[
      AdminPhoto(kind: 'faceRef', url: 'https://example.test/face.webp', storedAt: null),
      AdminPhoto(kind: 'selfie', url: 'https://example.test/selfie.webp', storedAt: null),
    ];
  }

  @override
  Future<void> decideDeviceCheck({required String uid, required DeviceCheckOutcome outcome, required AccessReasonCode reason}) async {
    await _maybeFail('deviceCheck');
    deviceDecisions.add((uid, outcome, reason));
    deviceCheckSince = null;
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
  Future<PagedResult<School>> schools({required SchoolStatus status, String? governorate, String? afterId, String? placeAreaId}) async {
    schoolAreaFilters.add(placeAreaId);
    await _maybeFail('schools:${status.code}');
    return PagedResult<School>(status == SchoolStatus.active ? sampleSchools : sampleOtherSchools, null);
  }

  @override
  Future<SchoolSearchPage> searchSchools(SchoolFilters filters, {required String languageCode, String? afterId}) async {
    schoolSearches.add(filters);
    await _maybeFail('searchSchools');
    final String q = filters.query.trim().toLowerCase();
    final List<School> found = <School>[
      for (final School s in <School>[...sampleSchools, if (filters.includeAll) ...sampleOtherSchools])
        if ((q.isEmpty || s.nameEn.toLowerCase().contains(q) || s.nameAr.contains(q)) &&
            (filters.city == null || s.governorate == filters.city) &&
            (filters.areaId == null || s.placeAreaId == filters.areaId) &&
            (filters.status == null || s.status == filters.status))
          s,
    ];
    return SchoolSearchPage(items: found, nextAfterId: null, total: afterId == null ? found.length : null);
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
  FakeAdminWalletApi? wallet,
  FakeAdminTrustApi? trust,
  FakeAdminFeaturesApi? features,
  FakeAdminPlacesApi? places,
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
        adminWalletApiProvider.overrideWithValue(wallet ?? FakeAdminWalletApi()),
        adminTrustApiProvider.overrideWithValue(trust ?? FakeAdminTrustApi()),
        adminFeaturesApiProvider.overrideWithValue(features ?? FakeAdminFeaturesApi()),
        adminPlacesApiProvider.overrideWithValue(places ?? FakeAdminPlacesApi()),
        ...extraOverrides,
      ],
      child: const AdminApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}

/// Prompt 11B: the admin wallet functions (fake data only). There is no
/// money method to fake: the panel cannot move money.
class FakeAdminWalletApi implements AdminWalletApi {
  final List<String> calls = <String>[];
  AdminFailure? failure;
  AdminWallet one = AdminWallet(
    uid: 'u-ali',
    status: 'active',
    balance: 50000,
    balanceCopy: 50000,
    transfers: <AdminTransfer>[
      AdminTransfer(id: 't_1', kind: 'transfer', amount: 12550, status: 'done', fromUid: 'u-ali', toUid: 'u-hoda', fromFirstName: 'Ali', toFirstName: 'Hoda', createdAt: DateTime.utc(2026, 11, 16, 8)),
    ],
    partnerTransactions: <PartnerTransaction>[PartnerTransaction(requestId: 't_1', signedAmount: -12550, status: 'done', at: DateTime.utc(2026, 11, 16, 8))],
  );
  List<WalletAlert> open = <WalletAlert>[
    WalletAlert(id: 'new-receivers_u-ali_1', kind: 'new-receivers', uid: 'u-ali', count: 4, createdAt: DateTime.utc(2026, 11, 16, 9)),
  ];
  (bool, FreezeReason, String?)? frozenWith;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<PagedResult<AdminTransfer>> transfers({String? uid, String? afterId}) async {
    await _maybeFail('transfers:${uid ?? ''}');
    return PagedResult<AdminTransfer>(one.transfers, null);
  }

  @override
  Future<AdminWallet> wallet(String uid) async {
    await _maybeFail('wallet:$uid');
    return one;
  }

  @override
  Future<void> setFrozen({required String uid, required bool frozen, required FreezeReason reason, String? note}) async {
    await _maybeFail('setFrozen:$uid:$frozen');
    frozenWith = (frozen, reason, note);
    one = AdminWallet(uid: one.uid, status: frozen ? 'frozen' : 'active', frozenReason: frozen ? reason : null, balance: one.balance, transfers: one.transfers);
  }

  @override
  Future<List<WalletAlert>> alerts({bool handled = false}) async {
    await _maybeFail('alerts');
    return open;
  }

  @override
  Future<void> resolveAlert(String alertId, AlertOutcome outcome) async {
    await _maybeFail('resolve:$alertId:${outcome.name}');
    open = <WalletAlert>[for (final WalletAlert a in open) if (a.id != alertId) a];
  }
}

/// Prompt 11: the admin trust functions (fake data only).
class FakeAdminTrustApi implements AdminTrustApi {
  final List<String> calls = <String>[];
  AdminFailure? failure;
  List<ReviewLink> links = <ReviewLink>[
    ReviewLink(
      id: 'k9_u-dina',
      childFirstName: 'Laila',
      ownerFirstName: 'Sami',
      guardianFirstName: 'Dina',
      guardianUid: 'u-dina',
      relation: 'guardian',
      createdAt: DateTime.utc(2026, 11, 16, 9),
    ),
  ];
  List<RatingFlagItem> flags = <RatingFlagItem>[
    RatingFlagItem(
      id: '2026-11_u-hoda_u-ali',
      stars: 2,
      tags: const <String>['late', 'unsafe-driving'],
      rateeUid: 'u-ali',
      rateeFirstName: 'Ali',
      raterFirstName: 'Hoda',
      createdAt: DateTime.utc(2026, 11, 16, 10),
    ),
  ];

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<TrustQueue> queue() async {
    await _maybeFail('queue');
    return TrustQueue(links: links, flags: flags);
  }

  @override
  Future<void> decideLink({required String linkId, required bool approve}) async {
    await _maybeFail('decideLink:$linkId:$approve');
    links = <ReviewLink>[for (final ReviewLink l in links) if (l.id != linkId) l];
  }

  @override
  Future<void> resolveFlag({required String flagId, required FlagOutcome outcome}) async {
    await _maybeFail('resolveFlag:$flagId:${outcome.wire}');
    flags = <RatingFlagItem>[for (final RatingFlagItem f in flags) if (f.id != flagId) f];
  }
}

/// Pilot feature switches and one parent's settle-up records (fake data
/// only). Starts with the pilot defaults, like a project with no
/// config/features document.
class FakeAdminFeaturesApi implements AdminFeaturesApi {
  final List<String> calls = <String>[];
  AdminFailure? failure;
  FeatureSwitches switches = FeatureSwitches.pilot;
  List<AdminSettleRecord> records = <AdminSettleRecord>[
    AdminSettleRecord(id: 's_1', payee: true, otherFirstName: 'Hoda', amount: 15000, reason: 'contribution', status: 'open', notReceived: 2, reported: true, createdAt: DateTime.utc(2026, 11, 16, 8)),
    AdminSettleRecord(id: 's_2', payee: false, otherFirstName: 'Badr', amount: 8000, reason: 'fuel', status: 'closed', createdAt: DateTime.utc(2026, 11, 15, 8)),
  ];

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AdminFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<FeatureSwitches> features() async {
    await _maybeFail('features');
    return switches;
  }

  @override
  Future<FeatureSwitches> setFeature(AppFeature feature, {required bool on}) async {
    await _maybeFail('setFeature:${feature.name}:$on');
    switches = switch (feature) {
      AppFeature.wallet => switches.copyWith(wallet: on),
      AppFeature.ratingsAndVouching => switches.copyWith(ratingsAndVouching: on),
      AppFeature.yearlyChecks => switches.copyWith(yearlyChecks: on),
      AppFeature.settleUp => switches.copyWith(settleUp: on),
      AppFeature.contributions => switches.copyWith(contributions: on),
      AppFeature.activityCarpools => switches.copyWith(activityCarpools: on),
    };
    return switches;
  }

  @override
  Future<List<AdminSettleRecord>> settleUps({required String uid, required AccessReasonCode reason}) async {
    await _maybeFail('settleUps:$uid:${reason.name}');
    return records;
  }

  /// R5: prod, closed until the PDPC licences are granted.
  AdminLaunch launchValue = const AdminLaunch(pdpcLicensed: false, signUpOpen: false, env: 'prod');

  @override
  Future<AdminLaunch> launch() async {
    await _maybeFail('launch');
    return launchValue;
  }

  @override
  Future<AdminLaunch> setLaunch({required bool pdpcLicensed, String licenceRefs = ''}) async {
    await _maybeFail('setLaunch:$pdpcLicensed:$licenceRefs');
    launchValue = AdminLaunch(pdpcLicensed: pdpcLicensed, signUpOpen: pdpcLicensed, env: launchValue.env);
    return launchValue;
  }
}
