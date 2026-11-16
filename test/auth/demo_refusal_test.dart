// App Review demo parents get "This demo account can't do that" instead of
// the generic error (server reasons demo-account and demo-closed,
// functions/src/privacy/device_gate.ts). Written, not run here (no Flutter
// SDK in the build workspace).
import 'dart:ui' show Locale;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/demo_refusal.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/chat/chat_models.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/places/address_repository.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

FirebaseFunctionsException _refusal(String reason) => FirebaseFunctionsException(
  code: reason == 'demo-closed' ? 'permission-denied' : 'failed-precondition',
  message: reason,
  details: <Object?, Object?>{'reason': reason},
);

void main() {
  test('reads both reasons and nothing else', () {
    expect(demoRefusalOf(_refusal('demo-account')), DemoRefusal.account);
    expect(demoRefusalOf(_refusal('demo-closed')), DemoRefusal.closed);
    expect(demoRefusalOf(_refusal('not-verified')), isNull);
    expect(demoRefusalOf(StateError('x')), isNull);
    expect(demoRefusalOf(null), isNull);
  });

  for (final Locale locale in AppLocales.supported) {
    final AppLocalizations l10n = lookupAppLocalizations(locale);
    test('[${locale.languageCode}] every failure type says it in words, not the generic error', () {
      final List<String Function(Object)> messages = <String Function(Object)>[
        (Object e) => AuthFailure.from(e).message(l10n),
        (Object e) => VerificationFailure.from(e).message(l10n),
        (Object e) => AddressFailure.from(e).message(l10n),
        (Object e) => TripFailure.from(e).message(l10n),
        (Object e) => WalletFailure.from(e).message(l10n),
        (Object e) => ChatFailure.from(e).message(l10n),
        (Object e) => NotificationFailure.from(e).message(l10n),
        (Object e) => MapFailure.from(e).message(l10n),
        (Object e) => CarpoolFailure.from(e).message(l10n),
        (Object e) => TrustFailure.from(e).message(l10n),
        (Object e) => OtherSchoolFailure.from(e).message(l10n),
        (Object e) => PrivacyFailure.from(e).message(l10n),
        (Object e) => SettleFailure.from(e).message(l10n),
      ];
      for (final String Function(Object) message in messages) {
        expect(message(_refusal('demo-account')), l10n.demoAccountRefused);
        expect(message(_refusal('demo-closed')), l10n.demoAccountClosed);
        expect(message(_refusal('demo-account')), isNot(l10n.errorGeneric));
      }
    });
  }
}
