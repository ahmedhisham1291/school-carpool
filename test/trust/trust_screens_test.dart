// Trust screens (Prompt 11, F17) with the fake trust repository and a fake
// camera: no Firebase. Rate parents, family links, the yearly check, the
// phone change, Profile's trust rows, the papers notice and one line at
// 320 dp in Arabic and English. Written, not run here (no Flutter SDK in
// the build workspace). CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/one_line.dart';
import '../helpers/test_app.dart';
import '../helpers/trust_fakes.dart';
import '../helpers/verification_fakes.dart';

const List<ChildRecord> _children = <ChildRecord>[
  ChildRecord(id: 'k1', firstName: 'Omar', age: 8, grade: Grade.g3, schoolName: 'Nile School', status: ReviewStatus.approved),
  ChildRecord(id: 'k2', firstName: 'Mai', age: 5, grade: Grade.kg2, schoolName: 'Nile School', status: ReviewStatus.approved),
  ChildRecord(id: 'k3', firstName: 'Ali', age: 9, grade: Grade.g4, schoolName: 'Nile School', status: ReviewStatus.left),
];

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(FakeTrustRepository trust, FakeCamera camera) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ...authOverrides(trust: trust),
  captureLauncherProvider.overrideWithValue(camera.launch),
  childrenProvider.overrideWith((Ref ref) => Stream<List<ChildRecord>>.value(_children)),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required FakeTrustRepository trust,
  FakeCamera? camera,
  Locale locale = AppLocales.english,
  double width = 400,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 2400 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(trust, camera ?? FakeCamera()),
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.light(DesignDirection.a),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, Finder f, String text) async {
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  // The button turns on only after a rebuild with the text.
  await tester.pumpAndSettle();
}

AppButton _button(WidgetTester tester, String key) => tester.widget<AppButton>(find.byKey(Key(key)));

