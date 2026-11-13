import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/queue_screen.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/admin/widgets/watermarked_image.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// One case with 5-minute image links. Every opening is in the audit log.
final _caseProvider = FutureProvider.autoDispose.family<CaseDetail, String>(
  (Ref ref, String caseId) => ref.watch(adminApiProvider).openCase(caseId),
);

/// Verification case (F2, F14): the documents with the reviewer's name
/// watermarked, the details, the checks the reviewer must tick (including
/// the parent and child name check, spec section 3), and approve or reject
/// with a reason.
///
/// Wide screens: documents on the start side, details and decision on the
/// end side. Narrow: one column.
///
/// States: loading (skeleton), error, offline and not found (retry), images
/// already deleted (note), decided meanwhile (note, back to the queue),
/// sending (button spinner).
class CaseScreen extends ConsumerStatefulWidget {
  const CaseScreen({required this.caseId, super.key});

  final String caseId;

  @override
  ConsumerState<CaseScreen> createState() => _CaseScreenState();
}

class _CaseScreenState extends ConsumerState<CaseScreen> {
  final Set<_Check> _ticked = <_Check>{};
  NameCheck? _nameCheck;
  bool _busy = false;
  AdminFailure? _failure;

  void _reload() => ref.invalidate(_caseProvider(widget.caseId));

