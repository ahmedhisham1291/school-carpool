// Admin panel > Incidents (breach register, Law 151 of 2020 Art. 7) with a
// fake API. Written, not run here (no Flutter SDK in the build workspace).
// CI runs it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_incidents.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/shell/admin_shell.dart';

import '../helpers/admin_fakes.dart';

class FakeIncidentsApi implements AdminIncidentsApi {
  final List<String> calls = <String>[];
  final List<AdminIncident> items = <AdminIncident>[];
  IncidentDraft? lastDraft;

  AdminIncident _make(String id, {String status = 'open', bool sensitive = false, DateTime? pdpcAt}) {
    final DateTime aware = DateTime.utc(2026, 11, 16, 8);
    return AdminIncident(
      id: id,
      status: status,
      awareAt: aware,
      kind: IncidentKind.unauthorisedAccess,
      approxPeople: 40,
      sensitive: sensitive,
      immediate: sensitive,
      summary: 'Test: leaked staging key (fake)',
      pdpcDueAt: sensitive ? aware : aware.add(const Duration(hours: 72)),
      subjectsDueAt: aware.add(const Duration(days: 6)),
      pdpcState: pdpcAt != null ? DeadlineState.done : (sensitive ? DeadlineState.now : DeadlineState.onTime),
      subjectsState: DeadlineState.onTime,
      pdpcNotifiedAt: pdpcAt,
    );
  }

  @override
  Future<List<AdminIncident>> list() async {
    calls.add('list');
    return List<AdminIncident>.of(items);
  }

  @override
  Future<AdminIncident> report(IncidentDraft draft) async {
    calls.add('report');
    lastDraft = draft;
    final AdminIncident i = _make('b${items.length + 1}', sensitive: draft.sensitive);
    items.insert(0, i);
    return i;
  }

  @override
  Future<AdminIncident> update(String id, IncidentStep step, {String reference = '', String text = ''}) async {
    calls.add('update:$id:${step.name}');
    final int at = items.indexWhere((AdminIncident i) => i.id == id);
    if (step == IncidentStep.pdpcNotified) {
      items[at] = _make(id, pdpcAt: DateTime.utc(2026, 11, 16, 12));
    }
    return items[at];
  }
}

void main() {
  const AdminSessionState reviewer = AdminSignedIn(testReviewer);

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  test('every admin has the Incidents section', () {
    expect(adminSections(superAdmin: false).map((AdminSection s) => s.path), contains(AdminRoutes.incidents));
  });

  testWidgets('empty register, then a report with children data starts an immediate clock', (WidgetTester tester) async {
    final FakeIncidentsApi api = FakeIncidentsApi();
    await pumpAdminPanel(
      tester,
      session: reviewer,
      location: AdminRoutes.incidents,
      locale: 'en',
      size: const Size(1280, 2400),
      extraOverrides: <Override>[adminIncidentsApiProvider.overrideWithValue(api)],
    );
    await settle(tester);
    expect(find.byKey(const Key('incidents.empty')), findsOneWidget);
    expect(find.byKey(const Key('incidents.rule')), findsOneWidget);

    await tester.tap(find.byKey(const Key('incidents.report')));
    await settle(tester);
    // Nothing is sent until the form is complete.
    await tester.ensureVisible(find.byKey(const Key('incidentForm.send')));
    await tester.tap(find.byKey(const Key('incidentForm.send')));
    await settle(tester);
    expect(find.byKey(const Key('incidentForm.error')), findsOneWidget);
    expect(api.calls.where((String c) => c == 'report'), isEmpty);

    await tester.ensureVisible(find.byKey(const Key('incidentForm.cat.children')));
    await tester.tap(find.byKey(const Key('incidentForm.cat.children')));
    await settle(tester);
    expect(find.byKey(const Key('incidentForm.sensitive')), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const Key('incidentForm.people')), matching: find.byType(EditableText)), '40');
    await tester.enterText(find.descendant(of: find.byKey(const Key('incidentForm.records')), matching: find.byType(EditableText)), '120');
    await tester.enterText(find.descendant(of: find.byKey(const Key('incidentForm.summary')), matching: find.byType(EditableText)), 'Leaked key');
    await tester.ensureVisible(find.byKey(const Key('incidentForm.send')));
    await tester.tap(find.byKey(const Key('incidentForm.send')));
    await settle(tester);
    expect(api.calls, contains('report'));
    expect(api.lastDraft?.sensitive, isTrue);
    expect(api.lastDraft?.approxPeople, 40);
    expect(find.byKey(const Key('incident.b1')), findsOneWidget);
    expect(find.text('Immediately'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
  });

  testWidgets('recording "Centre told" asks first, then shows Done and the next step', (WidgetTester tester) async {
    final FakeIncidentsApi api = FakeIncidentsApi();
    await api.report(
      IncidentDraft(
        awareAt: DateTime.utc(2026, 11, 16, 8),
        kind: IncidentKind.loss,
        categories: <IncidentCategory>{IncidentCategory.contact},
        source: IncidentSource.us,
        approxPeople: 3,
        approxRecords: 3,
        nationalSecurity: false,
        summary: 'x',
      ),
    );
    await pumpAdminPanel(
      tester,
      session: reviewer,
      location: AdminRoutes.incidents,
      locale: 'en',
      size: const Size(1280, 2400),
      extraOverrides: <Override>[adminIncidentsApiProvider.overrideWithValue(api)],
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('incident.b1.pdpc.done')));
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Record')));
    await settle(tester);
    expect(api.calls, contains('update:b1:pdpcNotified'));
    expect(find.byKey(const Key('incident.b1.parents.done')), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });
}
