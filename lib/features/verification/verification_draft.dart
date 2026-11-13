import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/legal_documents.dart';
import 'package:school_carpool/features/verification/national_id.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

/// What the parent has entered and captured so far. Kept in memory only:
/// captures are never written to the phone's storage or gallery, so
/// closing the app discards them (privacy over convenience; see
/// docs/progress/prompt-03.md).

@immutable
class ChildDraft {
  const ChildDraft({
    required this.ref,
    this.childId,
    this.firstName = '',
    this.age,
    this.grade,
    this.schoolName = '',
    this.schoolIdPhoto,
  });

  /// Slot that names the school ID upload: lowercase letters and digits.
  final String ref;

  /// Set when a verified parent edits an existing child.
  final String? childId;
  final String firstName;
  final int? age;
  final Grade? grade;

  /// Typed school name until the schools list (F4, Prompt 4B).
  final String schoolName;
  final Uint8List? schoolIdPhoto;

  bool get isComplete =>
      isValidPersonName(firstName) &&
      age != null &&
      grade != null &&
      isValidFreeText(schoolName, min: 2, max: 100) &&
      schoolIdPhoto != null;

  Map<String, Object?> toPayload() => <String, Object?>{
    'ref': ref,
    'childId': childId,
    'firstName': firstName.trim(),
    'age': age,
    'grade': grade?.name,
    'schoolName': schoolName.trim(),
  };
}

@immutable
class DriverDraft {
  const DriverDraft({
    this.plate = '',
    this.model = '',
    this.color = '',
    this.seats,
    this.licenseExpiry,
    this.carLicenseExpiry,
    this.licensePhoto,
    this.carLicensePhoto,
  });

  final String plate;
  final String model;
  final String color;

  /// Passenger seats (the driver's seat not counted).
  final int? seats;
  final DateTime? licenseExpiry;
  final DateTime? carLicenseExpiry;
  final Uint8List? licensePhoto;
  final Uint8List? carLicensePhoto;

  bool isComplete(DateTime today) =>
      isValidFreeText(plate, min: 2, max: 20) &&
      isValidFreeText(model, min: 2, max: 40) &&
      isValidFreeText(color, min: 2, max: 30) &&
      seats != null &&
      isFutureDate(licenseExpiry, today) &&
      isFutureDate(carLicenseExpiry, today) &&
      licensePhoto != null &&
      carLicensePhoto != null;

  DriverDraft copyWith({
    String? plate,
    String? model,
    String? color,
    int? seats,
    DateTime? licenseExpiry,
    DateTime? carLicenseExpiry,
    Uint8List? licensePhoto,
    Uint8List? carLicensePhoto,
  }) => DriverDraft(
    plate: plate ?? this.plate,
    model: model ?? this.model,
    color: color ?? this.color,
    seats: seats ?? this.seats,
    licenseExpiry: licenseExpiry ?? this.licenseExpiry,
    carLicenseExpiry: carLicenseExpiry ?? this.carLicenseExpiry,
    licensePhoto: licensePhoto ?? this.licensePhoto,
    carLicensePhoto: carLicensePhoto ?? this.carLicensePhoto,
  );

  Map<String, Object?> toPayload() => <String, Object?>{
    'plate': plate.trim(),
    'model': model.trim(),
    'color': color.trim(),
    'seats': seats,
    'licenseExpiry': licenseExpiry == null ? null : isoDate(licenseExpiry!),
    'carLicenseExpiry': carLicenseExpiry == null ? null : isoDate(carLicenseExpiry!),
  };
}

@immutable
class VerificationDraft {
  const VerificationDraft({
    required this.challenge,
    this.firstName = '',
    this.lastName = '',
    this.nationalId = '',
    this.idExpiry,
    this.idFront,
    this.idBack,
    this.selfie,
    this.selfieTurn,
    this.children = const <ChildDraft>[],
    this.drives = false,
    this.driver = const DriverDraft(),
    this.consent = false,
    this.uploaded = const <String>{},
  });

