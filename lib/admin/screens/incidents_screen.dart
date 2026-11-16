import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_incidents.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

Duration? _noRetry(int retryCount, Object error) => null;

final FutureProvider<List<AdminIncident>> adminIncidentsProvider = FutureProvider.autoDispose<List<AdminIncident>>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminIncidentsApiProvider).list(),
);

/// How long ago we became aware, offered in the report form (the clock
/// starts then, not when the form is sent).
const List<int> kAwareHoursAgo = <int>[0, 1, 3, 6, 12, 24, 48, 72];

String incidentKindLabel(AppLocalizations l10n, IncidentKind k) => switch (k) {
  IncidentKind.unauthorisedAccess => l10n.incidentKindAccess,
  IncidentKind.disclosure => l10n.incidentKindDisclosure,
  IncidentKind.loss => l10n.incidentKindLoss,
  IncidentKind.alteration => l10n.incidentKindAlteration,
  IncidentKind.unavailable => l10n.incidentKindUnavailable,
  IncidentKind.other => l10n.incidentKindOther,
};

String incidentCategoryLabel(AppLocalizations l10n, IncidentCategory c) => switch (c) {
  IncidentCategory.account => l10n.incidentCatAccount,
  IncidentCategory.contact => l10n.incidentCatContact,
  IncidentCategory.idImages => l10n.incidentCatIdImages,
  IncidentCategory.biometric => l10n.incidentCatBiometric,
  IncidentCategory.children => l10n.incidentCatChildren,
  IncidentCategory.location => l10n.incidentCatLocation,
  IncidentCategory.home => l10n.incidentCatHome,
  IncidentCategory.chat => l10n.incidentCatChat,
  IncidentCategory.devices => l10n.incidentCatDevices,
  IncidentCategory.other => l10n.incidentCatOther,
};

String incidentSourceLabel(AppLocalizations l10n, IncidentSource s) => switch (s) {
  IncidentSource.us => l10n.incidentSourceUs,
  IncidentSource.other => l10n.incidentSourceOther,
  // Company names are not translated.
  IncidentSource.google => 'Google',
  IncidentSource.meta => 'Meta (WhatsApp)',
  IncidentSource.algolia => 'Algolia',
  IncidentSource.sentry => 'Sentry',
  IncidentSource.valify => 'Valify',
  IncidentSource.email => l10n.incidentSourceEmail,
  IncidentSource.stream => 'Stream',
};

(String, AppBadgeTone) deadlineBadge(AppLocalizations l10n, DeadlineState s) => switch (s) {
  DeadlineState.done => (l10n.incidentStateDone, AppBadgeTone.success),
  DeadlineState.now => (l10n.incidentStateNow, AppBadgeTone.error),
  DeadlineState.onTime => (l10n.incidentStateOnTime, AppBadgeTone.neutral),
  DeadlineState.dueSoon => (l10n.incidentStateDueSoon, AppBadgeTone.warning),
  DeadlineState.overdue => (l10n.incidentStateOverdue, AppBadgeTone.error),
};

/// Admin panel > Incidents: the breach register. "Report incident" starts
/// the 72-hour clock and the list shows both deadlines (PDPC, parents)
/// with their state; each step (contained, PDPC told, parents told,
/// closed) is recorded and audit-logged by the server.
///
/// States: loading (skeleton), empty ("No incidents"), error and offline
/// (retry), via AdminAsyncView.
class IncidentsScreen extends ConsumerStatefulWidget {
  const IncidentsScreen({super.key});

  @override
  ConsumerState<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends ConsumerState<IncidentsScreen> {
  bool _busy = false;

  Future<void> _report() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final IncidentDraft? draft = await showAppSheet<IncidentDraft>(
      context: context,
      title: l10n.incidentReportTitle,
      body: const _ReportForm(),
    );
    if (draft == null || !mounted) {
      return;
    }
    await _run(() => ref.read(adminIncidentsApiProvider).report(draft), messenger, l10n.incidentReported);
  }

