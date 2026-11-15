import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

/// Data the admin panel (F14) gets from the admin Cloud Functions. Phone
/// numbers and emails arrive masked from the server.

/// Reads JSON-like values from callable results (maps arrive as
/// `Map<Object?, Object?>`).
@immutable
class Json {
  const Json(this.map);

  factory Json.of(Object? value) =>
      Json(value is Map<Object?, Object?> ? value : const <Object?, Object?>{});

  final Map<Object?, Object?> map;

  String str(String key, [String fallback = '']) {
    final Object? v = map[key];
    return v is String ? v : fallback;
  }

  String? strOrNull(String key) {
    final Object? v = map[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  int integer(String key, [int fallback = 0]) {
    final Object? v = map[key];
    return v is num ? v.toInt() : fallback;
  }

  double? number(String key) {
    final Object? v = map[key];
    return v is num ? v.toDouble() : null;
  }

  bool flag(String key) => map[key] == true;

  DateTime? time(String key) {
    final Object? v = map[key];
    return v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
  }

  Json child(String key) => Json.of(map[key]);

  List<Json> list(String key) {
    final Object? v = map[key];
    return v is List<Object?> ? v.map(Json.of).toList() : const <Json>[];
  }
}

enum AdminRole {
  admin,
  superAdmin;

  static AdminRole fromName(Object? name) => name == 'superAdmin' ? superAdmin : admin;
}

/// The signed-in admin. [displayName] and [email] are watermarked on every
/// document image.
@immutable
class AdminUser {
  const AdminUser({required this.uid, required this.email, required this.displayName, required this.role});

  final String uid;
  final String email;
  final String displayName;
  final AdminRole role;

  bool get isSuperAdmin => role == AdminRole.superAdmin;
}

/// One page of a longer list.
@immutable
class PagedResult<T> {
  const PagedResult(this.items, this.nextAfterId);

  final List<T> items;
  final String? nextAfterId;
}

// Verification -------------------------------------------------------------

@immutable
class QueueCase {
  const QueueCase({
    required this.caseId,
    required this.identity,
    required this.submittedAt,
    required this.kycResult,
    required this.children,
    required this.driver,
  });

  factory QueueCase.fromJson(Json j) => QueueCase(
    caseId: j.str('caseId'),
    identity: j.str('scope', 'identity') == 'identity',
    submittedAt: j.time('submittedAtMs'),
    kycResult: KycResult.fromName(j.strOrNull('kycResult')),
    children: j.integer('children'),
    driver: j.flag('driver'),
  );

  final String caseId;

  /// A first verification (true) or a later update of children or the car.
  final bool identity;
  final DateTime? submittedAt;
  final KycResult? kycResult;
  final int children;
  final bool driver;
}

/// The automated ID check's answer (advisory; the reviewer decides).
enum KycResult {
  match,
  noMatch,
  error;

  static KycResult? fromName(String? name) => switch (name) {
    'match' => match,
    'no_match' => noMatch,
    'error' => error,
    _ => null,
  };
}

@immutable
class CaseChild {
  const CaseChild({
    required this.childId,
    required this.firstName,
    required this.age,
    required this.grade,
    required this.schoolName,
    required this.imageUrl,
  });

  factory CaseChild.fromJson(Json j) => CaseChild(
    childId: j.str('childId'),
    firstName: j.str('firstName'),
    age: j.integer('age'),
    grade: Grade.fromName(j.str('grade')),
    schoolName: j.str('schoolName'),
    imageUrl: j.strOrNull('imageUrl'),
  );

  /// The child's name as the parent typed it (full name on the school ID).
  final String firstName;
  final String childId;
  final int age;
  final Grade? grade;
  final String schoolName;
  final String? imageUrl;
}

@immutable
class CaseDriver {
  const CaseDriver({
    required this.plate,
    required this.model,
    required this.color,
    required this.seats,
    required this.licenseExpiry,
    required this.carLicenseExpiry,
  });

  factory CaseDriver.fromJson(Json j) => CaseDriver(
    plate: j.str('plate'),
    model: j.str('model'),
    color: j.str('color'),
    seats: j.integer('seats'),
    licenseExpiry: j.str('licenseExpiry'),
    carLicenseExpiry: j.str('carLicenseExpiry'),
  );

  final String plate;
  final String model;
  final String color;
  final int seats;
  final String licenseExpiry;
  final String carLicenseExpiry;
}

@immutable
class CaseDetail {
  const CaseDetail({
    required this.caseId,
    required this.uid,
    required this.identity,
    required this.firstName,
    required this.lastName,
    required this.idExpiry,
    required this.liveness,
    required this.children,
    required this.driver,
    required this.kycResult,
    required this.kycScore,
    required this.submittedAt,
    required this.images,
    required this.decided,
  });

  factory CaseDetail.fromJson(Json j) {
    final Json identity = j.child('identity');
    final Json kyc = j.child('kyc');
    final Json images = j.child('images');
    return CaseDetail(
      caseId: j.str('caseId'),
      uid: j.str('uid'),
      identity: j.str('scope', 'identity') == 'identity',
      firstName: identity.strOrNull('firstName'),
      lastName: identity.strOrNull('lastName'),
      idExpiry: identity.strOrNull('idExpiry'),
      liveness: switch (identity.strOrNull('livenessChallenge')) {
        'left' => LivenessChallenge.left,
        'right' => LivenessChallenge.right,
        _ => null,
      },
      children: j.list('children').map(CaseChild.fromJson).toList(),
      driver: j.map['driver'] is Map<Object?, Object?> ? CaseDriver.fromJson(j.child('driver')) : null,
      kycResult: KycResult.fromName(kyc.strOrNull('result')),
      kycScore: kyc.number('score'),
      submittedAt: j.time('submittedAtMs'),
      images: _stringMap(images.map),
      decided: j.str('status', 'awaiting_review') != 'awaiting_review',
    );
  }

  final String caseId;
  final String uid;
  final bool identity;

  /// Names as on the national ID (null for an update case).
  final String? firstName;
  final String? lastName;
  final String? idExpiry;
  final LivenessChallenge? liveness;
  final List<CaseChild> children;
  final CaseDriver? driver;
  final KycResult? kycResult;
  final double? kycScore;
  final DateTime? submittedAt;

  /// 5-minute signed links by file name (empty once the images are deleted).
  final Map<String, String> images;
  final bool decided;

  String? get fullName => <String?>[firstName, lastName].whereType<String>().join(' ').trim().ifEmptyNull;
}

Map<String, String> _stringMap(Map<Object?, Object?> raw) {
  final Map<String, String> out = <String, String>{};
  raw.forEach((Object? key, Object? value) {
    if (key is String && value is String) {
      out[key] = value;
    }
  });
  return out;
}

extension _IfEmpty on String {
  String? get ifEmptyNull => isEmpty ? null : this;
}

/// How the parent and child name check passed (spec section 3).
enum NameCheck {
  match('match'),
  birthCertificate('birth_certificate');

  const NameCheck(this.code);

  final String code;
}

// Users --------------------------------------------------------------------

@immutable
class UserSummary {
  const UserSummary({
    required this.uid,
    required this.parentId,
    required this.firstName,
    required this.lastName,
    required this.status,
    required this.banned,
    required this.maskedPhone,
    required this.createdAt,
  });

  factory UserSummary.fromJson(Json j) => UserSummary(
    uid: j.str('uid'),
    parentId: j.str('parentId'),
    firstName: j.strOrNull('firstName'),
    lastName: j.strOrNull('lastName'),
    status: AccountStatus.fromName(j.str('status')),
    banned: j.flag('banned'),
    maskedPhone: j.strOrNull('phone'),
    createdAt: j.time('createdAtMs'),
  );

  final String uid;
  final String parentId;
  final String? firstName;
  final String? lastName;
  final AccountStatus status;
  final bool banned;

  /// For example +20********01. Never the full number.
  final String? maskedPhone;
  final DateTime? createdAt;

  String? get fullName => <String?>[firstName, lastName].whereType<String>().join(' ').trim().ifEmptyNull;
}

@immutable
class CaseHistory {
  const CaseHistory({
    required this.caseId,
    required this.identity,
    required this.status,
    required this.reason,
    required this.submittedAt,
    required this.decidedAt,
    this.withdrawn = false,
  });

  factory CaseHistory.fromJson(Json j) => CaseHistory(
    withdrawn: j.str('status') == 'withdrawn',
    caseId: j.str('caseId'),
    identity: j.str('scope', 'identity') == 'identity',
    status: switch (j.str('status')) {
      'approved' => ReviewStatus.approved,
      'rejected' => ReviewStatus.rejected,
      _ => ReviewStatus.pending,
    },
    reason: RejectionReason.fromCode(j.strOrNull('reasonCode')),
    submittedAt: j.time('submittedAtMs'),
    decidedAt: j.time('decidedAtMs'),
  );

  final String caseId;
  final bool identity;
  final ReviewStatus status;
  final RejectionReason? reason;
  final DateTime? submittedAt;
  final DateTime? decidedAt;

  /// The parent withdrew it before review (Prompt 3).
  final bool withdrawn;
}

@immutable
class ActionHistory {
  const ActionHistory({required this.action, required this.reason, required this.time});

  factory ActionHistory.fromJson(Json j) => ActionHistory(
    action: j.str('action'),
    reason: ModerationReason.fromCode(j.strOrNull('reasonCode')),
    time: j.time('timeMs'),
  );

  /// For example user.suspend.
  final String action;
  final ModerationReason? reason;
  final DateTime? time;
}

@immutable
class UserDetail {
  const UserDetail({required this.summary, required this.maskedEmail, required this.cases, required this.actions, this.deviceCheckSince});

  factory UserDetail.fromJson(Json j) => UserDetail(
    summary: UserSummary.fromJson(j),
    maskedEmail: j.strOrNull('email'),
    cases: j.list('cases').map(CaseHistory.fromJson).toList(),
    actions: j.list('actions').map(ActionHistory.fromJson).toList(),
    deviceCheckSince: j.time('deviceCheckSinceMs'),
  );

  final UserSummary summary;
  final String? maskedEmail;
  final List<CaseHistory> cases;
  final List<ActionHistory> actions;

  /// Prompt 13: a new-phone selfie check is open since then (the parent's
  /// chats, wallet and children stay closed until it is closed).
  final DateTime? deviceCheckSince;
}

/// Why an admin opens a parent's photos or closes a check (codes shared
/// with the server's access reasons, functions/src/privacy/photos.ts).
enum AccessReasonCode { review, investigation, report, legalRequest, parentRequest, appeal }

/// How an admin closes an open new-phone check (server DEVICE_CHECK_OUTCOMES).
enum DeviceCheckOutcome {
  /// The new-phone selfie matches the face reference (compared here).
  approved,

  /// The parent was confirmed another way (for example a call).
  confirmedOtherWay,
}

/// One kept photo (a 5-minute link; a thumbnail unless [full]).
@immutable
class AdminPhoto {
  const AdminPhoto({required this.kind, required this.url, required this.storedAt});

  factory AdminPhoto.fromJson(Json j) => AdminPhoto(kind: j.str('kind'), url: j.str('url'), storedAt: DateTime.tryParse(j.str('storedAt')));

  /// faceRef, driverPhoto, selfie or case.
  final String kind;
  final String url;
  final DateTime? storedAt;
}

enum ModerationAction { suspend, unsuspend, ban }

/// Reasons for suspend, unsuspend and ban (codes shared with the server).
enum ModerationReason {
  reports('reports'),
  fakeDocuments('fake_documents'),
  unsafeDriving('unsafe_driving'),
  harassment('harassment'),
  duplicateAccount('duplicate_account'),
  other('other');

  const ModerationReason(this.code);

  final String code;

  static ModerationReason? fromCode(String? code) {
    for (final ModerationReason r in values) {
      if (r.code == code) {
        return r;
      }
    }
    return null;
  }
}

// Schools ------------------------------------------------------------------

enum SchoolStatus {
  active('active'),
  awaitingReview('awaiting_review'),
  merged('merged');

  const SchoolStatus(this.code);

  final String code;

  static SchoolStatus fromCode(String code) =>
      values.firstWhere((SchoolStatus s) => s.code == code, orElse: () => active);
}

@immutable
class GeoPin {
  const GeoPin(this.lat, this.lng);

  final double lat;
  final double lng;

  static GeoPin? fromJson(Json j) {
    final double? lat = j.number('lat');
    final double? lng = j.number('lng');
    return lat == null || lng == null ? null : GeoPin(lat, lng);
  }

  Map<String, Object?> toJson() => <String, Object?>{'lat': lat, 'lng': lng};
}

@immutable
class School {
  const School({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.governorate,
    required this.city,
    required this.pin,
    required this.status,
    required this.source,
    this.placeAreaId = '',
    this.placeAreaNameAr = '',
    this.placeAreaNameEn = '',
  });

  factory School.fromJson(Json j) => School(
    id: j.str('id'),
    nameAr: j.str('nameAr'),
    nameEn: j.str('nameEn'),
    governorate: j.str('governorate'),
    city: j.str('city'),
    pin: GeoPin.fromJson(j.child('location')),
    status: SchoolStatus.fromCode(j.str('status')),
    source: j.str('source'),
    placeAreaId: j.str('placeAreaId'),
    placeAreaNameAr: j.str('placeAreaNameAr'),
    placeAreaNameEn: j.str('placeAreaNameEn'),
  );

  final String id;
  final String nameAr;
  final String nameEn;

  /// Governorate code, for example "cairo" (labels in the ARB files).
  final String governorate;
  final String city;
  final GeoPin? pin;
  final SchoolStatus status;
  final String source;

  /// City -> Area (placeAreas), or empty.
  final String placeAreaId;
  final String placeAreaNameAr;
  final String placeAreaNameEn;
}

@immutable
class Area {
  const Area({required this.id, required this.schoolId, required this.nameAr, required this.nameEn, required this.center});

  factory Area.fromJson(Json j) => Area(
    id: j.str('id'),
    schoolId: j.str('schoolId'),
    nameAr: j.str('nameAr'),
    nameEn: j.str('nameEn'),
    center: GeoPin.fromJson(j.child('center')) ?? const GeoPin(0, 0),
  );

  final String id;
  final String schoolId;
  final String nameAr;
  final String nameEn;
  final GeoPin center;
}

/// What the school form sends (create, edit or approve).
@immutable
class SchoolInput {
  const SchoolInput({
    required this.nameAr,
    required this.nameEn,
    required this.governorate,
    required this.city,
    required this.pin,
    this.id,
  });

  final String? id;
  final String nameAr;
  final String nameEn;
  final String governorate;
  final String city;
  final GeoPin pin;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': ?id,
    'nameAr': nameAr,
    'nameEn': nameEn,
    'governorate': governorate,
    'city': city,
    'location': pin.toJson(),
  };
}

/// Egypt's 27 governorates (codes shared with functions/src/admin_panel/schools.ts).
const List<String> kGovernorates = <String>[
  'alexandria',
  'aswan',
  'asyut',
  'beheira',
  'beni_suef',
  'cairo',
  'dakahlia',
  'damietta',
  'faiyum',
  'gharbia',
  'giza',
  'ismailia',
  'kafr_el_sheikh',
  'luxor',
  'matruh',
  'minya',
  'monufia',
  'new_valley',
  'north_sinai',
  'port_said',
  'qalyubia',
  'qena',
  'red_sea',
  'sharqia',
  'sohag',
  'south_sinai',
  'suez',
];

// Reports, audit log, admins -------------------------------------------------

@immutable
class ReportItem {
  const ReportItem({
    required this.id,
    required this.targetType,
    required this.targetId,
    required this.reason,
    required this.createdAt,
    this.urgent = false,
    this.kind = '',
  });

