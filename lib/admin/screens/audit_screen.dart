import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Audit log (F14): every admin action and every view of a person's data,
/// newest first, written only by Cloud Functions. Read only: there is no
/// edit or delete anywhere (the rules refuse it too). IP addresses are
/// shown to super admins only.
///
/// States: loading (skeleton), empty, error and offline (retry), loading
/// more (button spinner).
class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  AsyncValue<List<AuditEntry>> _entries = const AsyncLoading<List<AuditEntry>>();
  String? _next;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _entries = const AsyncLoading<List<AuditEntry>>();
      }
    });
    try {
      final AdminPage<AuditEntry> page = await ref.read(adminApiProvider).audit(afterId: more ? _next : null);
      if (mounted) {
        setState(() {
          final List<AuditEntry> before = more ? (_entries.value ?? const <AuditEntry>[]) : const <AuditEntry>[];
          _entries = AsyncData<List<AuditEntry>>(<AuditEntry>[...before, ...page.items]);
          _next = page.nextAfterId;
        });
      }
    } on AdminFailure catch (failure, stack) {
      if (mounted) {
        setState(() => _entries = AsyncError<List<AuditEntry>>(failure, stack));
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AdminPage(
      title: l10n.adminAuditTitle,
      actions: <Widget>[
        IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: () => unawaited(_load())),
      ],
      body: AdminAsyncView<List<AuditEntry>>(
        value: _entries,
        onRetry: () => unawaited(_load()),
        isEmpty: (List<AuditEntry> e) => e.isEmpty,
        empty: EmptyStateView(icon: Icons.history, title: l10n.adminAuditEmptyTitle, body: l10n.adminAuditEmptyBody),
        builder: (List<AuditEntry> entries) => ListView.builder(
          itemCount: entries.length + (_next == null ? 0 : 1),
          itemBuilder: (BuildContext context, int i) {
            if (i == entries.length) {
              return Padding(
                padding: AppSpacing.screenPadding,
                child: AppButton(
                  label: l10n.adminLoadMore,
                  variant: AppButtonVariant.tertiary,
                  loading: _loadingMore,
                  onPressed: () => unawaited(_load(more: true)),
                ),
              );
            }
            final AuditEntry e = entries[i];
            return AppListRow(
              key: Key('audit.${e.id}'),
              title: auditActionLabel(l10n, e.action),
              subtitle: <String>[
                e.actorName ?? (e.actorUid.startsWith('bootstrap') || e.actorUid.startsWith('review') ? l10n.adminScript : e.actorUid),
                adminDateTime(context, e.time),
                ltrIsolate(e.target),
                if (e.ip != null) ltrIsolate(e.ip!),
              ].join(' · '),
              leadingIcon: Icons.history,
            );
          },
        ),
      ),
    );
  }
}
