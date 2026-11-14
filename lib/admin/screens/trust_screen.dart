import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_trust.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// No automatic retry (Riverpod 3): the page shows its own Retry.
Duration? _noRetry(int retryCount, Object error) => null;

final _queueProvider = FutureProvider.autoDispose<TrustQueue>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminTrustApiProvider).queue(),
);

String _outcomeLabel(AppLocalizations l10n, FlagOutcome o) => switch (o) {
  FlagOutcome.noIssue => l10n.adminTrustOutcomeNoIssue,
  FlagOutcome.contacted => l10n.adminTrustOutcomeContacted,
  FlagOutcome.escalated => l10n.adminTrustOutcomeEscalated,
};

String _tagsLabel(AppLocalizations l10n, List<String> tags) => <String>[
  for (final String t in tags)
    for (final RatingTag r in RatingTag.values)
      if (r.wire == t) ratingTagLabel(l10n, r),
].join(l10n.listSeparator);

/// Trust (F14, F17): guardian links waiting for an admin (approve or
/// reject, asks first) and rating flags (low stars or unsafe driving;
/// close with an outcome, or open the rated parent to act on the account,
/// for example suspend: their runs then open for the group). Every decision
/// is in the audit log.
///
/// States: loading (skeleton), empty (a quiet line per section), error and
/// offline (retry).
class AdminTrustScreen extends ConsumerWidget {
  const AdminTrustScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void refresh() => ref.invalidate(_queueProvider);
    return AdminPage(
      title: l10n.adminTrustTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: AdminAsyncView<TrustQueue>(
        value: ref.watch(_queueProvider),
        onRetry: refresh,
        builder: (TrustQueue q) => ListView(
          key: const Key('adminTrust.list'),
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            AppSectionHeader(l10n.adminTrustLinks),
            if (q.links.isEmpty)
              AppInlineMessage(key: const Key('adminTrust.noLinks'), message: l10n.adminTrustNoLinks)
            else
              for (final ReviewLink link in q.links) _LinkRow(link: link, onDone: refresh),
            AppSectionHeader(l10n.adminTrustFlags),
            if (q.flags.isEmpty)
              AppInlineMessage(key: const Key('adminTrust.noFlags'), message: l10n.adminTrustNoFlags)
            else
              for (final RatingFlagItem flag in q.flags) _FlagRow(flag: flag, onDone: refresh),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends ConsumerWidget {
  const _LinkRow({required this.link, required this.onDone});

  final ReviewLink link;
  final VoidCallback onDone;

  Future<void> _decide(BuildContext context, WidgetRef ref, bool approve) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: approve ? l10n.adminTrustApproveTitle : l10n.adminTrustRejectTitle,
      body: l10n.adminTrustLinkBody(link.guardianFirstName, link.childFirstName, link.ownerFirstName),
      confirmLabel: approve ? l10n.adminTrustApprove : l10n.adminTrustReject,
      destructive: !approve,
    );
    if (!ok) {
      return;
    }
    try {
      await ref.read(adminTrustApiProvider).decideLink(linkId: link.id, approve: approve);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      onDone();
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    return AppListRow(
      key: Key('adminTrust.link.${link.id}'),
      inset: false,
      title: l10n.adminTrustLinkTitle(link.guardianFirstName, link.childFirstName),
      subtitle: <String>[
        relationLabel(l10n, Relation.fromName(link.relation)),
        l10n.adminTrustLinkOwner(link.ownerFirstName),
        adminDateTime(context, link.createdAt),
      ].join(' · '),
      leadingIcon: Icons.link_rounded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppButton(
            key: Key('adminTrust.reject.${link.id}'),
            label: l10n.adminTrustReject,
            variant: AppButtonVariant.tertiary,
            onPressed: () => unawaited(_decide(context, ref, false)),
          ),
          const SizedBox(width: AppSpacing.s8),
          AppButton(
            key: Key('adminTrust.approve.${link.id}'),
            label: l10n.adminTrustApprove,
            variant: AppButtonVariant.secondary,
            onPressed: () => unawaited(_decide(context, ref, true)),
          ),
        ],
      ),
    );
  }
}

class _FlagRow extends ConsumerWidget {
  const _FlagRow({required this.flag, required this.onDone});

  final RatingFlagItem flag;
  final VoidCallback onDone;

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final FlagOutcome? outcome = await showAppSheet<FlagOutcome>(
      context: context,
      title: l10n.adminTrustResolve,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final FlagOutcome o in FlagOutcome.values)
            Builder(
              builder: (BuildContext sheet) => AppListRow(
                key: Key('adminTrust.outcome.${o.name}'),
                inset: false,
                title: _outcomeLabel(l10n, o),
                onTap: () => Navigator.of(sheet).pop(o),
              ),
            ),
        ],
      ),
    );
    if (outcome == null) {
      return;
    }
    try {
      await ref.read(adminTrustApiProvider).resolveFlag(flagId: flag.id, outcome: outcome);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      onDone();
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String tags = _tagsLabel(l10n, flag.tags);
    return AppListRow(
      key: Key('adminTrust.flag.${flag.id}'),
      inset: false,
      title: l10n.adminTrustFlagTitle(flag.rateeFirstName, flag.stars),
      subtitle: <String>[
        l10n.adminTrustFlagBy(flag.raterFirstName),
        if (tags.isNotEmpty) tags,
        adminDateTime(context, flag.createdAt),
      ].join(' · '),
      leadingIcon: flag.tags.contains(RatingTag.unsafeDriving.wire) ? Icons.warning_amber_rounded : Icons.star_half_rounded,
      onTap: () => context.go(AdminRoutes.user(flag.rateeUid)),
      trailing: AppButton(
        key: Key('adminTrust.resolve.${flag.id}'),
        label: l10n.adminTrustResolve,
        variant: AppButtonVariant.tertiary,
        onPressed: () => unawaited(_resolve(context, ref)),
      ),
    );
  }
}