  factory ReportItem.fromJson(Json j) => ReportItem(
    id: j.str('id'),
    targetType: j.str('targetType'),
    targetId: j.str('targetId'),
    reason: j.str('reason'),
    createdAt: j.time('createdAtMs'),
    urgent: j.flag('urgent'),
    kind: j.str('kind'),
  );

  final String id;

  /// user, message or group.
  final String targetType;
  final String targetId;
  final String reason;
  final DateTime? createdAt;

  /// Prompt 9: child safety or dangerous driving (review the same day).
  final bool urgent;

  /// Prompt 9: kind of chat ("private", "school", "area", "carpool"), or ''.
  final String kind;
}

/// One message kept with a chat report (Prompt 9): first name, parent ID,
/// text cut short; photos are never copied.
@immutable
class ReportContextMessage {
  const ReportContextMessage({
    required this.id,
    required this.authorName,
    required this.authorParentId,
    required this.text,
    required this.attachment,
    required this.createdAt,
    required this.reported,
  });

  factory ReportContextMessage.fromJson(Json j) => ReportContextMessage(
    id: j.str('id'),
    authorName: j.str('authorName'),
    authorParentId: j.str('authorParentId'),
    text: j.str('text'),
    attachment: j.strOrNull('attachment'),
    createdAt: j.time('createdAtMs'),
    reported: j.flag('reported'),
  );