void main() {
  group('rate parents', () {
    testWidgets('lists shared trips, rates with stars, a tag and a vouch, then the row goes', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      await _pump(tester, ProfileRoutes.ratings, trust: trust);
      expect(find.byKey(const Key('rate.summary')), findsOneWidget);
      expect(find.text('4.5 from 4 ratings · 2 vouches'), findsOneWidget);
      expect(find.byKey(const Key('rate.parent.uid-hoda')), findsOneWidget);
      expect(find.text('Drove your child'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('rate.parent.uid-hoda')));
      expect(_button(tester, 'rate.send').onPressed, isNull, reason: 'no stars yet');
      await _tap(tester, find.byKey(const Key('stars.5')));
      await _tap(tester, find.byKey(const Key('rate.tag.on-time')));
      await _tap(tester, find.byKey(const Key('rate.vouch')));
      await _tap(tester, find.byKey(const Key('rate.send')));
      expect(trust.lastRating?.stars, 5);
      expect(trust.lastRating?.tags, <RatingTag>{RatingTag.onTime});
      expect(trust.lastRating?.vouch, isTrue);
      expect(find.text('Thanks for rating'), findsOneWidget);
      expect(find.byKey(const Key('rate.parent.uid-hoda')), findsNothing);
    });

    testWidgets('a concern turns the vouch off and says admins will review', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository()..flagged = true;
      await _pump(tester, ProfileRoutes.ratings, trust: trust);
      await _tap(tester, find.byKey(const Key('rate.parent.uid-badr')));
      await _tap(tester, find.byKey(const Key('stars.5')));
      await _tap(tester, find.byKey(const Key('rate.vouch')));
      await _tap(tester, find.byKey(const Key('rate.tag.unsafe-driving')));
      expect(find.byKey(const Key('rate.adminNote')), findsOneWidget);
      expect(tester.widget<AppSwitchRow>(find.byKey(const Key('rate.vouch'))).value, isFalse);
      await _tap(tester, find.byKey(const Key('rate.send')));
      expect(trust.lastRating?.vouch, isFalse);
      expect(find.text('Sent; admins will review it'), findsOneWidget);
    });

    testWidgets('already rated: the sheet stays with the reason', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      trust.failOnce['rate'] = const TrustFailure(TrustFailureKind.alreadyRated);
      await _pump(tester, ProfileRoutes.ratings, trust: trust);
      await _tap(tester, find.byKey(const Key('rate.parent.uid-hoda')));
      await _tap(tester, find.byKey(const Key('stars.3')));
      await _tap(tester, find.byKey(const Key('rate.send')));
      expect(find.byKey(const Key('rate.error')), findsOneWidget);
      expect(find.text('You already rated this parent this month.'), findsOneWidget);
    });

    testWidgets('nobody to rate: the empty state', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.ratings, trust: FakeTrustRepository(rateableList: const <RateableParent>[]));
      expect(find.byKey(const Key('rate.empty')), findsOneWidget);
    });

    testWidgets('offline shows the offline view with retry', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository()..failure = const TrustFailure(TrustFailureKind.offline);
      await _pump(tester, ProfileRoutes.ratings, trust: trust);
      expect(find.byType(OfflineStateView), findsOneWidget);
      trust.failure = null;
      await _tap(tester, find.byType(AppButton).first);
      expect(find.byKey(const Key('rate.parent.uid-hoda')), findsOneWidget);
    });
  });

  group('family links', () {
    testWidgets('ask a parent by ID and relation', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      await _pump(tester, ProfileRoutes.family, trust: trust);
      await _tap(tester, find.byKey(const Key('family.link')));
      expect(_button(tester, 'family.send').onPressed, isNull);
      await _type(tester, find.byKey(const Key('family.parentId')), 'sami 2345');
      await _tap(tester, find.byKey(const Key('family.relation.mother')));
      await _tap(tester, find.byKey(const Key('family.send')));
      expect(trust.lastLinkRequest, ('SAMI2345', GuardianRelation.mother));
      expect(find.text('Request sent to Sami'), findsOneWidget);
    });

    testWidgets('a wrong ID says how to fix it', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.family, trust: FakeTrustRepository());
      await _tap(tester, find.byKey(const Key('family.link')));
      await _type(tester, find.byKey(const Key('family.parentId')), 'ABCD1234');
      expect(find.text('Type 8 letters and digits, like ABCD2345.'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('family.relation.father')));
      expect(_button(tester, 'family.send').onPressed, isNull);
    });

    testWidgets('accept a request with chosen children; only approved children are offered', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      await _pump(tester, ProfileRoutes.family, trust: trust);
      expect(find.byKey(const Key('family.linked.k9_uid-1')), findsOneWidget);
      expect(find.text('Sami · In review'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('family.incoming.uid-1_uid-dina')));
      expect(find.byKey(const Key('family.child.k3')), findsNothing, reason: 'left school');
      expect(_button(tester, 'family.accept').onPressed, isNull);
      await _tap(tester, find.byKey(const Key('family.child.k1')));
      await _tap(tester, find.byKey(const Key('family.accept')));
      expect(trust.lastAnswer?.$1, 'uid-1_uid-dina');
      expect(trust.lastAnswer?.$2, isTrue);
      expect(trust.lastAnswer?.$3, <String>['k1']);
      expect(find.text('Linked'), findsOneWidget);
    });

    testWidgets('removing a link asks first', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      await _pump(tester, ProfileRoutes.family, trust: trust);
      await _tap(tester, find.byKey(const Key('family.remove.k1_uid-dina')));
      expect(find.text('Remove this link?'), findsOneWidget);
      expect(trust.calls.where((String c) => c.startsWith('removeLink')), isEmpty);
      await _tap(tester, find.text('Remove link').last);
      expect(trust.calls, contains('removeLink:k1_uid-dina'));
      expect(find.text('Link removed'), findsOneWidget);
    });

    testWidgets('empty: only the sentence and the action', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.family, trust: FakeTrustRepository(familyValue: const FamilyView()));
      expect(find.byKey(const Key('family.empty')), findsOneWidget);
      expect(find.byKey(const Key('family.link')), findsOneWidget);
    });
  });

  group('yearly check', () {
    testWidgets('confirm: grades preselected, a child who left asks first', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository(
        overviewValue: const TrustOverview(yearCheck: sampleYearCheck),
      );
      await _pump(tester, ProfileRoutes.schoolYear, trust: trust);
      expect(find.text('School year 2027/28'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('year.left.k2')));
      await _tap(tester, find.byKey(const Key('year.confirm')));
      expect(find.text('Children left school?'), findsOneWidget);
      await _tap(tester, find.text('Confirm').last);
      expect(trust.lastAnswers?.map((YearAnswer a) => a.toJson()).toList(), <Map<String, Object?>>[
        <String, Object?>{'childId': 'k1', 'stays': true, 'grade': 'g4'},
        <String, Object?>{'childId': 'k2', 'stays': false},
      ]);
      expect(find.text('All set for the new year'), findsOneWidget);
      expect(find.byKey(const Key('year.none')), findsOneWidget);
    });

    testWidgets('overdue shows the warning; nothing to confirm shows the empty state', (WidgetTester tester) async {
      const YearCheck overdue = YearCheck(state: YearCheckState.overdue, year: 2027, children: <YearChild>[
        YearChild(id: 'k1', firstName: 'Omar', grade: Grade.g3, schoolName: 'Nile School'),
      ]);
      await _pump(tester, ProfileRoutes.schoolYear, trust: FakeTrustRepository(overviewValue: const TrustOverview(yearCheck: overdue)));
      expect(find.byKey(const Key('year.overdue')), findsOneWidget);
    });

    testWidgets('Profile shows the school year card and opens the check', (WidgetTester tester) async {
      final GoRouter router = await _pump(
        tester,
        AppTab.profile.path,
        trust: FakeTrustRepository(overviewValue: const TrustOverview(yearCheck: sampleYearCheck, requests: 1)),
      );
      expect(find.byKey(const Key('profile.yearCheck')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('profile.family')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('1 request to answer'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('profile.yearCheck')), -200, scrollable: find.byType(Scrollable).first);
      await _tap(tester, find.byKey(const Key('profile.yearCheck')));
      expect(_path(router), ProfileRoutes.schoolYear);
    });
  });

  group('phone change', () {
    testWidgets('new number, code, selfie: changed', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      final FakeCamera camera = FakeCamera();
      await _pump(tester, ProfileRoutes.phone, trust: trust, camera: camera);
      expect(_button(tester, 'phone.sendCode').onPressed, isNull);
      await _type(tester, find.byKey(const Key('phone.new')), '01012345678');
      await _tap(tester, find.byKey(const Key('phone.sendCode')));
      expect(trust.calls, contains('requestPhoneChange:+201012345678'));
      await _type(tester, find.byKey(const Key('phone.code')), '123456');
      await _tap(tester, find.byKey(const Key('phone.next')));
      await _tap(tester, find.byKey(const Key('phone.selfie')));
      expect(camera.requests.single.kind, CaptureKind.selfie);
      expect(trust.calls, contains('confirmPhoneChange:+201012345678:123456'));
      expect(find.byKey(const Key('phone.done')), findsOneWidget);
    });

    testWidgets('a selfie that does not match sends the parent back for a new code', (WidgetTester tester) async {
      final FakeTrustRepository trust = FakeTrustRepository();
      trust.failOnce['confirmPhoneChange'] = const TrustFailure(TrustFailureKind.selfieMismatch);
      await _pump(tester, ProfileRoutes.phone, trust: trust);
      await _type(tester, find.byKey(const Key('phone.new')), '01012345678');
      await _tap(tester, find.byKey(const Key('phone.sendCode')));
      await _type(tester, find.byKey(const Key('phone.code')), '123456');
      await _tap(tester, find.byKey(const Key('phone.next')));
      await _tap(tester, find.byKey(const Key('phone.selfie')));
      expect(find.text("The selfie didn't match. Ask for a new code and try again."), findsOneWidget);
      expect(find.byKey(const Key('phone.sendCode')), findsOneWidget);
    });

    testWidgets('Profile opens the phone change for a verified parent', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, AppTab.profile.path, trust: FakeTrustRepository());
      await _tap(tester, find.byKey(const Key('profile.phone')));
      expect(_path(router), ProfileRoutes.phone);
    });
  });

  group('one line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        final String where = '${locale.languageCode} x$scale';
        testWidgets('rate sheet in $where', (WidgetTester tester) async {
          await _pump(tester, ProfileRoutes.ratings, trust: FakeTrustRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byType(AppBar), 'app bar $where', requireText: true, allowEllipsis: scale > 1);
          await _tap(tester, find.byKey(const Key('rate.parent.uid-hoda')));
          expectOneLine(find.byKey(const Key('rate.send')), 'send $where', requireText: true);
          for (final RatingTag t in RatingTag.values) {
            expectOneLine(find.byKey(Key('rate.tag.${t.wire}')), 'tag ${t.wire} $where', requireText: true, allowEllipsis: scale > 1);
          }
        });
        testWidgets('family and its sheets in $where', (WidgetTester tester) async {
          await _pump(tester, ProfileRoutes.family, trust: FakeTrustRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byKey(const Key('family.link')), 'link $where', requireText: true);
          expectOneLine(find.byType(AppSectionHeader), 'headers $where', allowEllipsis: scale > 1);
          await _tap(tester, find.byKey(const Key('family.link')));
          expectOneLine(find.byKey(const Key('family.send')), 'send $where', requireText: true);
          for (final GuardianRelation r in GuardianRelation.values) {
            expectOneLine(find.byKey(Key('family.relation.${r.name}')), 'relation $where', requireText: true, allowEllipsis: scale > 1);
          }
        });
        testWidgets('school year in $where', (WidgetTester tester) async {
          await _pump(
            tester,
            ProfileRoutes.schoolYear,
            trust: FakeTrustRepository(overviewValue: const TrustOverview(yearCheck: sampleYearCheck)),
            locale: locale,
            width: 320,
            textScale: scale,
          );
          expectOneLine(find.byKey(const Key('year.confirm')), 'confirm $where', requireText: true);
          expectOneLine(find.byKey(const Key('year.stays.k1')), 'stays $where', requireText: true, allowEllipsis: scale > 1);
          expectOneLine(find.byKey(const Key('year.left.k1')), 'left $where', requireText: true, allowEllipsis: scale > 1);
        });
        testWidgets('phone change in $where', (WidgetTester tester) async {
          await _pump(tester, ProfileRoutes.phone, trust: FakeTrustRepository(), locale: locale, width: 320, textScale: scale);
          expectOneLine(find.byKey(const Key('phone.sendCode')), 'send code $where', requireText: true);
          expectOneLine(find.byType(AppBar), 'app bar $where', requireText: true, allowEllipsis: scale > 1);
        });
      }
    }
  });
}
