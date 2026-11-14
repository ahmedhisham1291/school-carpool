import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show newRequestId;
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Settle up (F45) through our Cloud Functions. The app READS its own
/// records (the rules let only the two parties read one) and never writes
/// one: every change is a function call. The app never moves money and
/// never talks to InstaPay. Every Future method throws [SettleFailure].
abstract interface class SettleUpRepository {
  /// My records, newest change first (live). Errors are Firebase errors:
  /// screens read them with [SettleFailure.from].
  Stream<List<SettleUp>> watch(String uid);

  /// My own InstaPay address and the limits the form shows.
  Future<SettleProfile> profile();

  /// Saves my InstaPay address; returns it as stored.
  Future<String> saveAddress(String address);

  Future<void> removeAddress();

  /// Parents of my carpools, or of one carpool.
  Future<List<SettleContact>> contacts({String? carpoolId});

  Future<SettleUp> create(SettleCreate request);

  Future<SettleUp> act(String id, SettleAction action);

  /// The payee's InstaPay address, for the payer of an open record only.
  /// Null when the payee has not saved one.
  Future<String?> addressFor(String id);

  /// Sends the record to the admins after it bounced enough times.
  Future<void> report(String id, {String note = ''});
}

class FirebaseSettleUpRepository implements SettleUpRepository {
  FirebaseSettleUpRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  /// Enough for the home screen; older finished records stay on the server.
  static const int pageSize = 100;

  Future<Map<Object?, Object?>> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> r = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? value = r.data;
      return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(SettleFailure.from(error), stackTrace);
    }
  }

  static Map<Object?, Object?> _mapOf(Object? v) => v is Map<Object?, Object?> ? v : const <Object?, Object?>{};

  static SettleUp _record(Map<Object?, Object?> answer) {
    final Map<Object?, Object?> m = _mapOf(answer['record']);
    final Object? id = m['id'];
    return SettleUp.fromMap(id is String ? id : '', m);
  }

  @override
  Stream<List<SettleUp>> watch(String uid) => _db
      .collection('settleUps')
      .where('parties', arrayContains: uid)
      .orderBy('updatedAt', descending: true)
      .limit(pageSize)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> snapshot) => <SettleUp>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snapshot.docs) SettleUp.fromMap(d.id, d.data()),
        ],
      );

  @override
  Future<SettleProfile> profile() async => SettleProfile.fromMap(await _call('getSettleUpProfile'));

  @override
  Future<String> saveAddress(String address) async {
    final Map<Object?, Object?> m = await _call('saveInstaPayAddress', <String, Object?>{'address': address});
    final Object? saved = m['address'];
    return saved is String ? saved : address;
  }

  @override
  Future<void> removeAddress() async {
    await _call('removeInstaPayAddress');
  }

  @override
  Future<List<SettleContact>> contacts({String? carpoolId}) async {
    final Map<Object?, Object?> m = await _call('settleUpContacts', <String, Object?>{'carpoolId': ?carpoolId});
    final Object? list = m['contacts'];
    return <SettleContact>[
      if (list is List<Object?>)
        for (final Object? c in list) SettleContact.fromMap(_mapOf(c)),
    ];
  }

  @override
  Future<SettleUp> create(SettleCreate request) async => _record(await _call('createSettleUp', request.toJson()));

  @override
  Future<SettleUp> act(String id, SettleAction action) async =>
      _record(await _call('settleUpAction', <String, Object?>{'id': id, 'action': action.name}));

  @override
  Future<String?> addressFor(String id) async {
    final Map<Object?, Object?> m = await _call('getSettleUpAddress', <String, Object?>{'id': id});
    final Object? address = m['address'];
    return address is String && address.isNotEmpty ? address : null;
  }

  @override
  Future<void> report(String id, {String note = ''}) async {
    await _call('reportSettleUp', <String, Object?>{'id': id, if (note.isNotEmpty) 'note': note});
  }
}

final Provider<SettleUpRepository> settleUpRepositoryProvider = Provider<SettleUpRepository>(
  (Ref ref) => FirebaseSettleUpRepository(functionsClient(), ref.watch(firestoreProvider)),
);

/// New request IDs (tests make them predictable). One per record: a retry
/// sends the same ID and the server creates the record once.
final Provider<String Function()> settleRequestIdProvider = Provider<String Function()>((Ref ref) => newRequestId);

/// Riverpod retries failing providers by itself; these screens show the
/// error with their own Retry button instead.
Duration? noSettleRetry(int retryCount, Object error) => null;

String? _uidOf(SessionState session) => session is SessionSignedIn ? session.uid : null;

/// The signed-in parent's uid for the settle-up screens ('' when signed out).
final Provider<String> settleUidProvider = Provider<String>((Ref ref) => ref.watch(sessionProvider.select(_uidOf)) ?? '');

/// My records, live. One listener while a settle-up screen is open.
final StreamProvider<List<SettleUp>> settleUpsProvider = StreamProvider.autoDispose<List<SettleUp>>(
  retry: noSettleRetry,
  (Ref ref) {
    final String uid = ref.watch(settleUidProvider);
    if (uid.isEmpty) {
      return Stream<List<SettleUp>>.value(const <SettleUp>[]);
    }
    return ref.watch(settleUpRepositoryProvider).watch(uid);
  },
);

/// My InstaPay address and the limits. Reloaded after a change.
final FutureProvider<SettleProfile> settleProfileProvider = FutureProvider.autoDispose<SettleProfile>(
  retry: noSettleRetry,
  (Ref ref) => ref.watch(settleUpRepositoryProvider).profile(),
);
