import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/firebase/collections.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:url_launcher/url_launcher.dart';

/// Trips (Prompt 10). Every change goes through Cloud Functions; the app
/// reads the trip, its arrival times and emergencies it may read
/// (firestore.rules). Every method that calls a function throws
/// [TripFailure].
abstract interface class TripRepository {
  /// The trip of one run, or null when it has not started or is not for
  /// this parent (the rules then refuse the read).
  Stream<Trip?> watchTrip(String carpoolId, String runId);

  /// The run itself (carpools/{id}/schedule/{runId}; members read it).
  Stream<ScheduleRun?> watchRun(String carpoolId, String runId);

  /// Arrival times of [uid]'s children on the trip.
  Stream<TripEta?> watchEta(String tripId, String uid);

  /// Emergency alerts of a carpool, newest first (members only).
  Stream<List<EmergencyAlert>> watchEmergencies(String carpoolId);

  Stream<EmergencyContact?> watchEmergencyContact(String uid);

  Future<TripPreparation> prepare(String carpoolId, String runId);

  /// Uploads the live selfie (JPEG) and runs the face match (F38).
  Future<SelfieResult> submitSelfie({required String uid, required String carpoolId, required String runId, required Uint8List jpeg});

  Future<TripSession> start(String carpoolId, String runId);

  /// Where the location plugin posts the points of [tripId].
  String uploadUrl(String tripId);

  /// Returns false when a retry of [requestId] was applied already.
  Future<bool> act({required String carpoolId, required String runId, required String childId, required StopAction action, required String requestId});

  Future<void> confirmHandover({required String carpoolId, required String runId, required String childId});

  /// Returns false when the same message went out less than two minutes ago.
  Future<bool> quick({required String carpoolId, required String runId, required QuickKind kind, required String requestId});

  /// Review item 4: ends the run (no child on board).
  Future<void> endTrip(String carpoolId, String runId);

  /// Review item 5: ends this parent's live trips (before signing out).
  Future<void> stopMyTrips();

  /// Prompt 13: location went away during the driver's run ([reason]:
  /// service, permission or precise). The parents get "location stopped"
  /// once per gap.
  Future<void> reportTrackingLost(String carpoolId, String runId, String reason);

  /// Returns whether the saved emergency contact got the WhatsApp message.
  Future<bool> emergency({required String carpoolId, required String runId, GeoPin? point});

  Future<List<DriverCard>> todayDriverCards(String carpoolId);

  Future<List<HandoverAdult>> handoverAdults(String childId);
  Future<void> saveHandoverAdults(String childId, List<HandoverAdult> adults);

  /// R6: [agreed] is the parent's declaration that the person agreed.
  Future<void> saveEmergencyContact({required String name, required String phone, required Relation relation, required bool agreed});
  Future<void> clearEmergencyContact();

  /// Opens the phone dialer or the maps app (F20 emergency screen).
  Future<bool> openExternal(Uri uri);
}

/// A read the rules refuse means "not for you" (or "not started"): null.
Stream<T?> _orNull<T>(Stream<T?> source) => source.transform(
  StreamTransformer<T?, T?>.fromHandlers(
    handleError: (Object error, StackTrace stack, EventSink<T?> sink) {
      if (error is FirebaseException && error.code == 'permission-denied') {
        sink.add(null);
      } else {
        sink.addError(error, stack);
      }
    },
  ),
);

class FirebaseTripRepository implements TripRepository {
  FirebaseTripRepository(this._functions, this._db, this._storage, this._config);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;
  final FirebaseStorage _storage;
  final FlavorConfig _config;

