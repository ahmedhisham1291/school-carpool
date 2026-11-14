import 'package:flutter/foundation.dart';

/// Data of identity verification (F2), children (F3) and driving details.
/// Field names and codes match functions/src/verification.

/// Documents of the parent. Each is uploaded to
/// verification/{uid}/pending/{fileName} (storage.rules allows only these).
enum VerificationDocument {
  idFront('id_front.jpg'),
  idBack('id_back.jpg'),
  selfie('selfie.jpg'),
  selfieTurn('selfie_turn.jpg'),
  license('license.jpg'),
  carLicense('car_license.jpg'),

  /// Prompt 10 (F33, F38): optional face photo for today's driver card,
  /// approved with the rest and kept (the other images are deleted).
  driverPhoto('driver_photo.jpg');

  const VerificationDocument(this.fileName);

  final String fileName;
}

/// Upload name of a child's school ID photo.
String schoolIdFileName(String ref) => 'school_id_$ref.jpg';

/// What the camera is used for. Selfies use the front camera and the
/// liveness prompt; documents use the back camera and a card frame.
enum CaptureKind { idFront, idBack, selfie, schoolId, license, carLicense, driverPhoto }

/// Direction of the head-turn prompt, picked at random for each selfie.
enum LivenessChallenge { left, right }

/// School grades, kindergarten to grade 12 (codes shared with the server).
enum Grade {
  kg1,
  kg2,
  g1,
  g2,
  g3,
  g4,
  g5,
  g6,
  g7,
  g8,
  g9,
  g10,
  g11,
  g12;

  static Grade? fromName(Object? name) {
    for (final Grade grade in values) {
      if (grade.name == name) {
        return grade;
      }
    }
    return null;
  }
}

/// Status of a review: of the account's latest case, a child or a car.
enum ReviewStatus {
  pending,
  approved,
  rejected;

  static ReviewStatus? fromName(Object? name) {
    for (final ReviewStatus status in values) {
      if (status.name == name) {
        return status;
      }
    }
    return null;
  }
}

/// Reasons an admin gives for a rejection (codes from the server).
enum RejectionReason {
  photoUnclear('photo_unclear'),
  idMismatch('id_mismatch'),
  selfieMismatch('selfie_mismatch'),
  livenessFailed('liveness_failed'),
  idExpired('id_expired'),
  schoolIdUnclear('school_id_unclear'),
  childNameMismatch('child_name_mismatch'),
  licenseInvalid('license_invalid'),
  other('other');

  const RejectionReason(this.code);

  final String code;

  static RejectionReason? fromCode(Object? code) {
    if (code == null) {
      return null;
    }
    for (final RejectionReason reason in values) {
      if (reason.code == code) {
        return reason;
      }
    }
    return RejectionReason.other;
  }
}

/// The parent's latest submission, from users/{uid}.verification.
@immutable
class VerificationSummary {
  const VerificationSummary({
    required this.caseId,
    required this.status,
    this.identity = true,
    this.reason,
    this.note,
  });

  static VerificationSummary? fromMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final ReviewStatus? status = ReviewStatus.fromName(value['status']);
    final Object? caseId = value['caseId'];
    if (status == null || caseId is! String) {
      return null;
    }
    final Object? note = value['note'];
    return VerificationSummary(
      caseId: caseId,
      status: status,
      identity: value['scope'] != 'update',
      reason: RejectionReason.fromCode(value['reasonCode']),
      note: note is String && note.isNotEmpty ? note : null,
    );
  }

  final String caseId;
  final ReviewStatus status;

  /// False for a later update (children or car) of a verified parent.
  final bool identity;
  final RejectionReason? reason;

  /// Free text from the reviewer, shown as written.
  final String? note;

  @override
  bool operator ==(Object other) =>
      other is VerificationSummary &&
      other.caseId == caseId &&
      other.status == status &&
      other.identity == identity &&
      other.reason == reason &&
      other.note == note;

  @override
  int get hashCode => Object.hash(caseId, status, identity, reason, note);
}

/// A child, children/{id}. Written only by Cloud Functions.
@immutable
class ChildRecord {
  const ChildRecord({
    required this.id,
    required this.firstName,
    required this.age,
    required this.grade,
    required this.schoolName,
    required this.status,
    this.schoolId = '',
    this.reason,
  });

  factory ChildRecord.fromDoc(String id, Map<String, dynamic> data) {
    final Object? age = data['age'];
    return ChildRecord(
      id: id,
      firstName: data['firstName'] as String? ?? '',
      age: age is num ? age.toInt() : 0,
      grade: Grade.fromName(data['grade']) ?? Grade.g1,
      schoolName: data['schoolName'] as String? ?? '',
      schoolId: data['schoolId'] as String? ?? '',
      status: ReviewStatus.fromName(data['status']) ?? ReviewStatus.pending,
      reason: RejectionReason.fromCode(data['reasonCode']),
    );
  }

  final String id;
  final String firstName;
  final int age;
  final Grade grade;
  final String schoolName;

  /// Empty for children added before the schools list (F4).
  final String schoolId;
  final ReviewStatus status;
  final RejectionReason? reason;

  @override
  bool operator ==(Object other) =>
      other is ChildRecord &&
      other.id == id &&
      other.firstName == firstName &&
      other.age == age &&
      other.grade == grade &&
      other.schoolName == schoolName &&
      other.schoolId == schoolId &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(id, firstName, age, grade, schoolName, schoolId, status, reason);
}

/// The parent's car, vehicles/{uid}. Written only by Cloud Functions.
@immutable
class VehicleRecord {
  const VehicleRecord({
    required this.plate,
    required this.model,
    required this.color,
    required this.seats,
    required this.licenseExpiry,
    required this.carLicenseExpiry,
    required this.status,
  });

  factory VehicleRecord.fromMap(Map<String, dynamic> data) {
    final Object? seats = data['seats'];
    return VehicleRecord(
      plate: data['plate'] as String? ?? '',
      model: data['model'] as String? ?? '',
      color: data['color'] as String? ?? '',
      seats: seats is num ? seats.toInt() : 0,
      licenseExpiry: parseIsoDate(data['licenseExpiry']),
      carLicenseExpiry: parseIsoDate(data['carLicenseExpiry']),
      status: ReviewStatus.fromName(data['status']) ?? ReviewStatus.pending,
    );
  }

  final String plate;
  final String model;
  final String color;
  final int seats;
  final DateTime? licenseExpiry;
  final DateTime? carLicenseExpiry;
  final ReviewStatus status;
}

/// "YYYY-MM-DD" as sent to and stored by the server.
String isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime? parseIsoDate(Object? value) {
  if (value is! String) {
    return null;
  }
  final RegExpMatch? match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) {
    return null;
  }
  return DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
}
