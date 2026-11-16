import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/settings/settings_store.dart';
import 'package:url_launcher/url_launcher.dart';

/// Carpools (Prompt 6). Every change goes through Cloud Functions; the app
/// reads only what firestore.rules allows: its own memberships, a carpool
/// by ID, and members, consents and requests of carpools it belongs to.
abstract interface class CarpoolRepository {
  Stream<List<Membership>> myMemberships(String uid);
  Stream<Carpool?> watchCarpool(String carpoolId);

  /// Approved members only (an error for anyone else).
  Stream<List<CarpoolMember>> watchMembers(String carpoolId);
  Stream<List<DriverConsent>> watchConsents(String carpoolId);

  /// The carpool admin only.
  Stream<List<JoinRequest>> watchRequests(String carpoolId);
  Stream<Membership?> watchMyMembership(String carpoolId, String uid);
  Future<List<SchoolArea>> areas(String schoolId);

  /// Every method below throws [CarpoolFailure].
  Future<String> create(CarpoolDraft draft);
  Future<List<Carpool>> search(CarpoolQuery query);
  Future<void> requestToJoin({required String carpoolId, required List<String> childIds, required bool acceptContribution});
  Future<void> cancelRequest(String carpoolId);
  Future<void> decide({required String carpoolId, required String uid, required bool approve});
  Future<void> leave(String carpoolId);
  Future<void> setConsent({required String carpoolId, required String driverUid, required bool accept});
  Future<void> setPickupSharing({required String carpoolId, required bool share});
  Future<CarpoolInvite> createInvite(String carpoolId);

  /// Returns the carpool ID of a valid invite code.
  Future<String> openInvite(String code);
  Future<WantedList> listWanted({required String schoolId, String? areaId});
  Future<void> saveWanted(WantedDraft draft);
  Future<void> deleteWanted();
}

Map<Object?, Object?> _map(Object? data) => data is Map<Object?, Object?> ? data : const <Object?, Object?>{};

class FirebaseCarpoolRepository implements CarpoolRepository {
  FirebaseCarpoolRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  Future<Map<Object?, Object?>> _call(String name, Map<String, Object?> data) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions.httpsCallable(name).call<Object?>(data);
      return _map(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(CarpoolFailure.from(error), stackTrace);
    }
  }

  DocumentReference<Map<String, dynamic>> _carpool(String id) => _db.collection('carpools').doc(id);

  @override
  Stream<List<Membership>> myMemberships(String uid) => _db
      .collection('memberships')
      .where('uid', isEqualTo: uid)
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => <Membership>[for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) Membership.fromDoc(d.data())]);

  @override
  Stream<Carpool?> watchCarpool(String carpoolId) => _carpool(carpoolId).snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
    final Map<String, dynamic>? data = s.data();
    return data == null ? null : Carpool.fromDoc(s.id, data);
  });

  @override
  Stream<List<CarpoolMember>> watchMembers(String carpoolId) => _carpool(carpoolId)
      .collection('members')
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => <CarpoolMember>[for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) CarpoolMember.fromDoc(d.id, d.data())]);

  @override
  Stream<List<DriverConsent>> watchConsents(String carpoolId) => _carpool(carpoolId)
      .collection('driverConsents')
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => <DriverConsent>[for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) DriverConsent.fromDoc(d.data())]);

  @override
  Stream<List<JoinRequest>> watchRequests(String carpoolId) => _carpool(carpoolId)
      .collection('requests')
      .snapshots()
      .map((QuerySnapshot<Map<String, dynamic>> s) => <JoinRequest>[for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs) JoinRequest.fromDoc(d.id, d.data())]);

  @override
  Stream<Membership?> watchMyMembership(String carpoolId, String uid) =>
      _db.collection('memberships').doc('${carpoolId}_$uid').snapshots().map((DocumentSnapshot<Map<String, dynamic>> s) {
        final Map<String, dynamic>? data = s.data();
        return data == null ? null : Membership.fromDoc(data);
      });

  @override
  Future<List<SchoolArea>> areas(String schoolId) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await _db
          .collection('areas')
          .where('schoolId', isEqualTo: schoolId)
          .limit(200)
          .get();
      final List<SchoolArea> out = <SchoolArea>[
        for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs)
          SchoolArea(id: d.id, nameAr: d.data()['nameAr'] as String? ?? '', nameEn: d.data()['nameEn'] as String? ?? ''),
      ]..sort((SchoolArea a, SchoolArea b) => a.nameAr.compareTo(b.nameAr));
      return out;
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(CarpoolFailure.from(error), stackTrace);
    }
  }

  @override
  Future<String> create(CarpoolDraft draft) async {
    final Map<Object?, Object?> r = await _call('createCarpool', draft.toJson());
    final Object? id = r['carpoolId'];
    if (id is! String) {
      throw const CarpoolFailure(CarpoolFailureKind.unknown);
    }
    return id;
  }

  @override
  Future<List<Carpool>> search(CarpoolQuery query) async {
    final Map<Object?, Object?> r = await _call('searchCarpools', query.toJson());
    final Object? list = r['carpools'];
    return <Carpool>[
      if (list is List<Object?>)
        for (final Object? c in list) Carpool.fromSearch(_map(c)),
    ];
  }

  @override
  Future<void> requestToJoin({required String carpoolId, required List<String> childIds, required bool acceptContribution}) =>
      _call('requestToJoinCarpool', <String, Object?>{
        'carpoolId': carpoolId,
        'childIds': childIds,
        'acceptRules': true,
        // The join sheet sends only after the volunteer box is ticked.
        'acceptVolunteer': true,
        'acceptContribution': acceptContribution,
      });

  @override
  Future<void> cancelRequest(String carpoolId) => _call('cancelJoinRequest', <String, Object?>{'carpoolId': carpoolId});

  @override
  Future<void> decide({required String carpoolId, required String uid, required bool approve}) =>
      _call('decideJoinRequest', <String, Object?>{'carpoolId': carpoolId, 'uid': uid, 'approve': approve});

  @override
  Future<void> leave(String carpoolId) => _call('leaveCarpool', <String, Object?>{'carpoolId': carpoolId});

  @override
  Future<void> setConsent({required String carpoolId, required String driverUid, required bool accept}) =>
      _call('setDriverConsent', <String, Object?>{'carpoolId': carpoolId, 'driverUid': driverUid, 'accept': accept});

  @override
  Future<void> setPickupSharing({required String carpoolId, required bool share}) =>
      _call('setPickupSharing', <String, Object?>{'carpoolId': carpoolId, 'share': share});

  @override
  Future<CarpoolInvite> createInvite(String carpoolId) async {
    final Map<Object?, Object?> r = await _call('createCarpoolInvite', <String, Object?>{'carpoolId': carpoolId});
    final Object? code = r['code'];
    final Object? url = r['url'];
    if (code is! String || url is! String) {
      throw const CarpoolFailure(CarpoolFailureKind.unknown);
    }
    return CarpoolInvite(code: code, url: url);
  }

  @override
  Future<String> openInvite(String code) async {
    final Map<Object?, Object?> r = await _call('openCarpoolInvite', <String, Object?>{'code': code});
    final Object? id = r['carpoolId'];
    if (id is! String) {
      throw const CarpoolFailure(CarpoolFailureKind.inviteInvalid);
    }
    return id;
  }

  @override
  Future<WantedList> listWanted({required String schoolId, String? areaId}) async {
    final Map<Object?, Object?> r = await _call('listCarpoolWanted', <String, Object?>{'schoolId': schoolId, 'areaId': ?areaId});
    final Object? posts = r['posts'];
    return WantedList(
      posts: <WantedPost>[
        if (posts is List<Object?>)
          for (final Object? p in posts) WantedPost.fromMap(p),
      ],
      suggestion: WantedSuggestion.fromMap(r['suggestion']),
    );
  }

  @override
  Future<void> saveWanted(WantedDraft draft) => _call('saveCarpoolWanted', draft.toJson());

  @override
  Future<void> deleteWanted() => _call('deleteCarpoolWanted', const <String, Object?>{});
}

