import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/settle_up/settle_up_labels.dart';
import 'package:school_carpool/features/settle_up/settle_up_models.dart';
import 'package:school_carpool/features/settle_up/settle_up_repository.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Settle up (F45), from Profile and from a carpool's page. Layout, top to
/// bottom: the line "The app does not move money", my InstaPay address
/// (add or change), one primary action (New request), a card per person
/// with what I owe and what I am owed (from records that are not
/// finished), then the open records and the finished ones.
///
/// States: loading (skeleton), no records yet (a short note under "Open"),
/// not verified (empty with "Verify account"), error and offline (retry).
/// The list is live: it changes when the other parent taps "I paid".
class SettleUpScreen extends ConsumerWidget {
  const SettleUpScreen({super.key, this.carpoolId});

  /// Opened from this carpool: a new request starts with its parents.
  final String? carpoolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final Account? account = accountOf(ref.watch(sessionProvider));
    final Widget body;
    if (account != null && account.status != AccountStatus.verified) {
      body = EmptyStateView(
        key: const Key('settle.notVerified'),
        icon: Icons.verified_user_outlined,
        title: l10n.settleVerifyTitle,
        body: l10n.settleErrorNotVerified,
        actionLabel: l10n.walletVerifyAction,
        onAction: () => context.go(AuthRoutes.verifyAccount),
      );
    } else {
      final AsyncValue<List<SettleUp>> records = ref.watch(settleUpsProvider);
      void retry() => ref.invalidate(settleUpsProvider);
      body = switch (records) {
        AsyncData<List<SettleUp>>(:final List<SettleUp> value) => _SettleContent(records: value, carpoolId: carpoolId),
        AsyncError<List<SettleUp>>(:final Object error) =>
          SettleFailure.from(error).isOffline
              ? OfflineStateView(onRetry: retry)
              : ErrorStateView(key: const Key('settle.error'), onRetry: retry),
        _ => const _SettleSkeleton(),
      };
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.settleTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _SettleSkeleton extends StatelessWidget {
  const _SettleSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(padding: AppSpacing.screenPadding, child: SkeletonCard()),
        SkeletonListRow(),
        SkeletonListRow(),
        SkeletonListRow(),
      ],
    ),
  );
}

class _SettleContent extends ConsumerWidget {
  const _SettleContent({required this.records, this.carpoolId});

  final List<SettleUp> records;
  final String? carpoolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String uid = ref.watch(settleUidProvider);
    final AsyncValue<SettleProfile> profile = ref.watch(settleProfileProvider);
    final String? address = profile.value?.address;
    final List<SettleUp> open = <SettleUp>[
      for (final SettleUp r in records)
        if (!r.status.finished && r.roleOf(uid) != null) r,
    ];
    final List<SettleUp> closed = <SettleUp>[
      for (final SettleUp r in records)
        if (r.status.finished && r.roleOf(uid) != null) r,
    ];
    final List<PersonSummary> summary = summarizeSettleUps(records, uid);
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    const EdgeInsetsDirectional gutter = EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter);

    return ListView(
      key: const Key('settle.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, AppSpacing.s8),
          child: AppInlineMessage(key: const Key('settle.noMoney'), message: l10n.settleNoMoney),
        ),
        AppListRow(
          key: const Key('settle.address'),
          title: l10n.settleAddressRow,
          subtitle: address == null ? l10n.settleAddressMissing : ltrIsolate(address),
          leadingIcon: Icons.alternate_email_rounded,
          onTap: () => context.go(SettleUpRoutes.address),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, 0),
          child: AppButton(
            key: const Key('settle.new'),
            label: l10n.settleNewAction,
            icon: Icons.add_rounded,
            expand: true,
            onPressed: () => context.go(SettleUpRoutes.create(carpoolId: carpoolId)),
          ),
        ),
        if (summary.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.settleSummarySection),
          for (final PersonSummary s in summary)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s8),
              child: SettleSummaryCard(summary: s),
            ),
        ],
        AppSectionHeader(l10n.settleOpenSection),
        if (open.isEmpty)
          Padding(
            padding: gutter,
            child: Text(l10n.settleOpenEmpty, key: const Key('settle.openEmpty'), style: quiet),
          )
        else
          for (final SettleUp r in open) SettleRow(record: r, uid: uid, onTap: () => context.go(SettleUpRoutes.record(r.id))),
        if (closed.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.settleClosedSection),
          for (final SettleUp r in closed) SettleRow(record: r, uid: uid, onTap: () => context.go(SettleUpRoutes.record(r.id))),
        ],
      ],
    );
  }
}

/// "You owe / owes you" with one parent. Amounts are sums of records that
/// are not finished: a note between two parents, not a balance the app holds.
class SettleSummaryCard extends StatelessWidget {
  const SettleSummaryCard({required this.summary, super.key});

  final PersonSummary summary;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final PersonSummary s = summary;
    final TextStyle? line = context.text.bodyMedium;
    return AppCard(
      key: Key('settle.summary.${s.uid}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          OneLineText(s.firstName.isEmpty ? l10n.settleDeletedParent : s.firstName, style: context.text.titleSmall),
          const SizedBox(height: AppSpacing.s4),
          if (s.youOwe > 0) Text(l10n.settleSummaryYouOwe(Money.format(l10n, s.youOwe)), style: line),
          if (s.owesYou > 0) Text(l10n.settleSummaryOwesYou(Money.format(l10n, s.owesYou)), style: line),
          if (s.waiting > 0)
            Text(
              l10n.settleSummaryWaiting(Money.format(l10n, s.waiting)),
              style: line?.copyWith(color: context.colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// One record in a list: the other parent, the direction and amount, and
/// what happens next. No trailing widget, so the name keeps its room at
/// 320 dp and at 200 percent text.
class SettleRow extends StatelessWidget {
  const SettleRow({required this.record, required this.uid, super.key, this.onTap});

  final SettleUp record;
  final String uid;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final SettleRole mine = record.roleOf(uid) ?? SettleRole.payee;
    return AppListRow(
      key: Key('settle.row.${record.id}'),
      title: settleOtherName(l10n, record, mine),
      subtitle: l10n.settleRowSubtitle(settleDirection(l10n, record, mine), settleStatusLabel(l10n, record.status)),
      leadingIcon: settleIcon(mine),
      onTap: onTap,
    );
  }
}
