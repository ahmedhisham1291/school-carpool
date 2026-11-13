import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/screen_security.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';

import 'school_fakes.dart';

/// A valid 1 by 1 pixel PNG standing in for a photo, so Image.memory can
/// decode it (tests never use real images).
final Uint8List fakePhoto = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOYc+IAAAQoAiWGhDpEAAAAAElFTkSuQmCC',
);

/// Records uploads and submissions. [failUploadsOf] makes those names fail
/// once with [failure]; [submitFailure] fails the next submit.
class FakeVerificationRepository implements VerificationRepository {
  final List<String> uploads = <String>[];
  final List<Map<String, Object?>> submissions = <Map<String, Object?>>[];
  final List<String> removed = <String>[];
  final Set<String> failUploadsOf = <String>{};
  VerificationFailure failure = const VerificationFailure(VerificationFailureKind.offline);
  VerificationFailure? submitFailure;
  List<ChildRecord> childList = const <ChildRecord>[];

  @override
  Future<void> upload(String uid, String name, Uint8List bytes, {ValueChanged<double>? onProgress}) async {
    if (failUploadsOf.remove(name)) {
      throw failure;
    }
    onProgress?.call(1);
    uploads.add(name);
  }

  @override
  Future<String> submit(Map<String, Object?> payload) async {
    final VerificationFailure? f = submitFailure;
    if (f != null) {
      submitFailure = null;
      throw f;
    }
    submissions.add(payload);
    return 'case-${submissions.length}';
  }

  @override
  Future<void> removeChild(String childId) async => removed.add(childId);

  final List<String> withdrawn = <String>[];

  @override
  Future<void> withdraw(String caseId) async => withdrawn.add(caseId);

  @override
  Stream<List<ChildRecord>> children(String uid) => Stream<List<ChildRecord>>.value(childList);

  @override
  Stream<VehicleRecord?> vehicle(String uid) => Stream<VehicleRecord?>.value(null);
}

/// Returns fixed bytes instead of opening the camera, and records requests.
class FakeCamera {
  final List<CaptureRequest> requests = <CaptureRequest>[];

  Future<CaptureResult?> launch(BuildContext context, CaptureRequest request) async {
    requests.add(request);
    return CaptureResult(fakePhoto, turnImage: request.isSelfie ? fakePhoto : null);
  }
}

List<Override> verificationOverrides({
  required FakeVerificationRepository repository,
  FakeCamera? camera,
  List<ChildRecord>? children,
}) => <Override>[
  verificationRepositoryProvider.overrideWithValue(repository),
  captureLauncherProvider.overrideWithValue((camera ?? FakeCamera()).launch),
  screenSecurityProvider.overrideWithValue(const NoScreenSecurity()),
  childrenProvider.overrideWith((Ref ref) => Stream<List<ChildRecord>>.value(children ?? repository.childList)),
  vehicleProvider.overrideWith((Ref ref) => Stream<VehicleRecord?>.value(null)),
  // The child form picks the school from the schools list (F4).
  ...schoolOverrides(),
];
