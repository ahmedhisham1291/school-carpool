import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/wallet/wallet_models.dart' show Money;
import 'package:school_carpool/l10n/l10n.dart';

String _statusLabel(AppLocalizations l10n, String status) => switch (status) {
  'open' => l10n.settleStatusOpen,
  'paid' => l10n.settleStatusPaid,
  'closed' => l10n.settleStatusClosed,
  'declined' => l10n.settleStatusDeclined,
  _ => l10n.settleStatusCancelled,
};

AppBadgeTone _statusTone(String status) => switch (status) {
  'open' || 'paid' => AppBadgeTone.warning,
  'closed' => AppBadgeTone.success,
  _ => AppBadgeTone.neutral,
};

String _reasonLabel(AppLocalizations l10n, String reason) => switch (reason) {
  'contribution' => l10n.settleReasonContribution,
  'fuel' => l10n.settleReasonFuel,
  _ => l10n.settleReasonOther,
};

/// User page: the parent's settle-up records (F45). Read only: an admin
/// cannot change a record, and the app moves no money. Opened like the
/// kept photos: the admin picks a reason first, the server logs the access
/// with it, then the list shows. Never the InstaPay address or the note.
///
/// States: closed (reason and a button), loading (skeleton), none (a short
/// line), error and offline (one sentence; pick the reason again to retry).
class UserSettleUpSection extends ConsumerStatefulWidget {
  const UserSettleUpSection({required this.uid, super.key});

  final String uid;

  @override
  ConsumerState<UserSettleUpSection> createState() => _UserSettleUpSectionState();
}

class _UserSettleUpSectionState extends ConsumerState<UserSettleUpSection> {
  AccessReasonCode? _reason;
  Future<List<AdminSettleRecord>>? _records;

  /// One logged access, with the reason the admin picked.
  void _open(AccessReasonCode reason) {
    final Future<List<AdminSettleRecord>> records = ref.read(adminFeaturesApiProvider).settleUps(uid: widget.uid, reason: reason);
    // A block body: setState must not return the Future.
    setState(() {
      _records = records;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AccessReasonCode? reason = _reason;
    return Column(
      key: const Key('user.settleUp'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.adminSettleSection),
        Text(l10n.adminSettleIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s8),
        AppSelectField<AccessReasonCode>(
          key: const Key('user.settleUp.reason'),
          label: l10n.adminAccessReasonLabel,
          options: <(AccessReasonCode, String)>[
            for (final AccessReasonCode r in AccessReasonCode.values) (r, accessReasonLabel(l10n, r)),
          ],
          value: reason,
          // Locked once the list is open (a new reason would be a new access).
          onChanged: _records != null ? null : (AccessReasonCode r) => setState(() => _reason = r),
        ),
        const SizedBox(height: AppSpacing.s8),
        if (_records == null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const Key('user.settleUp.show'),
              label: l10n.adminSettleShow,
              variant: AppButtonVariant.secondary,
              onPressed: reason == null ? null : () => _open(reason),
            ),
          )
        else
          FutureBuilder<List<AdminSettleRecord>>(
            future: _records,
            builder: (BuildContext context, AsyncSnapshot<List<AdminSettleRecord>> snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const AdminSkeletonList(rows: 2);
              }
              final Object? error = snap.error;
              if (error != null) {
                return AppInlineMessage(
                  key: const Key('user.settleUp.error'),
                  message: error is AdminFailure ? error.message(l10n) : l10n.errorGeneric,
                  tone: AppStateTone.error,
                );
              }
              final List<AdminSettleRecord> records = snap.data ?? const <AdminSettleRecord>[];
              if (records.isEmpty) {
                return AppInlineMessage(key: const Key('user.settleUp.none'), message: l10n.adminSettleNone);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final AdminSettleRecord r in records)
                    AppListRow(
                      key: Key('user.settleUp.${r.id}'),
                      inset: false,
                      title: r.payee
                          ? l10n.adminSettleFrom(r.otherFirstName, Money.format(l10n, r.amount))
                          : l10n.adminSettleTo(r.otherFirstName, Money.format(l10n, r.amount)),
                      subtitle: <String>[
                        adminDateTime(context, r.createdAt),
                        _reasonLabel(l10n, r.reason),
                        if (r.notReceived > 0) l10n.adminSettleBounced(r.notReceived),
                        if (r.reported) l10n.settleEventReported,
                      ].join(' · '),
                      leadingIcon: r.payee ? Icons.south_west_rounded : Icons.north_east_rounded,
                      showChevron: false,
                      trailing: AppStatusBadge(label: _statusLabel(l10n, r.status), tone: _statusTone(r.status)),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}
