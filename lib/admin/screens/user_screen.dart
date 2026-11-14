import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// One parent, with verification and moderation history. Every opening is
/// in the audit log.
final _userProvider = FutureProvider.autoDispose.family<UserDetail, String>(
  (Ref ref, String uid) => ref.watch(adminApiProvider).user(uid),
);

/// User detail (F14): status, parent ID, masked phone and email,
/// verification history, moderation history, and suspend, unsuspend or
/// ban with a reason (each asks for confirmation; a ban cannot be undone
/// here).
///
/// States: loading (skeleton), error, offline and not found (retry),
/// sending (button spinner), refused (own account, an admin).
class UserScreen extends ConsumerStatefulWidget {
  const UserScreen({required this.uid, super.key});

  final String uid;

  @override
  ConsumerState<UserScreen> createState() => _UserScreenState();
}

class _UserScreenState extends ConsumerState<UserScreen> {
  bool _busy = false;
  AdminFailure? _failure;

  void _reload() => ref.invalidate(_userProvider(widget.uid));

  Future<void> _moderate(ModerationAction action) async {
    final AppLocalizations l10n = context.l10n;
    final (ModerationReason, String?)? choice = await showAppSheet<(ModerationReason, String?)>(
      context: context,
      title: moderationActionLabel(l10n, action),
      body: _ModerationForm(action: action),
    );
    if (choice == null || !mounted) {
      return;
    }
    final bool ok = await showConfirmDialog(
      context: context,
      title: switch (action) {
        ModerationAction.suspend => l10n.adminSuspendTitle,
        ModerationAction.unsuspend => l10n.adminUnsuspendTitle,
        ModerationAction.ban => l10n.adminBanTitle,
      },
      body: switch (action) {
        ModerationAction.suspend => l10n.adminSuspendBody,
        ModerationAction.unsuspend => l10n.adminUnsuspendBody,
        ModerationAction.ban => l10n.adminBanUserBody,
      },
      confirmLabel: moderationActionLabel(l10n, action),
      destructive: action != ModerationAction.unsuspend,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref
          .read(adminApiProvider)
          .moderate(uid: widget.uid, action: action, reason: choice.$1, note: choice.$2);
      if (mounted) {
        showAppSnackBar(context, l10n.adminSaved);
      }
      _reload();
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
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
    return AdminPage(
      title: l10n.adminUserTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: _reload)],
      body: AdminAsyncView<UserDetail>(
        value: ref.watch(_userProvider(widget.uid)),
        onRetry: _reload,
        builder: (UserDetail d) {
          final UserSummary u = d.summary;
          final AdminFailure? failure = _failure;
          return ListView(
            padding: AppSpacing.screenPadding,
            children: <Widget>[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(child: OneLineText(u.fullName ?? l10n.adminNoName, style: context.text.titleLarge)),
                        AppStatusBadge(
                          label: accountStatusLabel(l10n, u.status, banned: u.banned),
                          tone: accountStatusTone(u.status, banned: u.banned),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AdminFact(label: l10n.adminParentId, value: ltrIsolate(u.parentId)),
                    AdminFact(label: l10n.adminPhone, value: ltrIsolate(u.maskedPhone ?? '-')),
                    AdminFact(label: l10n.adminEmailLabel, value: ltrIsolate(d.maskedEmail ?? '-')),
                    AdminFact(label: l10n.adminJoined, value: adminDateTime(context, u.createdAt)),
                  ],
                ),
              ),
              // Prompt 11B: the parent's wallet (read only, freeze).
              AppListRow(
                key: const Key('user.wallet'),
                inset: false,
                title: l10n.adminWalletOneTitle,
                leadingIcon: Icons.account_balance_wallet_outlined,
                onTap: () => context.go(AdminRoutes.wallet(widget.uid)),
              ),
              const SizedBox(height: AppSpacing.s24),
              AppSectionHeader(l10n.adminVerificationHistory),
              if (d.cases.isEmpty)
                AppInlineMessage(message: l10n.adminNoHistory)
              else
                for (final CaseHistory c in d.cases)
                  AppListRow(
                    inset: false,
                    title: c.identity ? l10n.adminCaseNew : l10n.adminCaseUpdate,
                    subtitle: <String>[
                      adminDateTime(context, c.submittedAt),
                      if (c.reason != null) rejectionReasonShort(l10n, c.reason!),
                    ].join(' · '),
                    leadingIcon: Icons.badge_outlined,
                    trailing: c.withdrawn
                        ? AppStatusBadge(label: l10n.adminWithdrawn)
                        : AppStatusBadge(
                            label: reviewStatusLabel(l10n, c.status),
                            tone: switch (c.status) {
                              ReviewStatus.approved => AppBadgeTone.success,
                              ReviewStatus.rejected => AppBadgeTone.error,
                              ReviewStatus.pending => AppBadgeTone.warning,
                            },
                          ),
                  ),
              const SizedBox(height: AppSpacing.s24),
              AppSectionHeader(l10n.adminModerationHistory),
              if (d.actions.isEmpty)
                AppInlineMessage(message: l10n.adminNoHistory)
              else
                for (final ActionHistory a in d.actions)
                  AppListRow(
                    inset: false,
                    title: auditActionLabel(l10n, a.action),
                    subtitle: <String>[
                      adminDateTime(context, a.time),
                      if (a.reason != null) moderationReasonLabel(l10n, a.reason!),
                    ].join(' · '),
                    leadingIcon: Icons.gavel_outlined,
                  ),
              if (failure != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(
                  message: failure.message(l10n),
                  tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                ),
              ],
              const SizedBox(height: AppSpacing.s24),
              if (!u.banned)
                Wrap(
                  spacing: AppSpacing.s8,
                  runSpacing: AppSpacing.s8,
                  children: <Widget>[
                    if (u.status == AccountStatus.suspended)
                      AppButton(
                        key: const Key('user.unsuspend'),
                        label: l10n.adminActionUnsuspend,
                        loading: _busy,
                        onPressed: _busy ? null : () => unawaited(_moderate(ModerationAction.unsuspend)),
                      )
                    else
                      AppButton(
                        key: const Key('user.suspend'),
                        label: l10n.adminActionSuspend,
                        variant: AppButtonVariant.secondary,
                        loading: _busy,
                        onPressed: _busy ? null : () => unawaited(_moderate(ModerationAction.suspend)),
                      ),
                    AppButton(
                      key: const Key('user.ban'),
                      label: l10n.adminActionBan,
                      variant: AppButtonVariant.danger,
                      onPressed: _busy ? null : () => unawaited(_moderate(ModerationAction.ban)),
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

/// Reason and optional note (required for "other"). The parent never sees
/// the note.
class _ModerationForm extends StatefulWidget {
  const _ModerationForm({required this.action});

  final ModerationAction action;

  @override
  State<_ModerationForm> createState() => _ModerationFormState();
}

class _ModerationFormState extends State<_ModerationForm> {
  final TextEditingController _note = TextEditingController();
  ModerationReason? _reason;

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String note = _note.text.trim();
    final ModerationReason? reason = _reason;
    final bool valid = reason != null && (reason != ModerationReason.other || note.isNotEmpty) && note.length <= 500;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSelectField<ModerationReason>(
          key: const Key('moderation.reason'),
          label: l10n.adminReasonLabel,
          options: <(ModerationReason, String)>[
            for (final ModerationReason r in ModerationReason.values) (r, moderationReasonLabel(l10n, r)),
          ],
          value: reason,
          onChanged: (ModerationReason r) => setState(() => _reason = r),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('moderation.note'),
          label: l10n.adminNoteLabel,
          helperText: l10n.adminNoteInternal,
          controller: _note,
          maxLength: 500,
          errorText: reason == ModerationReason.other && note.isEmpty ? l10n.adminNoteRequired : null,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('moderation.submit'),
          label: moderationActionLabel(l10n, widget.action),
          variant: widget.action == ModerationAction.unsuspend ? AppButtonVariant.primary : AppButtonVariant.danger,
          expand: true,
          onPressed: valid
              ? () => Navigator.of(context).pop<(ModerationReason, String?)>((reason, note.isEmpty ? null : note))
              : null,
        ),
      ],
    );
  }
}