  final String id;
  final String authorName;
  final String authorParentId;
  final String text;

  /// "image", "location" or null.
  final String? attachment;
  final DateTime? createdAt;
  final bool reported;
}

/// Outcomes an admin can close a report with (functions/src/chat/admin.ts).
enum ReportOutcome { noAction, warned }

/// A chat report as the report screen shows it (adminGetReport).
@immutable
class ReportDetail {
  const ReportDetail({
    required this.id,
    required this.targetType,
    required this.reason,
    required this.urgent,
    required this.open,
    required this.kind,
    required this.note,
    required this.subjectUid,
    required this.pausedDriving,
    required this.outcome,
    required this.createdAt,
    required this.context,
  });

  factory ReportDetail.fromJson(Json j) => ReportDetail(
    id: j.str('id'),
    targetType: j.str('targetType'),
    reason: j.str('reason'),
    urgent: j.flag('urgent'),
    open: j.str('status') != 'handled',
    kind: j.str('kind'),
    note: j.str('note'),
    subjectUid: j.strOrNull('subjectUid'),
    pausedDriving: j.flag('pausedDriving'),
    outcome: j.strOrNull('outcome'),
    createdAt: j.time('createdAtMs'),
    context: j.list('context').map(ReportContextMessage.fromJson).toList(),
  );

