import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/about/about_screen.dart';
import 'package:school_carpool/features/schools/other_school_screen.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_picker_screen.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/schools/school_search.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/fonts.dart';
import '../helpers/school_fakes.dart';
import '../helpers/test_app.dart';

/// Opens the picker from a button and records what it returns.
class _Opener extends StatefulWidget {
  const _Opener();

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  SchoolOption? picked;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('open'),
        onPressed: () async {
          final SchoolOption? school = await openSchoolPicker(context);
          setState(() => picked = school);
        },
        child: Text(picked?.id ?? 'none'),
      ),
    ),
  );
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  Locale locale = AppLocales.english,
  FakeSchoolSearch? search,
  FakeSchoolRepository? repository,
  double width = 400,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, 900 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestApp(
      const _Opener(),
      locale: locale,
      extraOverrides: <Override>[
        ...authOverrides(session: testUnverifiedSession),
        ...schoolOverrides(search: search, repository: repository),
      ],
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('school.search')), text);
  // Past the debounce.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// The last row of the results list.
Widget _lastRow(WidgetTester tester) {
  final ListView list = tester.widget<ListView>(find.byKey(const Key('school.results')));
  final SliverChildListDelegate delegate = list.childrenDelegate as SliverChildListDelegate;
  return delegate.children.last;
}

