// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI: `flutter test`.
//
// The one-line rule (CLAUDE.md DESIGN, docs/DESIGN.md) for the admin web
// panel (F14): rail labels, app bar titles, buttons and list titles fit
// on one line in Arabic and English at 1024 px (a small laptop) at normal
// and 200 percent text, and the sign-in card also on a 320 dp phone.

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/design/components/components.dart';

import '../helpers/admin_fakes.dart';
import '../helpers/fonts.dart';
import '../helpers/one_line.dart';

List<RenderParagraph> _paragraphs(Finder finder) => paragraphsIn(finder);

/// Fails if any text under [finder] wraps onto a second line, or is cut off
/// with an ellipsis when [allowEllipsis] is false (message with widths).
void _expectOneLine(Finder finder, String where, {bool allowEllipsis = false}) =>
    expectOneLine(finder, where, allowEllipsis: allowEllipsis);

/// Fails if text under [finder] is drawn smaller than [minScale] of its size.
void _expectNotShrunk(Finder finder, double minScale, String where) {
  for (final RenderParagraph paragraph in _paragraphs(finder)) {
    final Rect drawn = MatrixUtils.transformRect(paragraph.getTransformTo(null), Offset.zero & paragraph.size);
    final double scale = drawn.width / paragraph.size.width;
    expect(
      scale,
      greaterThanOrEqualTo(minScale),
      reason: '"${paragraph.text.toPlainText()}" is shrunk to $scale; shorten it ($where)',
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadAppFonts);

  const AdminSessionState reviewer = AdminSignedIn(testReviewer);
  const AdminSessionState superAdmin = AdminSignedIn(testSuperAdmin);
  final Map<String, (String, AdminSessionState)> screens = <String, (String, AdminSessionState)>{
    'queue': (AdminRoutes.queue, reviewer),
    'case': ('/queue/case1', reviewer),
    'users': (AdminRoutes.users, reviewer),
    'user': ('/users/parent1', reviewer),
    'schools': (AdminRoutes.schools, reviewer),
    'new school': (AdminRoutes.newSchool, reviewer),
    'other school': ('/other-schools/p1', reviewer),
    'reports': (AdminRoutes.reports, reviewer),
    'report': ('/reports/r1', reviewer),
    'audit': (AdminRoutes.audit, superAdmin),
    'admins': (AdminRoutes.admins, superAdmin),
  };

  for (final String lang in <String>['ar', 'en']) {
    for (final double textScale in <double>[1, 2]) {
      for (final MapEntry<String, (String, AdminSessionState)> screen in screens.entries) {
        testWidgets('[$lang] ${screen.key} fits one line at 1024 px, text x$textScale', (WidgetTester tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpAdminPanel(
            tester,
            session: screen.value.$2,
            location: screen.value.$1,
            locale: lang,
            size: Size(1024, textScale == 1 ? 900 : 1800),
          );
          await _settle(tester);

          _expectOneLine(find.byType(NavigationRail), 'rail labels');
          _expectOneLine(find.byType(AppBar), 'app bar title');
          _expectNotShrunk(find.byType(AppBar), textScale == 1 ? 0.95 : 0.75, 'app bar title');
          final Finder buttons = find.byType(AppButton);
          if (buttons.evaluate().isNotEmpty) {
            _expectOneLine(buttons, 'buttons');
            _expectNotShrunk(buttons, textScale == 1 ? 0.95 : 0.75, 'buttons');
          }
          // List titles may fall back to an ellipsis for long data (names),
          // never wrap.
          final Finder rows = find.descendant(of: find.byType(AppListRow), matching: find.byType(OneLineText));
          if (rows.evaluate().isNotEmpty) {
            _expectOneLine(rows, 'list row titles', allowEllipsis: true);
          }
        });
      }
    }

    for (final double textScale in <double>[1, 2]) {
      testWidgets('[$lang] sign-in fits one line at 320 dp, text x$textScale', (WidgetTester tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpAdminPanel(
          tester,
          session: const AdminSignedOut(),
          location: AdminRoutes.signIn,
          locale: lang,
          size: const Size(320, 1200),
        );
        await _settle(tester);
        _expectOneLine(find.byType(AppButton), 'sign-in button');
        _expectNotShrunk(find.byType(AppButton), textScale == 1 ? 0.95 : 0.75, 'sign-in button');
        _expectOneLine(
          find.descendant(of: find.byType(AppTextField), matching: find.byType(OneLineText)),
          'field labels',
        );
      });
    }
  }
}