  Future<void> _step(AdminIncident incident, IncidentStep step) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: switch (step) {
        IncidentStep.pdpcNotified => l10n.incidentStepPdpc,
        IncidentStep.subjectsNotified => l10n.incidentStepParents,
        IncidentStep.closed => l10n.incidentStepClose,
        _ => l10n.incidentStepContained,
      },
      body: switch (step) {
        IncidentStep.pdpcNotified => l10n.incidentStepPdpcBody,
        IncidentStep.subjectsNotified => l10n.incidentStepParentsBody,
        IncidentStep.closed => l10n.incidentStepCloseBody,
        _ => l10n.incidentStepContainedBody,
      },
      confirmLabel: l10n.incidentConfirm,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() => ref.read(adminIncidentsApiProvider).update(incident.id, step), messenger, l10n.adminSaved);
  }

  Future<void> _run(Future<Object?> Function() body, ScaffoldMessengerState messenger, String done) async {
    setState(() => _busy = true);
    try {
      await body();
      showAppSnackBarOn(messenger, done);
      ref.invalidate(adminIncidentsProvider);
    } on AdminFailure catch (f) {
      if (mounted) {
        showAppSnackBarOn(messenger, f.message(context.l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    void refresh() => ref.invalidate(adminIncidentsProvider);
    return AdminPage(
      title: l10n.incidentsTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppInlineMessage(key: const Key('incidents.rule'), message: l10n.incidentsRule),
                const SizedBox(height: AppSpacing.s16),
                AppButton(
                  key: const Key('incidents.report'),
                  label: l10n.incidentReportButton,
                  icon: Icons.report_outlined,
                  loading: _busy,
                  onPressed: _busy ? null : () => unawaited(_report()),
                ),
              ],
            ),
          ),
          Expanded(
            child: AdminAsyncView<List<AdminIncident>>(
              value: ref.watch(adminIncidentsProvider),
              onRetry: refresh,
              isEmpty: (List<AdminIncident> list) => list.isEmpty,
              empty: EmptyStateView(key: const Key('incidents.empty'), icon: Icons.verified_user_outlined, title: l10n.incidentsEmpty),
              builder: (List<AdminIncident> list) => ListView(
                key: const Key('incidents.list'),
                padding: AppSpacing.screenPadding,
                children: <Widget>[
                  for (final AdminIncident i in list) ...<Widget>[
                    _IncidentCard(incident: i, busy: _busy, onStep: (IncidentStep s) => unawaited(_step(i, s))),
                    const SizedBox(height: AppSpacing.s16),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({required this.incident, required this.busy, required this.onStep});

  final AdminIncident incident;
  final bool busy;
  final ValueChanged<IncidentStep> onStep;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AdminIncident i = incident;
    final (String pdpcLabel, AppBadgeTone pdpcTone) = deadlineBadge(l10n, i.pdpcState);
    final (String parentsLabel, AppBadgeTone parentsTone) = deadlineBadge(l10n, i.subjectsState);
    return AppCard(
      key: Key('incident.${i.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OneLineText(incidentKindLabel(l10n, i.kind), style: context.text.titleSmall),
          Text(i.summary, style: context.text.bodyMedium),
          const SizedBox(height: AppSpacing.s8),
          AdminFact(label: l10n.incidentAwareAt, value: adminDateTime(context, i.awareAt)),
          AdminFact(label: l10n.incidentPeople, value: '${i.approxPeople}'),
          if (i.sensitive) AppInlineMessage(message: l10n.incidentSensitive, tone: AppStateTone.warning),
          const SizedBox(height: AppSpacing.s8),
          Row(
            children: <Widget>[
              Expanded(
                child: AdminFact(
                  label: l10n.incidentPdpcBy,
                  value: i.pdpcNotifiedAt != null
                      ? adminDateTime(context, i.pdpcNotifiedAt)
                      : (i.immediate
                            // R15: "immediately", with our 24-hour target for children's or biometric data.
                            ? (i.targetAt != null && i.targetAt!.isAfter(i.awareAt)
                                  ? l10n.incidentImmediatelyBy(adminDateTime(context, i.targetAt))
                                  : l10n.incidentImmediately)
                            : adminDateTime(context, i.pdpcDueAt)),
                ),
              ),
              AppStatusBadge(key: Key('incident.${i.id}.pdpc'), label: pdpcLabel, tone: pdpcTone),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: AdminFact(
                  label: l10n.incidentParentsBy,
                  value: adminDateTime(context, i.subjectsNotifiedAt ?? i.subjectsDueAt),
                ),
              ),
              AppStatusBadge(key: Key('incident.${i.id}.parents'), label: parentsLabel, tone: parentsTone),
            ],
          ),
          if (!i.closed) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            Wrap(
              spacing: AppSpacing.s8,
              runSpacing: AppSpacing.s8,
              children: <Widget>[
                AppButton(
                  key: Key('incident.${i.id}.contained'),
                  label: l10n.incidentStepContained,
                  variant: AppButtonVariant.tertiary,
                  onPressed: busy ? null : () => onStep(IncidentStep.contained),
                ),
                if (i.pdpcNotifiedAt == null)
                  AppButton(
                    key: Key('incident.${i.id}.pdpc.done'),
                    label: l10n.incidentStepPdpc,
                    variant: AppButtonVariant.secondary,
                    onPressed: busy ? null : () => onStep(IncidentStep.pdpcNotified),
                  )
                else if (i.subjectsNotifiedAt == null)
                  AppButton(
                    key: Key('incident.${i.id}.parents.done'),
                    label: l10n.incidentStepParents,
                    variant: AppButtonVariant.secondary,
                    onPressed: busy ? null : () => onStep(IncidentStep.subjectsNotified),
                  )
                else
                  AppButton(
                    key: Key('incident.${i.id}.close'),
                    label: l10n.incidentStepClose,
                    variant: AppButtonVariant.tertiary,
                    onPressed: busy ? null : () => onStep(IncidentStep.closed),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The report form: what, when we knew, which data, how many, where.
class _ReportForm extends StatefulWidget {
  const _ReportForm();

  @override
  State<_ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<_ReportForm> {
  IncidentKind _kind = IncidentKind.unauthorisedAccess;
  IncidentSource _source = IncidentSource.us;
  int _hoursAgo = 0;
  final Set<IncidentCategory> _categories = <IncidentCategory>{};
  bool _nationalSecurity = false;
  final TextEditingController _people = TextEditingController();
  final TextEditingController _records = TextEditingController();
  final TextEditingController _summary = TextEditingController();
  final TextEditingController _measures = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _people.dispose();
    _records.dispose();
    _summary.dispose();
    _measures.dispose();
    super.dispose();
  }

  String? _error(AppLocalizations l10n) {
    if (_categories.isEmpty) {
      return l10n.incidentErrorCategories;
    }
    if (int.tryParse(_people.text.trim()) == null || int.tryParse(_records.text.trim()) == null) {
      return l10n.incidentErrorCounts;
    }
    if (_summary.text.trim().isEmpty) {
      return l10n.incidentErrorSummary;
    }
    return null;
  }

  void _send() {
    final AppLocalizations l10n = context.l10n;
    if (_error(l10n) != null) {
      setState(() => _tried = true);
      return;
    }
    Navigator.of(context).pop(
      IncidentDraft(
        awareAt: DateTime.now().subtract(Duration(hours: _hoursAgo)),
        kind: _kind,
        categories: Set<IncidentCategory>.of(_categories),
        source: _source,
        approxPeople: int.parse(_people.text.trim()),
        approxRecords: int.parse(_records.text.trim()),
        nationalSecurity: _nationalSecurity,
        summary: _summary.text.trim(),
        measures: _measures.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String? error = _tried ? _error(l10n) : null;
    final bool sensitive = _categories.contains(IncidentCategory.children) || _categories.contains(IncidentCategory.biometric);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppInlineMessage(message: l10n.incidentNoPersonalData),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<int>(
          key: const Key('incidentForm.aware'),
          label: l10n.incidentAwareLabel,
          options: <(int, String)>[
            for (final int h in kAwareHoursAgo) (h, h == 0 ? l10n.incidentAwareNow : l10n.incidentAwareHoursAgo(h)),
          ],
          value: _hoursAgo,
          onChanged: (int h) => setState(() => _hoursAgo = h),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<IncidentKind>(
          key: const Key('incidentForm.kind'),
          label: l10n.incidentKindLabel,
          options: <(IncidentKind, String)>[for (final IncidentKind k in IncidentKind.values) (k, incidentKindLabel(l10n, k))],
          value: _kind,
          onChanged: (IncidentKind k) => setState(() => _kind = k),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSectionHeader(l10n.incidentCategoriesLabel),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final IncidentCategory c in IncidentCategory.values)
              AppChip(
                key: Key('incidentForm.cat.${c.name}'),
                label: incidentCategoryLabel(l10n, c),
                selected: _categories.contains(c),
                onSelected: (bool on) => setState(() => on ? _categories.add(c) : _categories.remove(c)),
              ),
          ],
        ),
        if (sensitive) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('incidentForm.sensitive'), message: l10n.incidentSensitive, tone: AppStateTone.warning),
        ],
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<IncidentSource>(
          key: const Key('incidentForm.source'),
          label: l10n.incidentSourceLabel,
          options: <(IncidentSource, String)>[for (final IncidentSource s in IncidentSource.values) (s, incidentSourceLabel(l10n, s))],
          value: _source,
          onChanged: (IncidentSource s) => setState(() => _source = s),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('incidentForm.people'),
          label: l10n.incidentPeople,
          controller: _people,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
          maxLength: 9,
          textDirection: TextDirection.ltr,
        ),
        const SizedBox(height: AppSpacing.s8),
        AppTextField(
          key: const Key('incidentForm.records'),
          label: l10n.incidentRecords,
          controller: _records,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
          maxLength: 9,
          textDirection: TextDirection.ltr,
        ),
        const SizedBox(height: AppSpacing.s8),
        AppTextField(key: const Key('incidentForm.summary'), label: l10n.incidentSummaryLabel, controller: _summary, maxLength: 1000),
        const SizedBox(height: AppSpacing.s8),
        AppTextField(key: const Key('incidentForm.measures'), label: l10n.incidentMeasuresLabel, controller: _measures, maxLength: 1000),
        AppCheckRow(
          key: const Key('incidentForm.nationalSecurity'),
          label: l10n.incidentNationalSecurity,
          value: _nationalSecurity,
          onChanged: (bool v) => setState(() => _nationalSecurity = v),
        ),
        if (error != null) AppInlineMessage(key: const Key('incidentForm.error'), message: error, tone: AppStateTone.error),
        const SizedBox(height: AppSpacing.s16),
        AppButton(key: const Key('incidentForm.send'), label: l10n.incidentReportSend, expand: true, onPressed: _send),
      ],
    );
  }
}
