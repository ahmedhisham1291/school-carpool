import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Everything the admin panel reads or changes goes through the admin
/// Cloud Functions (F14). The panel never reads or writes Firestore or
/// Storage directly. Every method throws [AdminFailure].
abstract interface class AdminApi {
  Future<List<QueueCase>> queue();
  Future<CaseDetail> openCase(String caseId);
  Future<void> decide({
    required String caseId,
    required bool approve,
    NameCheck? nameCheck,
    RejectionReason? reason,
    String? note,
    bool ban = false,
  });

  Future<List<UserSummary>> searchUsers(String query);
  Future<UserDetail> user(String uid);

  /// Prompt 13: the face reference and kept selfies (logged with [reason]).
  Future<List<AdminPhoto>> userPhotos(String uid, AccessReasonCode reason);

  /// Prompt 13: closes an open new-phone check (logged with [reason]).
  Future<void> decideDeviceCheck({required String uid, required DeviceCheckOutcome outcome, required AccessReasonCode reason});
  Future<void> moderate({
    required String uid,
    required ModerationAction action,
    required ModerationReason reason,
    String? note,
  });

  /// [placeAreaId] narrows to one area of the city (placeAreas).
  Future<PagedResult<School>> schools({required SchoolStatus status, String? governorate, String? afterId, String? placeAreaId});
  Future<(School, List<Area>)> school(String id);
  Future<String> saveSchool(SchoolInput input);
  Future<String> saveArea({
    required String schoolId,
    required String nameAr,
    required String nameEn,
    required GeoPin center,
    String? id,
  });
  Future<void> approveSchool(SchoolInput input);
  Future<int> mergeSchool({required String schoolId, required String intoId});

  Future<List<ReportItem>> reports();

  /// Prompt 9: one chat report with its little context (the opening is logged).
  Future<ReportDetail> report(String id);

  /// Deletes the reported message on Stream and closes the report.
  Future<ReportDetail> removeReportedMessage(String id);

  /// Removes the reported parent from that chat for good and closes the report.
  Future<ReportDetail> removeReportedMember(String id);

  Future<ReportDetail> resolveReport(String id, ReportOutcome outcome);

  /// The reported driver may drive again.
  Future<ReportDetail> liftDrivingPause(String id);
  Future<PagedResult<AuditEntry>> audit({String? afterId});

  Future<List<AdminAccount>> admins();

  /// Returns the one-time password setup link for the new admin.
  Future<String> createAdmin({required String email, required String displayName, required AdminRole role});
  Future<void> setAdminDisabled({required String uid, required bool disabled});

  /// Tells the server the admin is active (the 15-minute idle limit is
  /// also enforced there). Throws [AdminFailure] when the session ended.
  Future<void> ping();
}

class FirebaseAdminApi implements AdminApi {
  FirebaseAdminApi(this._functions);

  final FirebaseFunctions _functions;