  Future<void> _approve(CaseDetail c) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.adminApproveTitle,
      body: l10n.adminApproveBody,
      confirmLabel: l10n.adminApprove,
    );
    if (ok) {
      await _decide(
        () => ref.read(adminApiProvider).decide(caseId: c.caseId, approve: true, nameCheck: _nameCheck),
        l10n.adminApproved,
      );
    }
  }

  Future<void> _reject(CaseDetail c) async {
    final _Rejection? rejection = await showAppSheet<_Rejection>(
      context: context,
      title: context.l10n.adminRejectTitle,
      body: _RejectForm(canBan: c.identity),
    );
    if (rejection == null || !mounted) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    if (rejection.ban) {
      final bool ok = await showConfirmDialog(
        context: context,
        title: l10n.adminBanTitle,
        body: l10n.adminBanBody,
        confirmLabel: l10n.adminActionBan,
        destructive: true,
      );
      if (!ok) {
        return;
      }
    }
    await _decide(
      () => ref
          .read(adminApiProvider)
          .decide(caseId: c.caseId, approve: false, reason: rejection.reason, note: rejection.note, ban: rejection.ban),
      l10n.adminRejected,
    );
  }

  Future<void> _decide(Future<void> Function() call, String done) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await call();
      ref.invalidate(adminQueueProvider);
      if (mounted) {
        adminToast(context, done);
        context.go(AdminRoutes.queue);
      }
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

  void _tick(_Check check, {required bool on}) => setState(() {
    if (on) {
      _ticked.add(check);
    } else {
      _ticked.remove(check);
    }
  });

  List<_Check> _checksFor(CaseDetail c) => <_Check>[
    _Check.photos,
    if (c.identity) ...<_Check>[_Check.selfie, _Check.headTurn, _Check.idValid],
    if (c.driver != null) _Check.license,
  ];

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AdminUser? reviewer = adminUserOf(ref.watch(adminSessionProvider));
    final AsyncValue<CaseDetail> value = ref.watch(_caseProvider(widget.caseId));
    return AdminPage(
      title: l10n.adminCaseTitle,
      actions: <Widget>[
        IconButton(tooltip: l10n.adminReloadImages, icon: const Icon(Icons.refresh), onPressed: _reload),
      ],
      body: AdminAsyncView<CaseDetail>(
        value: value,
        onRetry: _reload,
        builder: (CaseDetail c) => LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget documents = _Documents(detail: c, watermark: _watermark(context, reviewer));
            final Widget review = _review(context, c);
            if (constraints.maxWidth >= AppSpacing.maxContentWidth * 1.4) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 3, child: documents),
                  Expanded(flex: 2, child: review),
                ],
              );
            }
            return ListView(children: <Widget>[documents, review]);
          },
        ),
      ),
    );
  }

  String _watermark(BuildContext context, AdminUser? reviewer) => <String>[
    reviewer?.displayName ?? '',
    reviewer?.email ?? '',
    adminDateTime(context, DateTime.now()),
  ].where((String s) => s.isNotEmpty).join(' · ');

  Widget _review(BuildContext context, CaseDetail c) {
    final AppLocalizations l10n = context.l10n;
    final List<_Check> checks = _checksFor(c);
    final bool needsName = c.children.isNotEmpty;
    final bool ready = checks.every(_ticked.contains) && (!needsName || _nameCheck != null);
    final AdminFailure? failure = _failure;

    return ListView(
      shrinkWrap: true,
      primary: false,
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        AppSectionHeader(l10n.adminCaseDetails),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AdminFact(label: l10n.adminCaseKind, value: c.identity ? l10n.adminCaseNew : l10n.adminCaseUpdate),
              if (c.fullName != null) AdminFact(label: l10n.adminNameOnId, value: c.fullName!),
              if (c.idExpiry != null) AdminFact(label: l10n.adminIdExpiry, value: c.idExpiry!),
              if (c.liveness != null)
                AdminFact(
                  label: l10n.adminHeadTurn,
                  value: c.liveness == LivenessChallenge.left ? l10n.adminTurnLeft : l10n.adminTurnRight,
                ),
              AdminFact(label: l10n.adminSubmitted, value: adminDateTime(context, c.submittedAt)),
              if (c.identity)
                Row(
                  children: <Widget>[
                    Flexible(child: OneLine(l10n.adminKycLabel)),
                    const SizedBox(width: AppSpacing.s8),
                    AppStatusBadge(label: kycLabel(l10n, c.kycResult), tone: kycTone(c.kycResult)),
                  ],
                ),
            ],
          ),
        ),
        for (final CaseChild child in c.children) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AdminFact(label: l10n.adminChildName, value: child.firstName),
                AdminFact(
                  label: l10n.adminChildDetails,
                  value: <String>[
                    l10n.childAgeYears(child.age),
                    if (child.grade != null) gradeLabel(l10n, child.grade!),
                    child.schoolName,
                  ].join(' · '),
                ),
              ],
            ),
          ),
        ],
        if (c.driver != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AdminFact(label: l10n.adminCar, value: '${c.driver!.model} · ${c.driver!.color} · ${c.driver!.plate}'),
                AdminFact(label: l10n.adminSeats, value: '${c.driver!.seats}'),
                AdminFact(label: l10n.adminLicenseExpiry, value: c.driver!.licenseExpiry),
                AdminFact(label: l10n.adminCarLicenseExpiry, value: c.driver!.carLicenseExpiry),
              ],
            ),
          ),
        ],
        if (c.decided) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(message: l10n.adminErrDecided, tone: AppStateTone.warning),
        ] else ...<Widget>[
          const SizedBox(height: AppSpacing.s24),
          AppSectionHeader(l10n.adminChecks),
          for (final _Check check in checks)
            AppCheckRow(
              key: Key('case.check.${check.name}'),
              label: check.label(l10n),
              value: _ticked.contains(check),
              onChanged: _busy ? null : (bool on) => _tick(check, on: on),
            ),
          if (needsName) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppSelectField<NameCheck>(
              key: const Key('case.nameCheck'),
              label: l10n.adminNameCheck,
              helperText: l10n.adminNameCheckHelp,
              options: <(NameCheck, String)>[
                (NameCheck.match, l10n.adminNameCheckMatch),
                (NameCheck.birthCertificate, l10n.adminNameCheckBirth),
              ],
              value: _nameCheck,
              onChanged: _busy ? null : (NameCheck v) => setState(() => _nameCheck = v),
            ),
          ],
          if (failure != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppInlineMessage(
              message: failure.message(l10n),
              tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
            ),
          ],
          const SizedBox(height: AppSpacing.s24),
          if (!ready) ...<Widget>[
            OneLine(l10n.adminTickAll, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.s8),
          ],
          AppButton(
            key: const Key('case.approve'),
            label: l10n.adminApprove,
            icon: Icons.check_rounded,
            expand: true,
            loading: _busy,
            onPressed: ready && !_busy ? () => unawaited(_approve(c)) : null,
          ),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('case.reject'),
            label: l10n.adminReject,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: _busy ? null : () => unawaited(_reject(c)),
          ),
        ],
      ],
    );
  }
}