  final String firstName;
  final String lastName;

  /// Typed by the parent, sent once to the server (which keeps only a keyed
  /// hash). Never logged or saved on the phone.
  final String nationalId;

  /// Expiry date from the back of the ID: the only field kept from it.
  final DateTime? idExpiry;
  final Uint8List? idFront;
  final Uint8List? idBack;
  final Uint8List? selfie;

  /// Selfie after the head-turn prompt (liveness evidence for the reviewer).
  final Uint8List? selfieTurn;
  final LivenessChallenge challenge;
  final List<ChildDraft> children;
  final bool drives;
  final DriverDraft driver;

  /// Consent to process ID, face and child data (Law 151).
  final bool consent;

  /// Upload names already in the pending folder. A retake removes its name.
  final Set<String> uploaded;

  bool detailsComplete(DateTime today) =>
      isValidPersonName(firstName) &&
      isValidPersonName(lastName) &&
      EgyptNationalId.isValid(nationalId, today) &&
      isFutureDate(idExpiry, today);

  bool get idPhotosComplete => idFront != null && idBack != null;
  bool get selfieComplete => selfie != null && selfieTurn != null;
  bool get childrenComplete => children.isNotEmpty && children.every((ChildDraft c) => c.isComplete);
  bool drivingComplete(DateTime today) => !drives || driver.isComplete(today);

  bool readyToSubmit(DateTime today) =>
      detailsComplete(today) &&
      idPhotosComplete &&
      selfieComplete &&
      childrenComplete &&
      drivingComplete(today) &&
      consent;

  /// Every image to upload, by upload name.
  Map<String, Uint8List> files() => <String, Uint8List>{
    if (idFront != null) VerificationDocument.idFront.fileName: idFront!,
    if (idBack != null) VerificationDocument.idBack.fileName: idBack!,
    if (selfie != null) VerificationDocument.selfie.fileName: selfie!,
    if (selfieTurn != null) VerificationDocument.selfieTurn.fileName: selfieTurn!,
    for (final ChildDraft child in children)
      if (child.schoolIdPhoto != null) schoolIdFileName(child.ref): child.schoolIdPhoto!,
    if (drives && driver.licensePhoto != null) VerificationDocument.license.fileName: driver.licensePhoto!,
    if (drives && driver.carLicensePhoto != null)
      VerificationDocument.carLicense.fileName: driver.carLicensePhoto!,
  };

  /// Body of the submitVerification call.
  Map<String, Object?> toPayload() => <String, Object?>{
    'identity': <String, Object?>{
      'firstName': firstName.trim(),
      'lastName': lastName.trim(),
      'nationalId': EgyptNationalId.normalize(nationalId),
      'idExpiry': idExpiry == null ? null : isoDate(idExpiry!),
      'livenessChallenge': challenge.name,
    },
    'children': <Map<String, Object?>>[for (final ChildDraft c in children) c.toPayload()],
    'driver': drives ? driver.toPayload() : null,
    'consents': LegalDocuments.verification,
  };

  VerificationDraft copyWith({
    String? firstName,
    String? lastName,
    String? nationalId,
    DateTime? idExpiry,
    Uint8List? idFront,
    Uint8List? idBack,
    Uint8List? selfie,
    Uint8List? selfieTurn,
    LivenessChallenge? challenge,
    List<ChildDraft>? children,
    bool? drives,
    DriverDraft? driver,
    bool? consent,
    Set<String>? uploaded,
  }) => VerificationDraft(
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    nationalId: nationalId ?? this.nationalId,
    idExpiry: idExpiry ?? this.idExpiry,
    idFront: idFront ?? this.idFront,
    idBack: idBack ?? this.idBack,
    selfie: selfie ?? this.selfie,
    selfieTurn: selfieTurn ?? this.selfieTurn,
    challenge: challenge ?? this.challenge,
    children: children ?? this.children,
    drives: drives ?? this.drives,
    driver: driver ?? this.driver,
    consent: consent ?? this.consent,
    uploaded: uploaded ?? this.uploaded,
  );
}

