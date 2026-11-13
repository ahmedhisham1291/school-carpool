import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/legal_documents.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/child_form_screen.dart';
import 'package:school_carpool/features/verification/review_status_badge.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Profile > Children (F3): the parent's children with their review status.
/// A verified parent adds, edits (with a new school ID photo, reviewed
/// again) and removes children here. Before verification, children are
/// added in the verification steps.
///
/// States: loading (skeleton), empty (no children yet), error and offline
/// (retry), sending (progress in the button area), and a note while a
/// review is pending (no changes until it is decided).
class ChildrenScreen extends ConsumerStatefulWidget {
  const ChildrenScreen({super.key});

  @override
  ConsumerState<ChildrenScreen> createState() => _ChildrenScreenState();
}

class _ChildrenScreenState extends ConsumerState<ChildrenScreen> {
  bool _busy = false;
  double? _progress;
  VerificationFailure? _failure;

  static const String _slot = 'c1';

  Future<void> _edit([ChildRecord? record]) async {
    final ChildDraft initial = record == null
        ? const ChildDraft(ref: _slot)
        : ChildDraft(
            ref: _slot,
            childId: record.id,
            firstName: record.firstName,
            age: record.age,
            grade: record.grade,
            schoolName: record.schoolName,
          );
    final ChildDraft? child = await openChildForm(context, initial);
    final Uint8List? photo = child?.schoolIdPhoto;
    if (child == null || photo == null || !mounted) {
      return;
    }
    await _send(<String, Uint8List>{schoolIdFileName(_slot): photo}, <String, Object?>{
      'children': <Map<String, Object?>>[child.toPayload()],
      'driver': null,
      'consents': LegalDocuments.verification,
    });
  }

  Future<void> _send(Map<String, Uint8List> files, Map<String, Object?> payload) async {
    final SessionState session = ref.read(sessionProvider);
    if (session is! SessionSignedIn) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String done = context.l10n.childSentForReview;
    final Set<String> uploaded = <String>{};
    setState(() {
      _busy = true;
      _failure = null;
      _progress = 0;
    });
    try {
      await uploadAndSubmit(
        repository: ref.read(verificationRepositoryProvider),
        uid: session.uid,
        files: files,
        payload: payload,
        isUploaded: uploaded.contains,
        markUploaded: uploaded.add,
        forgetUploads: uploaded.removeAll,
        onProgress: (double p) {
          if (mounted) {
            setState(() => _progress = p);
          }
        },
      );
      showAppSnackBarOn(messenger, done);
    } on VerificationFailure catch (failure) {
      if (mounted) {
        setState(() => _failure = failure);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _remove(ChildRecord child) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.childRemoveTitle(child.firstName),
      body: l10n.childRemoveBody,
      confirmLabel: l10n.childRemove,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref.read(verificationRepositoryProvider).removeChild(child.id);
      showAppSnackBarOn(messenger, l10n.childRemoved);
    } on VerificationFailure catch (failure) {
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
    final Account? account = accountOf(ref.watch(sessionProvider));
    final AsyncValue<List<ChildRecord>> children = ref.watch(childrenProvider);
    final bool verified = account?.status == AccountStatus.verified;
    final bool locked = account?.reviewPending ?? true;
    final bool canChange = verified && !locked && !_busy;
    final VerificationFailure? failure = _failure;
    final double? progress = _progress;
    void retry() => ref.invalidate(childrenProvider);

    final Widget list = switch (children) {
      AsyncData<List<ChildRecord>>(:final List<ChildRecord> value) when value.isEmpty => EmptyStateView(
        icon: Icons.child_care_outlined,
        title: l10n.childrenEmptyTitle,
        body: verified ? l10n.childrenEmptyBody : l10n.childrenAddInVerification,
      ),
      AsyncData<List<ChildRecord>>(:final List<ChildRecord> value) => ListView(
        children: <Widget>[
          for (final ChildRecord child in value)
            AppListRow(
              key: Key('children.${child.id}'),
              title: child.firstName,
              // The review status leads the subtitle (not a trailing badge),
              // so the one-line name keeps its room at 320 dp and 200%.
              subtitle: <String>[
                <String>[
                  reviewStatusLabel(l10n, child.status),
                  l10n.childAgeYears(child.age),
                  gradeLabel(l10n, child.grade),
                  child.schoolName,
                ].join(' · '),
                if (child.status == ReviewStatus.rejected && child.reason != null)
                  rejectionReasonText(l10n, child.reason!),
              ].join('\n'),
              leadingIcon: ReviewStatusBadge.iconFor(child.status),
              onTap: canChange ? () => unawaited(_showActions(child)) : null,
            ),
        ],
      ),
      AsyncError<List<ChildRecord>>(:final Object error) =>
        VerificationFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry),
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()])),
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.childrenTitle)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (verified && locked)
              Padding(
                padding: AppSpacing.screenPadding,
                child: AppInlineMessage(message: l10n.childrenLockedPending, icon: Icons.hourglass_top_rounded),
              ),
            Expanded(child: list),
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (failure != null) ...<Widget>[
                    AppInlineMessage(
                      message: failure.message(l10n),
                      tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                    ),
                    const SizedBox(height: AppSpacing.s16),
                  ],
                  if (progress != null) ...<Widget>[
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: AppSpacing.s8),
                    Text(l10n.verifyUploading((progress * 100).round()), style: context.text.bodyMedium),
                    const SizedBox(height: AppSpacing.s8),
                  ],
                  if (verified)
                    AppButton(
                      key: const Key('children.add'),
                      label: l10n.childAddTitle,
                      icon: Icons.add_rounded,
                      expand: true,
                      loading: _busy,
                      onPressed: canChange ? () => unawaited(_edit()) : null,
                    )
                  else
                    AppButton(
                      key: const Key('children.verify'),
                      label: l10n.verifyOpenStatus,
                      expand: true,
                      onPressed: () => context.go(AuthRoutes.verifyAccount),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showActions(ChildRecord child) async {
    final AppLocalizations l10n = context.l10n;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppListRow(
              title: l10n.childEditTitle,
              subtitle: l10n.childEditHelper,
              leadingIcon: Icons.edit_outlined,
              onTap: () => Navigator.of(sheet).pop('edit'),
            ),
            AppListRow(
              title: l10n.childRemove,
              leadingIcon: Icons.delete_outline_rounded,
              onTap: () => Navigator.of(sheet).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (action == 'edit') {
      await _edit(child);
    } else if (action == 'remove') {
      await _remove(child);
    }
  }
}
