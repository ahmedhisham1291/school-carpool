import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/l10n/l10n.dart';

final FutureProvider<List<ReportItem>> adminReportsProvider = FutureProvider<List<ReportItem>>(
  (Ref ref) => ref.watch(adminApiProvider).reports(),
);

/// Reports queue (F13, F14): open reports, newest first. The list only;
/// handling a report comes with chat (Prompt 9). Target response time is
/// 24 hours (spec section 6), so the age of each report is shown.
///
/// States: loading (skeleton), empty (no open reports), error and offline
/// (retry).
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void refresh() => ref.invalidate(adminReportsProvider);
    return AdminPage(
      title: l10n.adminReportsTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: AdminAsyncView<List<ReportItem>>(
        value: ref.watch(adminReportsProvider),
        onRetry: refresh,
        isEmpty: (List<ReportItem> r) => r.isEmpty,
        empty: EmptyStateView(
          icon: Icons.outlined_flag,
          title: l10n.adminReportsEmptyTitle,
          body: l10n.adminReportsEmptyBody,
        ),
        builder: (List<ReportItem> reports) => ListView.builder(
          itemCount: reports.length,
          itemBuilder: (BuildContext context, int i) {
            final ReportItem r = reports[i];
            final DateTime? at = r.createdAt;
            final bool overdue = at != null && DateTime.now().difference(at) > const Duration(hours: 24);
            return AppListRow(
              key: Key('reports.${r.id}'),
              title: reportReasonLabel(l10n, r.reason),
              subtitle: '${reportTargetLabel(l10n, r.targetType)} · ${adminDateTime(context, at)}',
              leadingIcon: Icons.flag_outlined,
              trailing: overdue ? AppStatusBadge(label: l10n.adminOverdue, tone: AppBadgeTone.warning) : null,
            );
          },
        ),
      ),
    );
  }
}
