import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/about/about_screen.dart';
import 'package:school_carpool/features/about/legal_links.dart';
import 'package:school_carpool/features/onboarding/terms_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/one_line.dart';
import '../helpers/test_app.dart';

/// App Review audit (docs/apple-review/audit.md): the privacy policy and
/// terms are reachable in the app (5.1.1(i)), the support address is
/// published (1.2), and the store build shows no "draft" note (2.1).
void main() {
  const LegalLinks configured = LegalLinks(siteUrl: 'https://school-carpool-links.web.app', supportEmail: 'help@schoolcarpool.org');

  group('LegalLinks', () {
    test('pages come from an https site only', () {
      expect(configured.privacy.toString(), 'https://school-carpool-links.web.app/privacy');
      expect(configured.terms.toString(), 'https://school-carpool-links.web.app/terms');
      expect(configured.support.toString(), 'https://school-carpool-links.web.app/support');
      expect(configured.deleteAccount.toString(), 'https://school-carpool-links.web.app/delete-account');
      expect(configured.mail.toString(), 'mailto:help@schoolcarpool.org');
      for (final String bad in <String>['', 'http://plain.example', 'javascript:alert(1)', 'not a url', 'https://x.org/?q=1']) {
        final LegalLinks links = LegalLinks(siteUrl: bad, supportEmail: 'nobody');
        expect(links.privacy, isNull, reason: bad);
        expect(links.email, isNull);
        expect(links.mail, isNull);
      }
      // A trailing slash or path on the site does not break the pages.
      expect(const LegalLinks(siteUrl: 'https://a.web.app/', supportEmail: '').privacy.toString(), 'https://a.web.app/privacy');
    });
  });

  group('About: legal and support', () {
    for (final Locale locale in AppLocales.supported) {
      final String lang = locale.languageCode;

      testWidgets('[$lang] documents open in the app and on the web; support opens Mail', (WidgetTester tester) async {
        final List<Uri> opened = <Uri>[];
        await tester.pumpWidget(
          buildTestApp(
            const AboutScreen(),
            locale: locale,
            extraOverrides: [
              legalLinksProvider.overrideWithValue(configured),
              linkOpenerProvider.overrideWithValue((Uri uri) async {
                opened.add(uri);
                return true;
              }),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final AppLocalizations l10n = AppLocalizations.of(tester.element(find.byType(AboutScreen)));

        await tester.tap(find.byKey(const Key('about.privacy')));
        await tester.pumpAndSettle();
        expect(find.text(l10n.termsPrivacyText), findsOneWidget);
        expect(find.text(l10n.termsDraftNotice), findsNothing);
        await tester.tap(find.byKey(const Key('about.documentPage')));
        await tester.pumpAndSettle();
        expect(opened.single.toString(), 'https://school-carpool-links.web.app/privacy');
        Navigator.of(tester.element(find.byKey(const Key('about.documentPage')))).pop();
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('about.support')));
        await tester.pumpAndSettle();
        expect(opened.last.toString(), 'mailto:help@schoolcarpool.org');
        expect(find.textContaining('help@schoolcarpool.org', findRichText: true), findsWidgets);
      });

      testWidgets('[$lang] without a site: documents still open in the app, no contact row, no link', (WidgetTester tester) async {
        await tester.pumpWidget(
          buildTestApp(const AboutScreen(), locale: locale, extraOverrides: [legalLinksProvider.overrideWithValue(LegalLinks.none)]),
        );
        await tester.pumpAndSettle();
        final AppLocalizations l10n = AppLocalizations.of(tester.element(find.byType(AboutScreen)));
        expect(find.byKey(const Key('about.support')), findsNothing);
        await tester.tap(find.byKey(const Key('about.terms')));
        await tester.pumpAndSettle();
        expect(find.text(l10n.termsTermsText), findsOneWidget);
        expect(find.byKey(const Key('about.documentPage')), findsNothing);
      });

      testWidgets('[$lang] a link that cannot open is copied instead', (WidgetTester tester) async {
        final List<MethodCall> clipboard = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add(call);
          }
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        await tester.pumpWidget(
          buildTestApp(
            const AboutScreen(),
            locale: locale,
            extraOverrides: [
              legalLinksProvider.overrideWithValue(configured),
              linkOpenerProvider.overrideWithValue((Uri uri) async => false),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('about.support')));
        await tester.pumpAndSettle();
        expect((clipboard.single.arguments as Map<Object?, Object?>)['text'], 'help@schoolcarpool.org');
        expect(find.byType(SnackBar), findsOneWidget);
      });

      testWidgets('[$lang] new rows fit one line at 320 dp', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          buildTestApp(const AboutScreen(), locale: locale, extraOverrides: [legalLinksProvider.overrideWithValue(configured)]),
        );
        await tester.pumpAndSettle();
        for (final String key in <String>['about.privacy', 'about.terms', 'about.conduct', 'about.support']) {
          expectOneLine(find.descendant(of: find.byKey(Key(key)), matching: find.byType(OneLineText)), key);
        }
      });
    }
  });

  group('Terms: the draft note is for testers only', () {
    Future<void> openPrivacy(WidgetTester tester) async {
      await tester.pumpAndSettle();
      final AppLocalizations l10n = AppLocalizations.of(tester.element(find.byType(TermsScreen)));
      await tester.tap(find.descendant(of: find.byKey(const Key('terms.privacy')), matching: find.text(l10n.termsRead)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.termsPrivacyText), findsOneWidget);
    }

    testWidgets('prod shows the document without a draft note', (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(const TermsScreen(), config: testProdConfig));
      await openPrivacy(tester);
      expect(find.byKey(const Key('terms.draftNotice')), findsNothing);
    });

    testWidgets('staging still shows it', (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(const TermsScreen(), config: testStagingConfig));
      await openPrivacy(tester);
      expect(find.byKey(const Key('terms.draftNotice')), findsOneWidget);
    });
  });
}