  Future<Json> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(seconds: 30)))
          .call<Object?>(data);
      return Json.of(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AdminFailure.from(error), stackTrace);
    }
  }

  @override
  Future<List<QueueCase>> queue() async =>
      (await _call('listVerificationQueue')).list('cases').map(QueueCase.fromJson).toList();

  @override
  Future<CaseDetail> openCase(String caseId) async =>
      CaseDetail.fromJson(await _call('openVerificationCase', <String, Object?>{'caseId': caseId}));

  @override
  Future<void> decide({
    required String caseId,
    required bool approve,
    NameCheck? nameCheck,
    RejectionReason? reason,
    String? note,
    bool ban = false,
  }) async {
    await _call('decideVerification', <String, Object?>{
      'caseId': caseId,
      'decision': approve ? 'approve' : 'reject',
      'nameCheck': ?nameCheck?.code,
      'reasonCode': ?reason?.code,
      'note': ?note,
      if (ban) 'ban': true,
    });
  }

  @override
  Future<List<UserSummary>> searchUsers(String query) async =>
      (await _call('adminSearchUsers', <String, Object?>{'query': query})).list('users').map(UserSummary.fromJson).toList();

  @override
  Future<UserDetail> user(String uid) async =>
      UserDetail.fromJson(await _call('adminGetUser', <String, Object?>{'uid': uid}));

  @override
  Future<List<AdminPhoto>> userPhotos(String uid, AccessReasonCode reason) async {
    final Json j = await _call('adminOpenUserPhotos', <String, Object?>{'uid': uid, 'reason': reason.name});
    return j.list('photos').map(AdminPhoto.fromJson).toList();
  }

  @override
  Future<void> decideDeviceCheck({required String uid, required DeviceCheckOutcome outcome, required AccessReasonCode reason}) async {
    await _call('adminClearDeviceCheck', <String, Object?>{'uid': uid, 'outcome': outcome.name, 'reason': reason.name});
  }

  @override
  Future<void> moderate({
    required String uid,
    required ModerationAction action,
    required ModerationReason reason,
    String? note,
  }) async {
    await _call('adminModerateUser', <String, Object?>{
      'uid': uid,
      'action': action.name,
      'reasonCode': reason.code,
      'note': ?note,
    });
  }

  @override
  Future<PagedResult<School>> schools({required SchoolStatus status, String? governorate, String? afterId, String? placeAreaId}) async {
    final Json j = await _call('adminListSchools', <String, Object?>{
      'status': status.code,
      'governorate': ?governorate,
      'afterId': ?afterId,
      'placeAreaId': ?placeAreaId,
    });
    return PagedResult<School>(j.list('schools').map(School.fromJson).toList(), j.strOrNull('nextAfterId'));
  }

  @override
  Future<(School, List<Area>)> school(String id) async {
    final Json j = await _call('adminGetSchool', <String, Object?>{'id': id});
    return (School.fromJson(j.child('school')), j.list('areas').map(Area.fromJson).toList());
  }

  @override
  Future<String> saveSchool(SchoolInput input) async => (await _call('adminSaveSchool', input.toJson())).str('id');

  @override
  Future<String> saveArea({
    required String schoolId,
    required String nameAr,
    required String nameEn,
    required GeoPin center,
    String? id,
  }) async => (await _call('adminSaveArea', <String, Object?>{
    'id': ?id,
    'schoolId': schoolId,
    'nameAr': nameAr,
    'nameEn': nameEn,
    'center': center.toJson(),
  })).str('id');

  @override
  Future<void> approveSchool(SchoolInput input) async {
    await _call('adminApproveSchool', input.toJson());
  }

  @override
  Future<int> mergeSchool({required String schoolId, required String intoId}) async =>
      (await _call('adminMergeSchool', <String, Object?>{'schoolId': schoolId, 'intoId': intoId})).integer('childrenMoved');

  @override
  Future<List<ReportItem>> reports() async =>
      (await _call('adminListReports', <String, Object?>{'status': 'open'})).list('reports').map(ReportItem.fromJson).toList();

  @override
  Future<ReportDetail> report(String id) async => ReportDetail.fromJson(await _call('adminGetReport', <String, Object?>{'reportId': id}));

  @override
  Future<ReportDetail> removeReportedMessage(String id) async =>
      ReportDetail.fromJson(await _call('adminRemoveChatMessage', <String, Object?>{'reportId': id}));

  @override
  Future<ReportDetail> removeReportedMember(String id) async =>
      ReportDetail.fromJson(await _call('adminRemoveChatMember', <String, Object?>{'reportId': id}));

  @override
  Future<ReportDetail> resolveReport(String id, ReportOutcome outcome) async => ReportDetail.fromJson(
    await _call('adminResolveReport', <String, Object?>{
      'reportId': id,
      'outcome': switch (outcome) {
        ReportOutcome.noAction => 'no-action',
        ReportOutcome.warned => 'warned',
      },
    }),
  );

  @override
  Future<ReportDetail> liftDrivingPause(String id) async =>
      ReportDetail.fromJson(await _call('adminLiftDrivingPause', <String, Object?>{'reportId': id}));

  @override
  Future<PagedResult<AuditEntry>> audit({String? afterId}) async {
    final Json j = await _call('adminListAuditLog', <String, Object?>{'afterId': ?afterId});
    return PagedResult<AuditEntry>(j.list('entries').map(AuditEntry.fromJson).toList(), j.strOrNull('nextAfterId'));
  }

  @override
  Future<List<AdminAccount>> admins() async =>
      (await _call('adminListAdmins')).list('admins').map(AdminAccount.fromJson).toList();

  @override
  Future<String> createAdmin({required String email, required String displayName, required AdminRole role}) async =>
      (await _call('adminCreateAdmin', <String, Object?>{
        'email': email,
        'displayName': displayName,
        'role': role.name,
      })).str('setupLink');

  @override
  Future<void> setAdminDisabled({required String uid, required bool disabled}) async {
    await _call('adminSetAdminDisabled', <String, Object?>{'uid': uid, 'disabled': disabled});
  }

  @override
  Future<void> ping() async {
    await _call('adminPing');
  }
}

final Provider<AdminApi> adminApiProvider = Provider<AdminApi>((Ref ref) => FirebaseAdminApi(functionsClient()));