final Provider<CarpoolRepository> carpoolRepositoryProvider = Provider<CarpoolRepository>(
  (Ref ref) => FirebaseCarpoolRepository(functionsClient(), ref.watch(firestoreProvider)),
);

/// The signed-in parent's memberships (any status).
final StreamProvider<List<Membership>> myMembershipsProvider = StreamProvider<List<Membership>>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<List<Membership>>.value(const <Membership>[]);
  }
  return ref.watch(carpoolRepositoryProvider).myMemberships(session.uid);
});

/// Shares an invite link (F31): WhatsApp, or copy.
abstract interface class LinkSharer {
  /// Opens WhatsApp with [text]; false when it could not be opened.
  Future<bool> shareOnWhatsApp(String text);
  Future<void> copy(String text);
}

/// WhatsApp through its official https://wa.me link, which iOS opens in
/// the WhatsApp app (no URL scheme query needed).
class UrlLinkSharer implements LinkSharer {
  const UrlLinkSharer();

  @override
  Future<bool> shareOnWhatsApp(String text) async {
    try {
      return await launchUrl(Uri.https('wa.me', '/', <String, String>{'text': text}), mode: LaunchMode.externalApplication);
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}

final Provider<LinkSharer> linkSharerProvider = Provider<LinkSharer>((Ref ref) => const UrlLinkSharer());

/// An invite code that arrived before the parent could open it (signed
/// out or not verified yet). Kept on the phone until it is opened. Not
/// personal data: a code only says which carpool to show after verification.
class PendingInvite extends Notifier<String?> {
  static const String storageKey = 'carpools.pendingInvite';

  @override
  String? build() => ref.watch(settingsStoreProvider).read(storageKey);

  Future<void> save(String? code) async {
    state = code;
    await ref.read(settingsStoreProvider).write(storageKey, code);
  }
}

final NotifierProvider<PendingInvite, String?> pendingInviteProvider = NotifierProvider<PendingInvite, String?>(PendingInvite.new);

/// The invite code in a link path `/c/<code>` (or the in-app
/// `/carpools/invite/<code>`), or null.
String? inviteCodeFromPath(String path) {
  final RegExpMatch? m = RegExp(r'^/(?:c|carpools/invite)/([2-9A-HJ-NP-Za-hj-np-z]{10})/?$').firstMatch(path);
  return m?[1]?.toUpperCase();
}
