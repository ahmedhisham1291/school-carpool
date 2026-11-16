import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/firebase/collections.dart';

/// Optional features the owner can switch on or off from the admin panel
/// without an app release (docs/DECISIONS.md, "Improvements, revised").
/// Core features (sign-in, verification, carpools, schedule, trips and
/// alerts, chat) have no switch.
enum AppFeature { wallet, ratingsAndVouching, yearlyChecks, settleUp }

/// The pilot feature switches (server document `config/features`, same
/// names as functions/src/features/model.ts). The server is the authority:
/// it refuses every call of a switched-off feature. The app only hides the
/// entry points and shows "not available yet" on a deep link.
@immutable
class FeatureSwitches {
  const FeatureSwitches({
    required this.wallet,
    required this.ratingsAndVouching,
    required this.yearlyChecks,
    required this.settleUp,
  });

  /// From the stored document. A missing document, a missing field or a
  /// value that is not a boolean reads as the pilot default.
  factory FeatureSwitches.fromMap(Map<String, Object?>? data) {
    bool pick(String key, bool fallback) {
      final Object? v = data?[key];
      return v is bool ? v : fallback;
    }

    return FeatureSwitches(
      wallet: pick('wallet', pilot.wallet),
      ratingsAndVouching: pick('ratingsAndVouching', pilot.ratingsAndVouching),
      yearlyChecks: pick('yearlyChecks', pilot.yearlyChecks),
      settleUp: pick('settleUp', pilot.settleUp),
    );
  }

  /// Pilot defaults: every switch is off, the money features (wallet and
  /// Settle up) included (owner decision 16 Nov 2026, "Money: OFF"; same as
  /// PILOT_DEFAULTS in functions/src/features/model.ts). Used while
  /// loading, offline with nothing cached, signed out, and when
  /// config/features or a field is missing: a missing record never shows a
  /// money feature.
  static const FeatureSwitches pilot = FeatureSwitches(
    wallet: false,
    ratingsAndVouching: false,
    yearlyChecks: false,
    settleUp: false,
  );

  /// Everything on (tests of the features themselves).
  static const FeatureSwitches allOn = FeatureSwitches(
    wallet: true,
    ratingsAndVouching: true,
    yearlyChecks: true,
    settleUp: true,
  );

  final bool wallet;
  final bool ratingsAndVouching;
  final bool yearlyChecks;
  final bool settleUp;

  bool isOn(AppFeature feature) => switch (feature) {
    AppFeature.wallet => wallet,
    AppFeature.ratingsAndVouching => ratingsAndVouching,
    AppFeature.yearlyChecks => yearlyChecks,
    AppFeature.settleUp => settleUp,
  };

  FeatureSwitches copyWith({bool? wallet, bool? ratingsAndVouching, bool? yearlyChecks, bool? settleUp}) => FeatureSwitches(
    wallet: wallet ?? this.wallet,
    ratingsAndVouching: ratingsAndVouching ?? this.ratingsAndVouching,
    yearlyChecks: yearlyChecks ?? this.yearlyChecks,
    settleUp: settleUp ?? this.settleUp,
  );

  @override
  bool operator ==(Object other) =>
      other is FeatureSwitches &&
      other.wallet == wallet &&
      other.ratingsAndVouching == ratingsAndVouching &&
      other.yearlyChecks == yearlyChecks &&
      other.settleUp == settleUp;

  @override
  int get hashCode => Object.hash(wallet, ratingsAndVouching, yearlyChecks, settleUp);

  @override
  String toString() =>
      'FeatureSwitches(wallet: $wallet, ratingsAndVouching: $ratingsAndVouching, yearlyChecks: $yearlyChecks, settleUp: $settleUp)';
}

/// No automatic retry: a refused or failed read falls back to the pilot
/// defaults at once, and the listener delivers the value when it can.
Duration? _noRetry(int retryCount, Object error) => null;

String? _uidOf(SessionState session) => session is SessionSignedIn ? session.uid : null;

/// The ONE listener on `config/features`, shared by every screen. Starts
/// when a parent is signed in (the rules let signed-in parents read that
/// document); Firestore's cache answers offline.
final StreamProvider<FeatureSwitches> featureSwitchesStreamProvider = StreamProvider<FeatureSwitches>(
  retry: _noRetry,
  (Ref ref) {
    final String? uid = ref.watch(sessionProvider.select(_uidOf));
    if (uid == null) {
      return Stream<FeatureSwitches>.value(FeatureSwitches.pilot);
    }
    return ref
        .watch(firestoreProvider)
        .collection(Collections.config)
        .doc(Docs.features)
        .snapshots()
        .map((DocumentSnapshot<Map<String, dynamic>> snapshot) => FeatureSwitches.fromMap(snapshot.data()));
  },
);

/// The switches right now: the stored values, or the pilot defaults while
/// loading and on any error. Tests override this with a fixed value.
final Provider<FeatureSwitches> featureSwitchesProvider = Provider<FeatureSwitches>(
  (Ref ref) => ref.watch(featureSwitchesStreamProvider).value ?? FeatureSwitches.pilot,
);