/// The checks a reviewer ticks before approving.
enum _Check {
  photos,
  selfie,
  headTurn,
  idValid,
  license;

  String label(AppLocalizations l10n) => switch (this) {
    _Check.photos => l10n.adminCheckPhotos,
    _Check.selfie => l10n.adminCheckSelfie,
    _Check.headTurn => l10n.adminCheckHeadTurn,
    _Check.idValid => l10n.adminCheckIdValid,
    _Check.license => l10n.adminCheckLicense,
  };
}

class _Documents extends StatelessWidget {
  const _Documents({required this.detail, required this.watermark});

  final CaseDetail detail;
  final String watermark;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<(String, String?)> items = <(String, String?)>[
      if (detail.identity) ...<(String, String?)>[
        (l10n.adminDocIdFront, detail.images['id_front.jpg']),
        (l10n.adminDocIdBack, detail.images['id_back.jpg']),
        (l10n.adminDocSelfie, detail.images['selfie.jpg']),
        (l10n.adminDocHeadTurn, detail.images['selfie_turn.jpg']),
      ],
      for (final CaseChild child in detail.children) (l10n.adminDocSchoolId(child.firstName), child.imageUrl),
      if (detail.driver != null) ...<(String, String?)>[
        (l10n.adminDocLicense, detail.images['license.jpg']),
        (l10n.adminDocCarLicense, detail.images['car_license.jpg']),
      ],
    ];
    return ListView(
      shrinkWrap: true,
      primary: false,
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        if (detail.images.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s16),
            child: AppInlineMessage(message: l10n.adminImagesDeleted, icon: Icons.auto_delete_outlined),
          ),
        for (final (String label, String? url) in items) ...<Widget>[
          AppSectionHeader(label),
          WatermarkedImage(url: url, watermark: watermark, semanticLabel: label),
          const SizedBox(height: AppSpacing.s16),
        ],
      ],
    );
  }
}

/// What the reject sheet returns.
class _Rejection {
  const _Rejection(this.reason, this.note, {required this.ban});

  final RejectionReason reason;
  final String? note;
  final bool ban;
}

/// Reason (required), note (required for "other"; the parent sees it),
/// and ban (new accounts only: the ID can never register again).
class _RejectForm extends StatefulWidget {
  const _RejectForm({required this.canBan});

  final bool canBan;

  @override
  State<_RejectForm> createState() => _RejectFormState();
}

class _RejectFormState extends State<_RejectForm> {
  final TextEditingController _note = TextEditingController();
  RejectionReason? _reason;
  bool _ban = false;

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

  bool get _valid {
    final RejectionReason? r = _reason;
    if (r == null || _note.text.length > 500) {
      return false;
    }
    return r != RejectionReason.other || _note.text.trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String note = _note.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSelectField<RejectionReason>(
          key: const Key('reject.reason'),
          label: l10n.adminReasonLabel,
          options: <(RejectionReason, String)>[
            for (final RejectionReason r in RejectionReason.values) (r, rejectionReasonShort(l10n, r)),
          ],
          value: _reason,
          onChanged: (RejectionReason r) => setState(() => _reason = r),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('reject.note'),
          label: l10n.adminNoteLabel,
          helperText: l10n.adminNoteParentSees,
          controller: _note,
          maxLength: 500,
          errorText: _reason == RejectionReason.other && note.isEmpty ? l10n.adminNoteRequired : null,
        ),
        if (widget.canBan)
          AppCheckRow(
            key: const Key('reject.ban'),
            label: l10n.adminBanCheck,
            helperText: l10n.adminBanHelp,
            value: _ban,
            onChanged: (bool v) => setState(() => _ban = v),
          ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('reject.submit'),
          label: l10n.adminReject,
          variant: AppButtonVariant.danger,
          expand: true,
          onPressed: _valid
              ? () => Navigator.of(context).pop(_Rejection(_reason!, note.isEmpty ? null : note, ban: _ban))
              : null,
        ),
      ],
    );
  }
}
