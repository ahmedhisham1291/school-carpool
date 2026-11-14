import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Trust in the admin panel (Prompt 11: F14, F17): guardian links that need
/// an admin (a guardian who is not a parent, or a child already linked to
/// another adult) and rating flags (low stars or "unsafe driving"). Every
/// decision is in the audit log. Every method throws [AdminFailure].
abstract interface class AdminTrustApi {
  Future<TrustQueue> queue();
  Future<void> decideLink({required String linkId, required bool approve});
  Future<void> resolveFlag({required String flagId, required FlagOutcome outcome});
}

enum FlagOutcome {
  noIssue('no-issue'),
  contacted('contacted'),
  escalated('escalated');

  const FlagOutcome(this.wire);

  final String wire;
}

@immutable
class ReviewLink {
  const ReviewLink({
    required this.id,
    required this.childFirstName,
    required this.ownerFirstName,
    required this.guardianFirstName,
    required this.guardianUid,
    required this.relation,
    this.createdAt,
  });

  factory ReviewLink.fromJson(Json j) => ReviewLink(
    id: j.str('id'),
    childFirstName: j.str('childFirstName'),
    ownerFirstName: j.str('ownerFirstName'),
    guardianFirstName: j.str('guardianFirstName'),
    guardianUid: j.str('guardianUid'),
    relation: j.str('relation', 'guardian'),
    createdAt: j.time('createdAtMs'),
  );

  final String id;
  final String childFirstName;
  final String ownerFirstName;
  final String guardianFirstName;
  final String guardianUid;

  /// father, mother or guardian.
  final String relation;
  final DateTime? createdAt;
}

@immutable
class RatingFlagItem {
  const RatingFlagItem({
    required this.id,
    required this.stars,
    required this.tags,
    required this.rateeUid,
    required this.rateeFirstName,
    required this.raterFirstName,
    this.createdAt,
  });

  factory RatingFlagItem.fromJson(Json j) {
    final Object? raw = j.map['tags'];
    return RatingFlagItem(
      id: j.str('id'),
      stars: j.integer('stars'),
      tags: <String>[
        if (raw is List<Object?>)
          for (final Object? t in raw)
            if (t is String) t,
      ],
      rateeUid: j.str('rateeUid'),
      rateeFirstName: j.str('rateeFirstName'),
      raterFirstName: j.str('raterFirstName'),
      createdAt: j.time('createdAtMs'),
    );
  }

  final String id;
  final int stars;
  final List<String> tags;
  final String rateeUid;
  final String rateeFirstName;
  final String raterFirstName;
  final DateTime? createdAt;
}

@immutable
class TrustQueue {
  const TrustQueue({this.links = const <ReviewLink>[], this.flags = const <RatingFlagItem>[]});

  final List<ReviewLink> links;
  final List<RatingFlagItem> flags;
}

class FirebaseAdminTrustApi implements AdminTrustApi {
  FirebaseAdminTrustApi(this._functions);

  final FirebaseFunctions _functions;

  Future<Json> _call(String name, [Map<String, Object?> data = const <String, Object?>{}]) async {
    try {
      final HttpsCallableResult<Object?> result = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: const Duration(seconds: 30)))
          .call<Object?>(data);
      return Json.of(result.data);
    } on Object catch (error, stackTrace) {
      Error.throwWithStackTrace(AdminFailure.from(error), stackTrace);
    }
  }

  @override
  Future<TrustQueue> queue() async {
    final Json j = await _call('adminTrustQueue');
    return TrustQueue(links: j.list('links').map(ReviewLink.fromJson).toList(), flags: j.list('flags').map(RatingFlagItem.fromJson).toList());
  }

  @override
  Future<void> decideLink({required String linkId, required bool approve}) async {
    await _call('adminDecideGuardianLink', <String, Object?>{'linkId': linkId, 'approve': approve});
  }

  @override
  Future<void> resolveFlag({required String flagId, required FlagOutcome outcome}) async {
    await _call('adminResolveRatingFlag', <String, Object?>{'flagId': flagId, 'outcome': outcome.wire});
  }
}

final Provider<AdminTrustApi> adminTrustApiProvider = Provider<AdminTrustApi>((Ref ref) => FirebaseAdminTrustApi(functionsClient()));
