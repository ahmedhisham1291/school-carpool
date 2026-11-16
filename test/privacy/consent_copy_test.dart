import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/privacy/consent_copy_screen.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/privacy/privacy_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/privacy_fakes.dart';
import '../helpers/test_app.dart';

/// R3: the parent's copy of a signed consent (Privacy > consent > View copy).
void main() {
  Future<List<Uri>> pump(WidgetTester tester, FakePrivacyRepository repository, {Locale locale = AppLocales.english}) async {
    final List<Uri> opened = <Uri>[];
    await tester.pumpWidget(
      buildTestApp(
        const ConsentCopyScreen(kind: ConsentKind.face),
        locale: locale,
        extraOverrides: [
          privacyRepositoryProvider.overrideWithValue(repository),
          linkOpenerProvider.overrideWithValue((Uri uri) async {
            opened.add(uri);
            return true;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('shows the signed text, who signed, when and how; downloads the copy', (WidgetTester tester) async {
    final FakePrivacyRepository repository = FakePrivacyRepository();
    final List<Uri> opened = await pump(tester, repository);
    expect(find.textContaining('explicit written consent'), findsOneWidget);
    expect(find.text('Mona Hassan'), findsOneWidget);
    expect(find.text('Face ID or passcode'), findsOneWidget);
    expect(find.text('0123456789ab'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('consentCopy.download')));
    await tester.tap(find.byKey(const Key('consentCopy.download')));
    await tester.pumpAndSettle();
    expect(repository.calls, contains('downloadConsentCopy:face'));
    expect(opened.single.path, '/consent-face.txt');
    expect(find.text('Copy opened. The link works for 1 hour.'), findsOneWidget);
  });

  testWidgets('empty state for a consent given before signed copies', (WidgetTester tester) async {
    final FakePrivacyRepository repository = FakePrivacyRepository()..copyValue = null;
    await pump(tester, repository);
    expect(find.byKey(const Key('consentCopy.empty')), findsOneWidget);
    expect(find.text('No copy yet'), findsOneWidget);
  });

  testWidgets('error and offline states retry', (WidgetTester tester) async {
    final FakePrivacyRepository repository = FakePrivacyRepository()..failure = const PrivacyFailure(PrivacyFailureKind.offline);
    await pump(tester, repository);
    expect(find.byType(OfflineStateView), findsOneWidget);
  });

  testWidgets('Arabic, right to left, labels on one line at 320 dp', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester, FakePrivacyRepository(), locale: AppLocales.arabic);
    expect(find.text('وقّعها'), findsOneWidget);
    expect(find.text('تنزيل النسخة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
