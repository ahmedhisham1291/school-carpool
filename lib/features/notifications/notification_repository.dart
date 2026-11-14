import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Notifications (Prompt 8: F12, F23). The app reads its own in-app
/// records and settings and may only set `readAt` (firestore.rules).
/// Settings and phones go through Cloud Functions.
abstract interface class NotificationRepository {
  /// The newest [kNotificationsPageSize] notifications of [uid], newest first.
  Stream<List<AppNotification>> watch(String uid);

  /// Sets readAt to the server time. Already read: nothing happens.
  Future<void> markRead(String uid, String id);

  /// One batch for every id (at most [kNotificationsPageSize]).
  Future<void> markAllRead(String uid, List<String> ids);

  Stream<NotificationSettings> watchSettings(String uid);

  /// Throws [NotificationFailure].
  Future<void> setWhatsApp(WhatsAppGroup group, {required bool on});
  Future<void> setQuietHours({required bool on});

  /// Saves this phone's push token for the signed-in parent.
  Future<void> registerDevice({required String token, required String platform, String? previousToken});

  /// Removes this phone's token before signing out.
  Future<void> unregisterDevice(String token);
}

/// The Notifications tab shows this many (rules allow up to 100).
const int kNotificationsPageSize = 50;

class FirebaseNotificationRepository implements NotificationRepository {
  FirebaseNotificationRepository(this._functions, this._db);

  final FirebaseFunctions _functions;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _records(String uid) =>
      _db.collection('users').doc(uid).collection('notifications');

  Future<void> _call(String name, Map<String, Object?> data) async {
    try {
      await _functions.httpsCallable(name).call<Object?>(data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(NotificationFailure.from(error), stackTrace);
    }
  }

  @override
  Stream<List<AppNotification>> watch(String uid) => _records(uid)
      .orderBy('createdAt', descending: true)
      .limit(kNotificationsPageSize)
      .snapshots()
      .map(
        (QuerySnapshot<Map<String, dynamic>> s) => <AppNotification>[
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in s.docs)
            if (NotificationKind.fromWire(d.data()['type']) case final NotificationKind kind)
              AppNotification.fromDoc(d.id, kind, d.data()),
        ],
      );

  @override
  Future<void> markRead(String uid, String id) async {
    try {
      await _records(uid).doc(id).update(<String, Object?>{'readAt': FieldValue.serverTimestamp()});
    } on FirebaseException catch (error) {
      // Already read (the rule allows one change) or gone: nothing to do.
      if (error.code != 'permission-denied' && error.code != 'not-found') {
        rethrow;
      }
    }
  }

  @override
  Future<void> markAllRead(String uid, List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }
    final WriteBatch batch = _db.batch();
    for (final String id in ids.take(kNotificationsPageSize)) {
      batch.update(_records(uid).doc(id), <String, Object?>{'readAt': FieldValue.serverTimestamp()});
    }
    try {
      await batch.commit();
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(NotificationFailure.from(error), stackTrace);
    }
  }

  @override
  Stream<NotificationSettings> watchSettings(String uid) => _db
      .collection('notificationSettings')
      .doc(uid)
      .snapshots()
      .map((DocumentSnapshot<Map<String, dynamic>> s) => NotificationSettings.fromDoc(s.data()));

  @override
  Future<void> setWhatsApp(WhatsAppGroup group, {required bool on}) => _call('updateNotificationSettings', <String, Object?>{
    'whatsapp': <String, Object?>{group.name: on},
  });

  @override
  Future<void> setQuietHours({required bool on}) => _call('updateNotificationSettings', <String, Object?>{
    'quiet': <String, Object?>{'on': on},
  });

  @override
  Future<void> registerDevice({required String token, required String platform, String? previousToken}) =>
      _call('registerPushDevice', <String, Object?>{
        'token': token,
        'platform': platform,
        'previousToken': ?previousToken,
      });

  @override
  Future<void> unregisterDevice(String token) => _call('unregisterPushDevice', <String, Object?>{'token': token});
}

final Provider<NotificationRepository> notificationRepositoryProvider = Provider<NotificationRepository>(
  (Ref ref) => FirebaseNotificationRepository(functionsClient(), ref.watch(firestoreProvider)),
);

/// The signed-in parent's uid, or null.
String? _uid(Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  return session is SessionSignedIn ? session.uid : null;
}

/// The parent's notifications, newest first (empty when signed out).
final StreamProvider<List<AppNotification>> notificationsProvider = StreamProvider<List<AppNotification>>((Ref ref) {
  final String? uid = _uid(ref);
  if (uid == null) {
    return Stream<List<AppNotification>>.value(const <AppNotification>[]);
  }
  return ref.watch(notificationRepositoryProvider).watch(uid);
});

/// Unread notifications (the tab's dot).
final Provider<int> unreadCountProvider = Provider<int>(
  (Ref ref) => (ref.watch(notificationsProvider).value ?? const <AppNotification>[]).where((AppNotification n) => n.unread).length,
);

/// The newest unread critical alert, for the in-app banner (spec section 11).
final Provider<AppNotification?> openCriticalProvider = Provider<AppNotification?>((Ref ref) {
  for (final AppNotification n in ref.watch(notificationsProvider).value ?? const <AppNotification>[]) {
    if (n.critical && n.unread) {
      return n;
    }
  }
  return null;
});

final StreamProvider<NotificationSettings> notificationSettingsProvider = StreamProvider<NotificationSettings>((Ref ref) {
  final String? uid = _uid(ref);
  if (uid == null) {
    return Stream<NotificationSettings>.value(const NotificationSettings());
  }
  return ref.watch(notificationRepositoryProvider).watchSettings(uid);
});
