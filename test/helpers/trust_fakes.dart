import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

/// Trust fakes (Prompt 11). Fake data only.

const List<RateableParent> sampleRateable = <RateableParent>[
  RateableParent(uid: 'uid-hoda', firstName: 'Hoda', drove: true, date: null),
  RateableParent(uid: 'uid-badr', firstName: 'Badr', drove: false, date: null),
];

const YearCheck sampleYearCheck = YearCheck(
  state: YearCheckState.due,
  year: 2027,
  children: <YearChild>[
    YearChild(id: 'k1', firstName: 'Omar', grade: Grade.g3, schoolName: 'Nile School'),
    YearChild(id: 'k2', firstName: 'Mai', grade: Grade.kg2, schoolName: 'Nile School'),
  ],
);

const FamilyView sampleFamily = FamilyView(
  incoming: <GuardianRequest>[GuardianRequest(id: 'uid-1_uid-dina', guardianFirstName: 'Dina', relation: GuardianRelation.mother)],
  outgoing: <GuardianRequest>[GuardianRequest(id: 'uid-sami_uid-1', guardianFirstName: 'Test', relation: GuardianRelation.father)],
  shared: <GuardianLink>[
    GuardianLink(id: 'k1_uid-dina', childFirstName: 'Omar', ownerFirstName: 'Test', guardianFirstName: 'Dina', relation: GuardianRelation.mother, status: LinkStatus.active),
  ],
  linked: <GuardianLink>[
    GuardianLink(id: 'k9_uid-1', childFirstName: 'Laila', ownerFirstName: 'Sami', guardianFirstName: 'Test', relation: GuardianRelation.guardian, status: LinkStatus.review),
  ],
);

/// Records calls; [failure] is thrown by every call when set.
class FakeTrustRepository implements TrustRepository {
  FakeTrustRepository({
    this.overviewValue = const TrustOverview(summary: TrustSummary(ratings: 4, average: 4.5, vouches: 2), toRate: 2),
    this.rateableList = sampleRateable,
    this.familyValue = sampleFamily,
  });

  TrustOverview overviewValue;
  List<RateableParent> rateableList;
  FamilyView familyValue;
  final List<String> calls = <String>[];
  TrustFailure? failure;

  /// Fails only the next call with this name (then clears).
  final Map<String, TrustFailure> failOnce = <String, TrustFailure>{};
  RatingDraft? lastRating;
  List<YearAnswer>? lastAnswers;
  (String, GuardianRelation)? lastLinkRequest;
  (String, bool, List<String>)? lastAnswer;
  bool flagged = false;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final String name = call.split(':').first;
    final TrustFailure? once = failOnce.remove(name);
    if (once != null) {
      throw once;
    }
    final TrustFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<TrustOverview> overview() async {
    await _maybeFail('overview');
    return overviewValue;
  }

  @override
  Future<List<RateableParent>> rateable() async {
    await _maybeFail('rateable');
    return rateableList;
  }

  @override
  Future<bool> rate(RatingDraft draft) async {
    await _maybeFail('rate:${draft.uid}');
    lastRating = draft;
    rateableList = <RateableParent>[for (final RateableParent p in rateableList) if (p.uid != draft.uid) p];
    return flagged;
  }

  @override
  Future<void> confirmSchoolYear({required int year, required List<YearAnswer> answers}) async {
    await _maybeFail('confirmSchoolYear:$year');
    lastAnswers = answers;
    overviewValue = TrustOverview(summary: overviewValue.summary, toRate: overviewValue.toRate, yearCheck: const YearCheck(state: YearCheckState.done, year: 2027));
  }

  @override
  Future<FamilyView> family() async {
    await _maybeFail('family');
    return familyValue;
  }

  @override
  Future<String> requestLink({required String parentId, required GuardianRelation relation}) async {
    await _maybeFail('requestLink:$parentId');
    lastLinkRequest = (parentId, relation);
    return 'Sami';
  }

  @override
  Future<void> cancelLinkRequest(String requestId) => _maybeFail('cancelLinkRequest:$requestId');

  @override
  Future<void> answerLinkRequest({required String requestId, required bool accept, List<String> childIds = const <String>[]}) async {
    await _maybeFail('answerLinkRequest:$requestId');
    lastAnswer = (requestId, accept, childIds);
  }

  @override
  Future<void> removeLink(String linkId) => _maybeFail('removeLink:$linkId');

  @override
  Future<void> requestPhoneChange({required String phoneE164, required String language}) => _maybeFail('requestPhoneChange:$phoneE164');

  @override
  Future<void> confirmPhoneChange({required String uid, required String phoneE164, required String code, required Uint8List selfie}) =>
      _maybeFail('confirmPhoneChange:$phoneE164:$code');
}

/// Same shape in every call (one ProviderScope per test).
List<Override> trustOverrides({FakeTrustRepository? repository}) => <Override>[
  trustRepositoryProvider.overrideWithValue(repository ?? FakeTrustRepository()),
];
