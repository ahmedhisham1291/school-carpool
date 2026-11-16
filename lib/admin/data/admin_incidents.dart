import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';

/// Admin panel > Incidents: the personal data breach register (Law 151 of
/// 2020, Art. 7; Decree 816/2025, Art. 5; functions/src/privacy/breaches.ts;
/// docs/legal/breach-runbook.md). The PDPC is told within 72 hours of
/// awareness (at once for national security, children's or biometric data);
/// parents within 3 working days of that. Every method throws
/// [AdminFailure]; every call is audit-logged by the server.
abstract interface class AdminIncidentsApi {
  Future<List<AdminIncident>> list();
  Future<AdminIncident> report(IncidentDraft draft);
  Future<AdminIncident> update(String id, IncidentStep step, {String reference = '', String text = ''});
}

/// Same words as BREACH_KINDS, BREACH_CATEGORIES and BREACH_SOURCES on the server.
enum IncidentKind { unauthorisedAccess, disclosure, loss, alteration, unavailable, other }

enum IncidentCategory { account, contact, idImages, biometric, children, location, home, chat, devices, other }

enum IncidentSource { us, google, meta, algolia, sentry, valify, email, stream, other }

/// The steps an admin records (BREACH_ACTIONS).
enum IncidentStep { contained, pdpcNotified, subjectsNotified, note, closed }

/// Where a clock stands (DeadlineState on the server).
enum DeadlineState {
  done,
  now,
  onTime,
  dueSoon,
  overdue;

  static DeadlineState fromWire(Object? v) => values.firstWhere((DeadlineState s) => s.name == v, orElse: () => DeadlineState.overdue);
}

@immutable
class IncidentDraft {
  const IncidentDraft({
    required this.awareAt,
    required this.kind,
    required this.categories,
    required this.source,
    required this.approxPeople,
    required this.approxRecords,
    required this.nationalSecurity,
    required this.summary,
    this.measures = '',
  });

  /// When we became aware: the 72-hour clock starts here.
  final DateTime awareAt;
  final IncidentKind kind;
  final Set<IncidentCategory> categories;
  final IncidentSource source;
  final int approxPeople;
  final int approxRecords;
  final bool nationalSecurity;

  /// Admin's words; never personal data (the form says so).
  final String summary;
  final String measures;

  bool get sensitive => categories.contains(IncidentCategory.children) || categories.contains(IncidentCategory.biometric);

  Map<String, Object?> toJson() => <String, Object?>{
    'awareAtMs': awareAt.millisecondsSinceEpoch,
    'kind': kind.name,
    'categories': <String>[for (final IncidentCategory c in categories) c.name],
    'source': source.name,
    'approxPeople': approxPeople,
    'approxRecords': approxRecords,
    'nationalSecurity': nationalSecurity,
    'summary': summary,
    'measures': measures,
  };
}

@immutable
class AdminIncident {
  const AdminIncident({
    required this.id,
    required this.status,
    required this.awareAt,
    required this.kind,
    required this.approxPeople,
    required this.sensitive,
    required this.immediate,
    required this.summary,
    required this.pdpcDueAt,
    required this.subjectsDueAt,
    required this.pdpcState,
    required this.subjectsState,
    this.pdpcNotifiedAt,
    this.pdpcReference,
    this.subjectsNotifiedAt,
  });

  factory AdminIncident.fromJson(Json j) => AdminIncident(
    id: j.str('id'),
    status: j.str('status', 'open'),
    awareAt: j.time('awareAtMs') ?? DateTime.fromMillisecondsSinceEpoch(0),
    kind: IncidentKind.values.firstWhere((IncidentKind k) => k.name == j.str('kind'), orElse: () => IncidentKind.other),
    approxPeople: j.integer('approxPeople'),
    sensitive: j.flag('sensitive'),
    immediate: j.flag('immediate'),
    summary: j.str('summary'),
    pdpcDueAt: j.time('pdpcDueAtMs') ?? DateTime.fromMillisecondsSinceEpoch(0),
    subjectsDueAt: j.time('subjectsDueAtMs') ?? DateTime.fromMillisecondsSinceEpoch(0),
    pdpcState: DeadlineState.fromWire(j.str('pdpcState')),
    subjectsState: DeadlineState.fromWire(j.str('subjectsState')),
    pdpcNotifiedAt: j.time('pdpcNotifiedAtMs'),
    pdpcReference: j.strOrNull('pdpcReference'),
    subjectsNotifiedAt: j.time('subjectsNotifiedAtMs'),
  );

  final String id;

  /// open, pdpcNotified, subjectsNotified or closed.
  final String status;
  final DateTime awareAt;
  final IncidentKind kind;
  final int approxPeople;
  final bool sensitive;

  /// The PDPC must be told at once (national security, children or biometrics).
  final bool immediate;
  final String summary;
  final DateTime pdpcDueAt;
  final DateTime subjectsDueAt;
  final DeadlineState pdpcState;
  final DeadlineState subjectsState;
  final DateTime? pdpcNotifiedAt;
  final String? pdpcReference;
  final DateTime? subjectsNotifiedAt;

  bool get closed => status == 'closed';
}

class FirebaseAdminIncidentsApi implements AdminIncidentsApi {
  FirebaseAdminIncidentsApi(this._functions);

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
  Future<List<AdminIncident>> list() async => (await _call('adminListIncidents')).list('incidents').map(AdminIncident.fromJson).toList();

  @override
  Future<AdminIncident> report(IncidentDraft draft) async => AdminIncident.fromJson(await _call('adminReportIncident', draft.toJson()));

  @override
  Future<AdminIncident> update(String id, IncidentStep step, {String reference = '', String text = ''}) async => AdminIncident.fromJson(
    await _call('adminUpdateIncident', <String, Object?>{
      'id': id,
      'action': step.name,
      if (reference.isNotEmpty) 'reference': reference,
      if (text.isNotEmpty) 'text': text,
    }),
  );
}

final Provider<AdminIncidentsApi> adminIncidentsApiProvider = Provider<AdminIncidentsApi>(
  (Ref ref) => FirebaseAdminIncidentsApi(functionsClient()),
);