/// Names: letters of any script, spaces, apostrophes, dots and hyphens,
/// 2 to 40 characters (same rule as the server).
final RegExp _personName = RegExp(r"^[\p{L}\p{M}][\p{L}\p{M} .'’-]{0,38}[\p{L}\p{M}.]$", unicode: true);
final RegExp _freeText = RegExp(r"^[\p{L}\p{M}\p{N} .,'()&’/-]+$", unicode: true);

bool isValidPersonName(String value) => _personName.hasMatch(value.trim().replaceAll(RegExp(r'\s+'), ' '));

bool isValidFreeText(String value, {required int min, required int max}) {
  final String text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  return text.length >= min && text.length <= max && _freeText.hasMatch(text);
}

/// True when [date] is today or later.
bool isFutureDate(DateTime? date, DateTime today) {
  if (date == null) {
    return false;
  }
  final DateTime day = DateTime(today.year, today.month, today.day);
  return !DateTime(date.year, date.month, date.day).isBefore(day);
}

/// Holds the draft while the parent moves through the steps.
class VerificationDraftController extends Notifier<VerificationDraft> {
  VerificationDraftController([Random? random]) : _random = random ?? Random.secure();

  final Random _random;
  int _nextRef = 1;

  @override
  VerificationDraft build() => VerificationDraft(
    challenge: _random.nextBool() ? LivenessChallenge.left : LivenessChallenge.right,
  );

  void update(VerificationDraft Function(VerificationDraft draft) change) => state = change(state);

  /// Sets an identity photo and forgets that its old version was uploaded.
  void setPhoto(VerificationDocument document, Uint8List bytes) {
    final Set<String> uploaded = <String>{...state.uploaded}..remove(document.fileName);
    state = switch (document) {
      VerificationDocument.idFront => state.copyWith(idFront: bytes, uploaded: uploaded),
      VerificationDocument.idBack => state.copyWith(idBack: bytes, uploaded: uploaded),
      VerificationDocument.selfie => state.copyWith(selfie: bytes, uploaded: uploaded),
      VerificationDocument.selfieTurn => state.copyWith(selfieTurn: bytes, uploaded: uploaded),
      VerificationDocument.license => state.copyWith(
        driver: state.driver.copyWith(licensePhoto: bytes),
        uploaded: uploaded,
      ),
      VerificationDocument.carLicense => state.copyWith(
        driver: state.driver.copyWith(carLicensePhoto: bytes),
        uploaded: uploaded,
      ),
    };
  }

  /// A fresh slot name for a new child.
  String newChildRef() => 'c${_nextRef++}';

  /// Adds or replaces (same ref) a child.
  void saveChild(ChildDraft child) {
    final Set<String> uploaded = <String>{...state.uploaded}..remove(schoolIdFileName(child.ref));
    final List<ChildDraft> children = <ChildDraft>[
      for (final ChildDraft c in state.children)
        if (c.ref != child.ref) c,
      child,
    ];
    final int at = state.children.indexWhere((ChildDraft c) => c.ref == child.ref);
    if (at >= 0) {
      children
        ..removeLast()
        ..insert(at, child);
    }
    state = state.copyWith(children: children, uploaded: uploaded);
  }

  void removeChild(String ref) => state = state.copyWith(
    children: <ChildDraft>[
      for (final ChildDraft c in state.children)
        if (c.ref != ref) c,
    ],
  );

  void markUploaded(String name) => state = state.copyWith(uploaded: <String>{...state.uploaded, name});

  void forgetUploads(Iterable<String> names) =>
      state = state.copyWith(uploaded: <String>{...state.uploaded}..removeAll(names));

  /// Clears everything (after a successful submission or on sign-out).
  void reset() {
    _nextRef = 1;
    state = build();
  }
}

final NotifierProvider<VerificationDraftController, VerificationDraft> verificationDraftProvider =
    NotifierProvider<VerificationDraftController, VerificationDraft>(VerificationDraftController.new);
