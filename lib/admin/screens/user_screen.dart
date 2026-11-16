import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/user_settle_up_section.dart';
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

  /// Prompt 13: compare the kept new-phone selfie with the reference photo
  /// and close the check with a logged reason (Valify's face match is a
  /// stub until the contract, so every check waits for an admin).
  Future<void> _deviceCheck() async {
    final AppLocalizations l10n = context.l10n;
    final (DeviceCheckOutcome, AccessReasonCode)? choice = await showAppSheet<(DeviceCheckOutcome, AccessReasonCode)>(
      context: context,
      title: l10n.adminDeviceCheckSheet,
      body: _DeviceCheckForm(uid: widget.uid),
    );
    if (choice == null || !mounted) {
      return;
    }
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.adminDeviceCheckConfirmTitle,
      body: l10n.adminDeviceCheckConfirmBody,
      confirmLabel: l10n.adminDeviceCheckClose,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(adminApiProvider).decideDeviceCheck(uid: widget.uid, outcome: choice.$1, reason: choice.$2);
      if (mounted) {
        showAppSnackBar(context, l10n.adminDeviceCheckDone);
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
              if (d.deviceCheckSince != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppCard(
                  key: const Key('user.deviceCheck'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(Icons.phonelink_lock_outlined, color: context.appColors.warning),
                          const SizedBox(width: AppSpacing.s8),
                          Expanded(child: OneLineText(l10n.adminDeviceCheckTitle, style: context.text.titleMedium)),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.s8),
                      Text(l10n.adminDeviceCheckBody, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                      AdminFact(label: l10n.adminDeviceCheckSince, value: adminDateTime(context, d.deviceCheckSince)),
                      const SizedBox(height: AppSpacing.s8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppButton(
                          key: const Key('user.deviceCheck.open'),
                          label: l10n.adminDeviceCheckOpen,
                          loading: _busy,
                          onPressed: _busy ? null : () => unawaited(_deviceCheck()),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // Prompt 11B: the parent's wallet (read only, freeze); shown
              // only while the wallet is on (no money in the app, 16 Nov 2026).
              if (adminSwitchesNow(ref).wallet)
                AppListRow(
                  key: const Key('user.wallet'),
                  inset: false,
                  title: l10n.adminWalletOneTitle,
                  leadingIcon: Icons.account_balance_wallet_outlined,
                  onTap: () => context.go(AdminRoutes.wallet(widget.uid)),
                ),
              // F45: the parent's settle-up records (read only, logged reason),
              // only while Settle up is on.
              if (adminSwitchesNow(ref).settleUp) UserSettleUpSection(uid: widget.uid),
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
                              ReviewStatus.left => AppBadgeTone.neutral,
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

/// Prompt 13: the reference photo and the latest kept selfie side by side
/// (opened with a logged reason; thumbnails, 5-minute links), how the
/// parent was confirmed, then "Close check".
class _DeviceCheckForm extends ConsumerStatefulWidget {
  const _DeviceCheckForm({required this.uid});

  final String uid;

  @override
  ConsumerState<_DeviceCheckForm> createState() => _DeviceCheckFormState();
}

class _DeviceCheckFormState extends ConsumerState<_DeviceCheckForm> {
  /// Chosen by the admin first: the photos open (and are logged) only after.
  AccessReasonCode? _reason;
  DeviceCheckOutcome? _outcome;
  Future<List<AdminPhoto>>? _photos;

  /// One logged access, with the reason the admin picked.
  void _open(AccessReasonCode reason) {
    final Future<List<AdminPhoto>> photos = ref.read(adminApiProvider).userPhotos(widget.uid, reason);
    setState(() {
      _photos = photos;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final DeviceCheckOutcome? outcome = _outcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSelectField<AccessReasonCode>(
          key: const Key('deviceCheck.reason'),
          label: l10n.adminAccessReasonLabel,
          options: <(AccessReasonCode, String)>[
            for (final AccessReasonCode r in AccessReasonCode.values) (r, accessReasonLabel(l10n, r)),
          ],
          value: _reason,
          // Locked once the photos are open (a new reason would be a new access).
          onChanged: _photos != null ? null : (AccessReasonCode r) => setState(() => _reason = r),
        ),
        const SizedBox(height: AppSpacing.s16),
        if (_photos == null)
          AppButton(
            key: const Key('deviceCheck.showPhotos'),
            label: l10n.adminDeviceShowPhotos,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: _reason == null ? null : () => _open(_reason!),
          )
        else
        FutureBuilder<List<AdminPhoto>>(
          future: _photos,
          builder: (BuildContext context, AsyncSnapshot<List<AdminPhoto>> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Skeleton(child: SkeletonBox(height: AppSpacing.s64 * 2));
            }
            final Object? error = snap.error;
            if (error != null) {
              return AppInlineMessage(
                message: error is AdminFailure ? error.message(l10n) : l10n.adminPhotosNone,
                tone: AppStateTone.error,
              );
            }
            final List<AdminPhoto> photos = snap.data ?? const <AdminPhoto>[];
            final AdminPhoto? face = photos.where((AdminPhoto p) => p.kind == 'faceRef').firstOrNull;
            final List<AdminPhoto> selfies = photos.where((AdminPhoto p) => p.kind == 'selfie').toList()
              ..sort((AdminPhoto a, AdminPhoto b) => (b.storedAt ?? DateTime(0)).compareTo(a.storedAt ?? DateTime(0)));
            if (face == null && selfies.isEmpty) {
              return AppInlineMessage(message: l10n.adminPhotosNone);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: _Photo(key: const Key('deviceCheck.face'), label: l10n.adminPhotoFaceRef, photo: face)),
                const SizedBox(width: AppSpacing.s16),
                Expanded(child: _Photo(key: const Key('deviceCheck.selfie'), label: l10n.adminPhotoSelfie, photo: selfies.firstOrNull)),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<DeviceCheckOutcome>(
          key: const Key('deviceCheck.outcome'),
          label: l10n.adminDeviceOutcomeLabel,
          options: <(DeviceCheckOutcome, String)>[
            for (final DeviceCheckOutcome o in DeviceCheckOutcome.values) (o, deviceOutcomeLabel(l10n, o)),
          ],
          value: outcome,
          onChanged: (DeviceCheckOutcome o) => setState(() => _outcome = o),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('deviceCheck.submit'),
          label: l10n.adminDeviceCheckClose,
          expand: true,
          onPressed: outcome == null || _reason == null
              ? null
              : () => Navigator.of(context).pop<(DeviceCheckOutcome, AccessReasonCode)>((outcome, _reason!)),
        ),
      ],
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.label, required this.photo, super.key});

  final String label;
  final AdminPhoto? photo;

  @override
  Widget build(BuildContext context) {
    final AdminPhoto? p = photo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        OneLineText(label, style: context.text.labelLarge),
        const SizedBox(height: AppSpacing.s8),
        ClipRRect(
          borderRadius: AppRadii.card,
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: p == null
                ? ColoredBox(color: context.colors.surfaceContainerHighest, child: const Icon(Icons.hide_image_outlined))
                : Image.network(
                    p.url,
                    fit: BoxFit.cover,
                    semanticLabel: label,
                    errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                        ColoredBox(color: context.colors.surfaceContainerHighest, child: const Icon(Icons.broken_image_outlined)),
                  ),
          ),
        ),
      ],
    );
  }
}