void main() {
  setUpAll(loadAppFonts);

  group('school picker', () {
    testWidgets('finds a school by part of its name in Arabic and in English, and returns it', (
      WidgetTester tester,
    ) async {
      final FakeSchoolSearch search = FakeSchoolSearch();
      await _pumpPicker(tester, search: search);
      expect(find.text('Type at least 2 letters of the school\'s name.'), findsOneWidget);

      await _type(tester, 'نيل');
      expect(find.byKey(const Key('school.result.nile')), findsOneWidget);
      await _type(tester, 'vict');
      expect(find.byKey(const Key('school.result.victoria')), findsOneWidget);
      expect(find.byKey(const Key('school.result.nile')), findsNothing);
      expect(search.queries.map(((String, String?) q) => q.$1), containsAll(<String>['نيل', 'vict']));

      await tester.tap(find.byKey(const Key('school.result.victoria')));
      await tester.pumpAndSettle();
      expect(find.text('victoria'), findsOneWidget);
    });

    testWidgets('"Other" is the last row in every state', (WidgetTester tester) async {
      final FakeSchoolSearch search = FakeSchoolSearch();
      await _pumpPicker(tester, search: search);
      expect(_lastRow(tester).key, const Key('school.other'));

      await _type(tester, 'Nile');
      expect(_lastRow(tester).key, const Key('school.other'));

      await _type(tester, 'zzzz');
      expect(find.text('No school found'), findsOneWidget);
      expect(_lastRow(tester).key, const Key('school.other'));

      search.failure = const SchoolSearchFailure(SchoolSearchFailureKind.offline);
      await _type(tester, 'Nile');
      expect(find.byType(OfflineStateView), findsOneWidget);
      expect(_lastRow(tester).key, const Key('school.other'));

      search.failure = const SchoolSearchFailure(SchoolSearchFailureKind.unavailable);
      await _type(tester, 'Nil');
      expect(find.byType(ErrorStateView), findsOneWidget);
      expect(_lastRow(tester).key, const Key('school.other'));

      // Retry works once the search is back.
      search.failure = null;
      await tester.tap(find.descendant(of: find.byType(ErrorStateView), matching: find.byType(AppButton)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('school.result.nile')), findsOneWidget);
    });

    testWidgets('the governorate filter limits the search', (WidgetTester tester) async {
      final FakeSchoolSearch search = FakeSchoolSearch();
      await _pumpPicker(tester, search: search);
      await _type(tester, 'school');
      expect(find.byKey(const Key('school.result.nile')), findsOneWidget);
      expect(find.byKey(const Key('school.result.orman')), findsOneWidget);

      await tester.tap(find.byKey(const Key('school.governorate')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('school.gov.giza')),
        200,
        scrollable: find.descendant(of: find.byType(AppSheet), matching: find.byType(Scrollable)).first,
      );
      await tester.tap(find.byKey(const Key('school.gov.giza')));
      await tester.pumpAndSettle();
      expect(search.queries.last, ('school', 'giza'));
      expect(find.byKey(const Key('school.result.orman')), findsOneWidget);
      expect(find.byKey(const Key('school.result.nile')), findsNothing);
      expect(find.text('Giza'), findsOneWidget);
    });

    testWidgets('"Other": name, governorate and pin; saved for review and picked at once', (WidgetTester tester) async {
      final FakeSchoolRepository repository = FakeSchoolRepository();
      addTearDown(repository.dispose);
      await _pumpPicker(tester, repository: repository);
      await _type(tester, 'Zohour');
      await tester.tap(find.byKey(const Key('school.other')));
      await tester.pumpAndSettle();

      // The typed text comes along; the button waits for the governorate.
      expect(find.widgetWithText(TextFormField, 'Zohour'), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const Key('other.save'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('other.governorate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cairo').last);
      await tester.pumpAndSettle();

      // A pin outside Egypt is refused as typed, and says how to fix it.
      await tester.enterText(find.byKey(const Key('other.pin')), '48.85, 2.35');
      await tester.pump();
      expect(find.text('This pin is outside Egypt. Check the numbers.'), findsOneWidget);
      expect(tester.widget<AppButton>(find.byKey(const Key('other.save'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('other.pin')), '30.0444, 31.2357');
      await tester.pump();

      await tester.tap(find.byKey(const Key('other.save')));
      await tester.pumpAndSettle();
      expect(repository.added.single.nameAr, 'Zohour');
      expect(repository.added.single.governorate, 'cairo');
      // Back on the opener with the new school: the parent carries on.
      expect(find.text('other-1'), findsOneWidget);
      expect(find.text('School added'), findsOneWidget);
    });

    testWidgets('the parent\'s own schools awaiting review are listed first, marked', (WidgetTester tester) async {
      final FakeSchoolRepository repository = FakeSchoolRepository()
        ..initialPending = const <SchoolOption>[
          SchoolOption(id: 'mine', nameAr: 'مدرسة الزهور', nameEn: 'مدرسة الزهور', governorate: 'cairo', pending: true),
        ];
      addTearDown(repository.dispose);
      await _pumpPicker(tester, repository: repository);
      expect(find.byKey(const Key('school.result.mine')), findsOneWidget);
      expect(find.text('Awaiting review'), findsOneWidget);
      await _type(tester, 'الزهور');
      expect(find.byKey(const Key('school.result.mine')), findsOneWidget);
    });

    testWidgets('"Other" says what went wrong and keeps the form', (WidgetTester tester) async {
      final FakeSchoolRepository repository = FakeSchoolRepository()
        ..failure = const OtherSchoolFailure(OtherSchoolFailureKind.offline);
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        buildTestApp(
          const OtherSchoolScreen(initialName: 'Zohour School', initialGovernorate: 'giza'),
          locale: AppLocales.english,
          extraOverrides: schoolOverrides(repository: repository),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('other.save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('other.error')), findsOneWidget);
      expect(find.text('No connection. Try again.'), findsOneWidget);
      expect(find.byType(OtherSchoolScreen), findsOneWidget);
    });
  });

  group('About', () {
    for (final Locale locale in AppLocales.supported) {
      testWidgets('[${locale.languageCode}] shows the OpenStreetMap credit and copies the link', (
        WidgetTester tester,
      ) async {
        final List<MethodCall> clipboard = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(call);
          }
          return null;
        });
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await tester.pumpWidget(buildTestApp(const AboutScreen(), locale: locale));
        await tester.pumpAndSettle();
        final Text credit = tester.widget<Text>(find.byKey(const Key('about.osmCredit')));
        expect(credit.data, contains('OpenStreetMap'));
        expect(credit.data, contains('ODbL'));
        expect(credit.data, contains('©'));
        await tester.tap(find.byKey(const Key('about.osmLink')));
        await tester.pumpAndSettle();
        expect((clipboard.single.arguments as Map<Object?, Object?>)['text'], kOsmCopyrightUrl);
        expect(find.byType(SnackBar), findsOneWidget);
      });
    }
  });

  group('one line at 320 dp', () {
    void expectOneLine(WidgetTester tester, Finder finder, String where) {
      for (final Element e in find.descendant(of: finder, matching: find.byType(RichText), matchRoot: true).evaluate()) {
        final RenderParagraph p = e.renderObject! as RenderParagraph;
        final String text = p.text.toPlainText();
        if (text.isEmpty) {
          continue;
        }
        final double half = p.size.height / 2;
        final bool wraps = p
            .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length))
            .any((TextBox box) => box.top >= half);
        expect(wraps, isFalse, reason: '"$text" wraps ($where)');
        expect(p.didExceedMaxLines, isFalse, reason: '"$text" is cut off ($where)');
      }
    }

    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;
      testWidgets('[$lang] picker, "Other" form and About labels fit one line', (WidgetTester tester) async {
        await _pumpPicker(tester, locale: locale, width: 320);
        expectOneLine(tester, find.byType(AppBarTitle), 'picker title');
        expectOneLine(tester, find.byKey(const Key('school.governorate')), 'governorate chip');
        expectOneLine(
          tester,
          find.descendant(of: find.byKey(const Key('school.other')), matching: find.byType(OneLineText)),
          'Other row',
        );
        expectOneLine(
          tester,
          find.descendant(of: find.byKey(const Key('school.search')), matching: find.byType(OneLineText)),
          'search label',
        );

        await tester.tap(find.byKey(const Key('school.other')));
        await tester.pumpAndSettle();
        expectOneLine(tester, find.byType(AppBarTitle), 'Other title');
        for (final String key in <String>['other.name', 'other.governorate', 'other.pin', 'other.save']) {
          expectOneLine(
            tester,
            find.descendant(of: find.byKey(Key(key)), matching: find.byType(OneLineText)),
            key,
          );
        }

        // A fresh ProviderScope: the About app has fewer overrides than the picker's.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(buildTestApp(const AboutScreen(), locale: locale));
        await tester.pumpAndSettle();
        expectOneLine(tester, find.byType(AppBarTitle), 'About title');
        for (final String key in <String>['about.osmLink', 'about.licenses']) {
          expectOneLine(
            tester,
            find.descendant(of: find.byKey(Key(key)), matching: find.byType(OneLineText)),
            key,
          );
        }
        expectOneLine(tester, find.byType(AppSectionHeader), 'About sections');
      });
    }
  });
}
