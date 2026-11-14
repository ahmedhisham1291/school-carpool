import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/reports_screen.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _reportProvider = FutureProvider.autoDispose.family<ReportDetail, String>(
  (Ref ref, String id) => ref.watch(adminApiProvider).report(id),
);

/// One chat report (Prompt 9: F13, F14). Shows the reported message with
/// the little context the report kept (a few messages around it, first
/// names and parent IDs, text only: photos are never copied). Admins never
/// browse a chat. Actions, each after a confirmation: remove the message,
/// remove the reported parent from that chat, close with an outcome, lift
/// a driving pause; suspend or ban on the parent's page.
///
/// States: loading (skeleton), error, offline and not found (retry),
/// sending (button spinner), closed (actions hidden, outcome shown).
class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({required this.reportId, super.key});

  final String reportId;

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  bool _busy = false;
  AdminFailure? _failure;

  void _reload() => ref.invalidate(_reportProvider(widget.reportId));

  Future<void> _act({required String title, required String body, required String confirm, required Future<ReportDetail> Function(AdminApi api) action}) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(context: context, title: title, body: body, confirmLabel: confirm, destructive: true);
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await action(ref.read(adminApiProvider));
      showAppSnackBarOn(messenger, l10n.adminReportDone);
      ref.invalidate(adminReportsProvider);
      _reload();
    } on AdminFailure catch (f) {
      if (mounted) {
        setState(() => _failure = f);
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
    final String id = widget.reportId;
    return AdminPage(
      title: l10n.adminReportTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: _reload)],
      body: AdminAsyncView<ReportDetail>(
        value: ref.watch(_reportProvider(id)),
        onRetry: _reload,
        builder: (ReportDetail r) {
          final AdminFailure? failure = _failure;
          final String? subject = r.subjectUid;
          return ListView(
            padding: AppSpacing.screenPadding,
            children: <Widget>[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(child: OneLineText(reportReasonLabel(l10n, r.reason), style: context.text.titleLarge)),
                        if (r.urgent) AppStatusBadge(key: const Key('report.urgent'), label: l10n.adminReportUrgent, tone: AppBadgeTone.error),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AdminFact(label: l10n.adminReportTarget, value: reportTargetLabel(l10n, r.targetType)),
                    AdminFact(label: l10n.adminReportChat, value: reportKindLabel(l10n, r.kind)),
                    AdminFact(label: l10n.adminReportWhen, value: adminDateTime(context, r.createdAt)),
                    if (r.note.isNotEmpty) AdminFact(label: l10n.adminReportNote, value: r.note),
                    if (r.pausedDriving) AdminFact(label: l10n.adminReportDriving, value: l10n.adminReportDrivingPaused),
                    if (!r.open) AdminFact(label: l10n.adminReportOutcome, value: r.outcome ?? '-'),
                  ],
                ),
              ),
              if (r.context.isNotEmpty) ...<Widget>[
                AppSectionHeader(l10n.adminReportContext),
                for (final ReportContextMessage m in r.context)
                  AppChatBubble(
                    key: Key('report.msg.${m.id}'),
                    mine: m.reported,
                    author: '${m.authorName} · ${ltrIsolate(m.authorParentId)}',
                    time: adminDateTime(context, m.createdAt),
                    child: Text(switch (m.attachment) {
                      'image' => l10n.adminReportPhotoHidden,
                      'location' => l10n.chatLocation,
                      _ => m.text,
                    }),
                  ),
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: AppSpacing.s8),
                  child: Text(l10n.adminReportContextNote, style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant)),
                ),
              ],
              if (failure != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(message: failure.message(l10n), tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error),
              ],
              const SizedBox(height: AppSpacing.s24),
              Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s8,
                children: <Widget>[
                  if (r.open && r.targetType == 'message')
                    AppButton(
                      key: const Key('report.removeMessage'),
                      label: l10n.adminReportRemoveMessage,
                      variant: AppButtonVariant.secondary,
                      loading: _busy,
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _act(
                                title: l10n.adminReportRemoveMessageTitle,
                                body: l10n.adminReportRemoveMessageBody,
                                confirm: l10n.adminReportRemoveMessage,
                                action: (AdminApi api) => api.removeReportedMessage(id),
                              ),
                            ),
                    ),
                  if (r.open && subject != null)
                    AppButton(
                      key: const Key('report.removeMember'),
                      label: l10n.adminReportRemoveMember,
                      variant: AppButtonVariant.secondary,
                      loading: _busy,
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _act(
                                title: l10n.adminReportRemoveMemberTitle,
                                body: l10n.adminReportRemoveMemberBody,
                                confirm: l10n.adminReportRemoveMember,
                                action: (AdminApi api) => api.removeReportedMember(id),
                              ),
                            ),
                    ),
                  if (r.open)
                    for (final ReportOutcome o in ReportOutcome.values)
                      AppButton(
                        key: Key('report.close.${o.name}'),
                        label: o == ReportOutcome.noAction ? l10n.adminReportCloseNoAction : l10n.adminReportCloseWarned,
                        variant: AppButtonVariant.tertiary,
                        loading: _busy,
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _act(
                                  title: l10n.adminReportCloseTitle,
                                  body: l10n.adminReportCloseBody,
                                  confirm: l10n.adminReportClose,
                                  action: (AdminApi api) => api.resolveReport(id, o),
                                ),
                              ),
                      ),
                  if (r.pausedDriving)
                    AppButton(
                      key: const Key('report.liftPause'),
                      label: l10n.adminReportLiftPause,
                      variant: AppButtonVariant.secondary,
                      loading: _busy,
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _act(
                                title: l10n.adminReportLiftPauseTitle,
                                body: l10n.adminReportLiftPauseBody,
                                confirm: l10n.adminReportLiftPause,
                                action: (AdminApi api) => api.liftDrivingPause(id),
                              ),
                            ),
                    ),
                  if (subject != null)
                    AppButton(
                      key: const Key('report.openUser'),
                      label: l10n.adminReportOpenParent,
                      variant: AppButtonVariant.tertiary,
                      onPressed: () => context.go('${AdminRoutes.users}/$subject'),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
