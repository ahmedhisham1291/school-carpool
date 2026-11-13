import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Cases waiting for review, oldest first (listVerificationQueue).
final FutureProvider<List<QueueCase>> adminQueueProvider = FutureProvider<List<QueueCase>>(
  (Ref ref) => ref.watch(adminApiProvider).queue(),
);

/// Verification queue (F2 review, F14). One row per case: kind (new
/// account or update), when it was sent, what it holds, and the automated
/// check's advice. Tap to open the documents.
///
/// States: loading (skeleton rows), empty (nothing to review), error and
/// offline (retry).
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void refresh() => ref.invalidate(adminQueueProvider);
    return AdminPage(
      title: l10n.adminQueueTitle,
      actions: <Widget>[
        IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh),
      ],
      body: AdminAsyncView<List<QueueCase>>(
        value: ref.watch(adminQueueProvider),
        onRetry: refresh,
        isEmpty: (List<QueueCase> cases) => cases.isEmpty,
        empty: EmptyStateView(
          icon: Icons.task_alt_outlined,
          title: l10n.adminQueueEmptyTitle,
          body: l10n.adminQueueEmptyBody,
        ),
        builder: (List<QueueCase> cases) => ListView.builder(
          itemCount: cases.length,
          itemBuilder: (BuildContext context, int i) {
            final QueueCase c = cases[i];
            final List<String> parts = <String>[
              adminDateTime(context, c.submittedAt),
              if (c.children > 0) l10n.adminChildrenCount(c.children),
              if (c.driver) l10n.adminHasCar,
            ];
            return AppListRow(
              key: Key('queue.${c.caseId}'),
              title: c.identity ? l10n.adminCaseNew : l10n.adminCaseUpdate,
              subtitle: parts.join(' · '),
              leadingIcon: c.identity ? Icons.badge_outlined : Icons.edit_note_outlined,
              trailing: c.identity ? AppStatusBadge(label: kycLabel(l10n, c.kycResult), tone: kycTone(c.kycResult)) : null,
              onTap: () => context.go(AdminRoutes.caseDetail(c.caseId)),
            );
          },
        ),
      ),
    );
  }
}
