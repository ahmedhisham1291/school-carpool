import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/core/app_failure.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/firebase/callable_error.dart';

FirebaseFunctionsException _error(String code, [Object? details]) =>
    FirebaseFunctionsException(code: code, message: 'x', details: details);

void main() {
  group('callableReason', () {
    test('reads details.reason', () {
      expect(callableReason(_error('failed-precondition', <Object?, Object?>{'reason': 'no-car'})), 'no-car');
    });

    test('is null without details, with non-map details or a non-string reason', () {
      expect(callableReason(_error('internal')), isNull);
      expect(callableReason(_error('internal', 'text')), isNull);
      expect(callableReason(_error('internal', <Object?, Object?>{'reason': 3})), isNull);
    });

    test('callableDetail reads any key', () {
      expect(callableDetail(_error('resource-exhausted', <Object?, Object?>{'retryAfterSeconds': 5}), 'retryAfterSeconds'), 5);
    });
  });

  group('feature failures through AppFailure', () {
    test('map the reason and the offline state the same way as before', () {
      final AppFailure carpool = CarpoolFailure.from(_error('failed-precondition', <Object?, Object?>{'reason': 'no-car'}));
      expect((carpool as CarpoolFailure).kind, CarpoolFailureKind.noCar);
      expect(carpool.isOffline, isFalse);

      final AppFailure offline = TripFailure.from(_error('unavailable'));
      expect(offline.isOffline, isTrue);
    });
  });
}