  final String id;
  final String targetType;
  final String reason;
  final bool urgent;
  final bool open;
  final String kind;
  final String note;

  /// The reported parent, when there is one.
  final String? subjectUid;
  final bool pausedDriving;
  final String? outcome;
  final DateTime? createdAt;
  final List<ReportContextMessage> context;
}

@immutable
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.actorUid,
    required this.actorName,
    required this.action,
    required this.target,
    required this.ip,
    required this.time,
  });

  factory AuditEntry.fromJson(Json j) => AuditEntry(
    id: j.str('id'),
    actorUid: j.str('actorUid'),
    actorName: j.strOrNull('actorName'),
    action: j.str('action'),
    target: j.str('target'),
    ip: j.strOrNull('ip'),
    time: j.time('timeMs'),
  );

  final String id;
  final String actorUid;
  final String? actorName;

  /// For example verification.approve, school.create, user.suspend.
  final String action;

  /// The record it touched, for example users/abc.
  final String target;

  /// Super admins only.
  final String? ip;
  final DateTime? time;
}

@immutable
class AdminAccount {
  const AdminAccount({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    required this.disabled,
  });

  factory AdminAccount.fromJson(Json j) => AdminAccount(
    uid: j.str('uid'),
    email: j.str('email'),
    displayName: j.str('displayName'),
    role: AdminRole.fromName(j.str('role')),
    disabled: j.flag('disabled'),
  );

  final String uid;
  final String email;
  final String displayName;
  final AdminRole role;
  final bool disabled;
}