  Future<Object?> _call(String name, Map<String, Object?> data) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable(name).call<Object?>(data);
      return result.data;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(TripFailure.from(error), stackTrace);
    }
  }

  Map<String, Object?> _run(String carpoolId, String runId) => <String, Object?>{'carpoolId': carpoolId, 'runId': runId};

  Map<Object?, Object?> _map(Object? value) => value is Map<Object?, Object?> ? value : const <Object?, Object?>{};

  @override
  Stream<Trip?> watchTrip(String carpoolId, String runId) {
    final String id = Trip.idOf(carpoolId, runId);
    return _orNull(
      _db.collection(Collections.trips).doc(id).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
        final Map<String, dynamic>? data = s.data();
        return data == null ? null : Trip.fromDoc(id, data);
      }),
    );
  }

  @override
  Stream<ScheduleRun?> watchRun(String carpoolId, String runId) => _orNull(
    _db.collection(Collections.carpools).doc(carpoolId).collection(Collections.schedule).doc(runId).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
      final Map<String, dynamic>? data = s.data();
      return data == null ? null : ScheduleRun.fromDoc(s.id, data);
    }),
  );

  @override
  Stream<TripEta?> watchEta(String tripId, String uid) => _orNull(
    _db.collection(Collections.trips).doc(tripId).collection(Collections.eta).doc(uid).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
      final Map<String, dynamic>? data = s.data();
      return data == null ? null : TripEta.fromDoc(data);
    }),
  );

  @override
  Stream<List<EmergencyAlert>> watchEmergencies(String carpoolId) => _db
      .collection(Collections.carpools)
      .doc(carpoolId)
      .collection(Collections.emergencies)
      .orderBy('at', descending: true)
      .limit(10)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> s) => <EmergencyAlert>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) EmergencyAlert.fromDoc(d.id, d.data()),
        ],
      );

  @override
  Stream<EmergencyContact?> watchEmergencyContact(String uid) =>
      _db.collection(Collections.emergencyContacts).doc(uid).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
        final Map<String, dynamic>? data = s.data();
        return data == null ? null : EmergencyContact.fromDoc(data);
      });

  @override
  Future<TripPreparation> prepare(String carpoolId, String runId) async =>
      TripPreparation.fromMap(await _call('prepareTrip', _run(carpoolId, runId)));

  @override
  Future<SelfieResult> submitSelfie({required String uid, required String carpoolId, required String runId, required Uint8List jpeg}) async {
    try {
      await _storage
          .ref('selfieChecks/$uid/${Trip.idOf(carpoolId, runId)}.jpg')
          .putData(jpeg, SettableMetadata(contentType: 'image/jpeg'));
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(TripFailure.from(error), stackTrace);
    }
    final Object? status = _map(await _call('submitSelfieCheck', _run(carpoolId, runId)))['status'];
    return switch (status) {
      'passed' || 'none' => SelfieResult.passed,
      'failed' => SelfieResult.failed,
      _ => SelfieResult.error,
    };
  }

  @override
  Future<TripSession> start(String carpoolId, String runId) async => TripSession.fromMap(await _call('startTrip', _run(carpoolId, runId)));

  @override
  String uploadUrl(String tripId) {
    final String project = Firebase.app().options.projectId;
    final String trip = Uri.encodeQueryComponent(tripId);
    if (_config.useEmulators) {
      return 'http://${_config.emulatorHost}:${EmulatorPorts.functions}/$project/$kFunctionsRegion/tripLocation?trip=$trip';
    }
    return 'https://$kFunctionsRegion-$project.cloudfunctions.net/tripLocation?trip=$trip';
  }

  @override
  Future<bool> act({required String carpoolId, required String runId, required String childId, required StopAction action, required String requestId}) async {
    final Object? result = await _call('tripAction', <String, Object?>{
      ..._run(carpoolId, runId),
      'childId': childId,
      'action': action.name,
      'requestId': requestId,
    });
    return _map(result)['applied'] != false;
  }

  @override
  Future<void> confirmHandover({required String carpoolId, required String runId, required String childId}) =>
      _call('confirmHandover', <String, Object?>{..._run(carpoolId, runId), 'childId': childId});

  @override
  Future<bool> quick({required String carpoolId, required String runId, required QuickKind kind, required String requestId}) async {
    final Object? result = await _call('quickMessage', <String, Object?>{..._run(carpoolId, runId), 'kind': kind.name, 'requestId': requestId});
    return _map(result)['posted'] == true;
  }

  @override
  Future<void> endTrip(String carpoolId, String runId) => _call('endTrip', _run(carpoolId, runId));

  @override
  Future<void> stopMyTrips() => _call('stopMyTrips', <String, Object?>{});

  @override
  Future<void> reportTrackingLost(String carpoolId, String runId, String reason) =>
      _call('reportTrackingLost', <String, Object?>{..._run(carpoolId, runId), 'reason': reason});

  @override
  Future<bool> emergency({required String carpoolId, required String runId, GeoPin? point}) async {
    final Object? result = await _call('tripEmergency', <String, Object?>{
      ..._run(carpoolId, runId),
      if (point != null) 'point': <String, double>{'lat': point.lat, 'lng': point.lng},
    });
    return _map(result)['contactSent'] == true;
  }

  @override
  Future<List<DriverCard>> todayDriverCards(String carpoolId) async {
    final Object? cards = _map(await _call('getTodayDriverCards', <String, Object?>{'carpoolId': carpoolId}))['cards'];
    return <DriverCard>[if (cards is List<Object?>) for (final Object? c in cards) DriverCard.fromMap(c)];
  }

  @override
  Future<List<HandoverAdult>> handoverAdults(String childId) async {
    final Object? adults = _map(await _call('getHandoverAdults', <String, Object?>{'childId': childId}))['adults'];
    return <HandoverAdult>[if (adults is List<Object?>) for (final Object? a in adults) HandoverAdult.fromMap(a)];
  }

  @override
  Future<void> saveHandoverAdults(String childId, List<HandoverAdult> adults) => _call('saveHandoverAdults', <String, Object?>{
    'childId': childId,
    'adults': <Map<String, Object?>>[for (final HandoverAdult a in adults) a.toJson()],
  });

  @override
  Future<void> saveEmergencyContact({required String name, required String phone, required Relation relation, required bool agreed}) =>
      _call('setEmergencyContact', <String, Object?>{'name': name, 'phone': phone, 'relation': relation.name, 'agreed': agreed});

  @override
  Future<void> clearEmergencyContact() => _call('setEmergencyContact', <String, Object?>{'clear': true});

  @override
  Future<bool> openExternal(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  }
}

final Provider<TripRepository> tripRepositoryProvider = Provider<TripRepository>(
  (Ref ref) => FirebaseTripRepository(functionsClient(), ref.watch(firestoreProvider), FirebaseStorage.instance, ref.watch(flavorConfigProvider)),
);

/// "Now" for the trip screens (tests fix it).
final Provider<DateTime Function()> tripClockProvider = Provider<DateTime Function()>((Ref ref) => DateTime.now);
