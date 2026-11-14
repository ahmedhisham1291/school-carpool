import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// The wallet through our Cloud Functions only (Prompt 11B). The app never
/// reads or writes wallet records in Firestore (firestore.rules close them)
/// and never talks to the wallet partner: the functions do, through one
/// WalletProvider. Every method throws [WalletFailure].
abstract interface class WalletRepository {
  /// The wallet, with the balance read from the partner.
  Future<WalletInfo> wallet();

  /// Opens the wallet after the parent agreed to the partner's terms ([termsVersion]).
  Future<WalletInfo> open({required String termsVersion});

  Future<WalletPage> history({String? afterId});

  /// One transfer; a pending one is checked with the partner first.
  Future<WalletTransfer> transfer(String id);

  /// First name and Verified badge only (rate limited on the server).
  Future<ReceiverPreview> lookup(String parentId);

  /// Parents of my carpools, or of one carpool.
  Future<List<WalletContact>> contacts({String? carpoolId});

  Future<MoneyResult> send(SendRequest request);

  Future<MoneyResult> addMoney({required String requestId, required int amount});

  Future<MoneyResult> withdraw({required String requestId, required int amount});

  /// Returns whether the parent's own wallet was frozen (someone else sent it).
  Future<bool> report({required String transferId, required WalletReportReason reason, String note = ''});
}

class FirebaseWalletRepository implements WalletRepository {
  FirebaseWalletRepository(this._functions);

  final FirebaseFunctions _functions;

  Future<Map<Object?, Object?>> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> r = await _functions.httpsCallable(name).call<Object?>(data);
      final Object? value = r.data;
      return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(WalletFailure.from(error), stackTrace);
    }
  }

  static Map<Object?, Object?> _mapOf(Object? v) => v is Map<Object?, Object?> ? v : const <Object?, Object?>{};

  MoneyResult _money(Map<Object?, Object?> m) => MoneyResult(
    transfer: WalletTransfer.fromMap(_mapOf(m['transfer'])),
    checkoutUrl: m['checkoutUrl'] is String ? m['checkoutUrl']! as String : null,
  );

  @override
  Future<WalletInfo> wallet() async => WalletInfo.fromMap(await _call('getWallet'));

  @override
  Future<WalletInfo> open({required String termsVersion}) async =>
      WalletInfo.fromMap(await _call('openWallet', <String, Object?>{'acceptTerms': termsVersion}));

  @override
  Future<WalletPage> history({String? afterId}) async {
    final Map<Object?, Object?> m = await _call('listWalletHistory', <String, Object?>{'afterId': ?afterId});
    final Object? list = m['transfers'];
    return WalletPage(
      transfers: <WalletTransfer>[
        if (list is List<Object?>)
          for (final Object? t in list) WalletTransfer.fromMap(_mapOf(t)),
      ],
      nextAfterId: m['nextAfterId'] is String ? m['nextAfterId']! as String : null,
    );
  }

  @override
  Future<WalletTransfer> transfer(String id) async => WalletTransfer.fromMap(await _call('getTransfer', <String, Object?>{'transferId': id}));

  @override
  Future<ReceiverPreview> lookup(String parentId) async {
    final Map<Object?, Object?> m = await _call('lookupParentId', <String, Object?>{'parentId': ParentIds.normalize(parentId)});
    return ReceiverPreview(firstName: m['firstName'] is String ? m['firstName']! as String : '', verified: m['verified'] == true);
  }

  @override
  Future<List<WalletContact>> contacts({String? carpoolId}) async {
    final Map<Object?, Object?> m = await _call('walletContacts', <String, Object?>{'carpoolId': ?carpoolId});
    final Object? list = m['contacts'];
    return <WalletContact>[
      if (list is List<Object?>)
        for (final Object? c in list) WalletContact.fromMap(_mapOf(c)),
    ];
  }

  @override
  Future<MoneyResult> send(SendRequest request) async => _money(await _call('sendMoney', request.toJson()));

  @override
  Future<MoneyResult> addMoney({required String requestId, required int amount}) async =>
      _money(await _call('addMoney', <String, Object?>{'requestId': requestId, 'amount': amount}));

  @override
  Future<MoneyResult> withdraw({required String requestId, required int amount}) async =>
      _money(await _call('withdrawMoney', <String, Object?>{'requestId': requestId, 'amount': amount}));

  @override
  Future<bool> report({required String transferId, required WalletReportReason reason, String note = ''}) async {
    final Map<Object?, Object?> m = await _call('reportTransfer', <String, Object?>{
      'transferId': transferId,
      'reason': reason.name,
      if (note.isNotEmpty) 'note': note,
    });
    return m['frozen'] == true;
  }
}

final Provider<WalletRepository> walletRepositoryProvider = Provider<WalletRepository>(
  (Ref ref) => FirebaseWalletRepository(functionsClient()),
);

/// "Now" for the wallet screens (tests fix it).
final Provider<DateTime Function()> walletClockProvider = Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// New request IDs (tests make them predictable).
final Provider<String Function()> requestIdFactoryProvider = Provider<String Function()>((Ref ref) => newRequestId);

/// Riverpod 3 retries failing providers by itself; wallet screens show the
/// error with their own Retry button instead (a refused parent must not see
/// a screen that keeps loading).
Duration? noWalletRetry(int retryCount, Object error) => null;

/// The wallet (balance from the partner). Reloaded after every money action.
final FutureProvider<WalletInfo> walletInfoProvider = FutureProvider.autoDispose<WalletInfo>(
  retry: noWalletRetry,
  (Ref ref) => ref.watch(walletRepositoryProvider).wallet(),
);

/// The first page of the history.
final FutureProvider<WalletPage> walletHistoryProvider = FutureProvider.autoDispose<WalletPage>(
  retry: noWalletRetry,
  (Ref ref) => ref.watch(walletRepositoryProvider).history(),
);
