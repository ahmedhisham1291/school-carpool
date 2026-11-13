import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/child_form_screen.dart';
import 'package:school_carpool/features/verification/driver_form.dart';
import 'package:school_carpool/features/verification/national_id.dart';
import 'package:school_carpool/features/verification/screen_security.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Steps of the first verification (spec section 3, steps 3 to 6).
enum VerificationStep { details, idPhotos, selfie, children, driving, review }

/// Document submission for review (F2, F3), one short step at a time with
/// a progress bar: your details, ID photos, live selfie, children, driving
/// (optional), then review, consent and submit.
///
/// Everything stays in memory until submit; screenshots are blocked on the
/// whole flow. States: each step checks its fields as the parent types and
/// says what is missing; submit shows upload progress, then errors (with
/// what to fix) or offline (retry sends only what is missing). There is
/// nothing to load, so no skeleton or empty state.
class VerificationFlowScreen extends ConsumerStatefulWidget {
  const VerificationFlowScreen({super.key, this.initialStep = VerificationStep.details});

  /// For tests and screenshots.
  final VerificationStep initialStep;

  @override
  ConsumerState<VerificationFlowScreen> createState() => _VerificationFlowScreenState();
}

class _VerificationFlowScreenState extends ConsumerState<VerificationFlowScreen> {
  late VerificationStep _step = widget.initialStep;
  bool _busy = false;
  double? _progress;
  VerificationFailure? _failure;

  DateTime get _today {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  VerificationDraftController get _draft => ref.read(verificationDraftProvider.notifier);

  bool _stepComplete(VerificationDraft d) => switch (_step) {
    VerificationStep.details => d.detailsComplete(_today),
    VerificationStep.idPhotos => d.idPhotosComplete,
    VerificationStep.selfie => d.selfieComplete,
    VerificationStep.children => d.childrenComplete,
    VerificationStep.driving => d.drivingComplete(_today),
    VerificationStep.review => d.readyToSubmit(_today),
  };

  void _back() {
    if (_busy) {
      return;
    }
    if (_step.index == 0) {
      context.go(AuthRoutes.verifyAccount);
      return;
    }
    setState(() {
      _failure = null;
      _step = VerificationStep.values[_step.index - 1];
    });
  }

  void _next() => setState(() {
    _failure = null;
    _step = VerificationStep.values[_step.index + 1];
  });

  Future<void> _capture(CaptureKind kind) async {
    final CaptureLauncher launch = ref.read(captureLauncherProvider);
    final VerificationDraft draft = ref.read(verificationDraftProvider);
    final CaptureResult? result = await launch(context, CaptureRequest(kind, challenge: draft.challenge));
    if (result == null || !mounted) {
      return;
    }
    switch (kind) {
      case CaptureKind.idFront:
        _draft.setPhoto(VerificationDocument.idFront, result.image);
      case CaptureKind.idBack:
        _draft.setPhoto(VerificationDocument.idBack, result.image);
      case CaptureKind.selfie:
        _draft.setPhoto(VerificationDocument.selfie, result.image);
        final Uint8List? turn = result.turnImage;
        if (turn != null) {
          _draft.setPhoto(VerificationDocument.selfieTurn, turn);
        }
      case CaptureKind.schoolId || CaptureKind.license || CaptureKind.carLicense:
        break;
    }
  }

  Future<void> _addOrEditChild([ChildDraft? existing]) async {
    final String? ref = existing?.ref ?? _draft.newChildRef();
    if (ref == null) {
      return;
    }
    final ChildDraft initial = existing ?? ChildDraft(ref: ref);
    final ChildDraft? child = await openChildForm(context, initial);
    if (child != null && mounted) {
      _draft.saveChild(child);
    }
  }

  Future<void> _removeChild(ChildDraft child) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.childRemoveTitle(child.firstName),
      body: l10n.childRemoveDraftBody,
      confirmLabel: l10n.childRemove,
    );
    if (ok) {
      _draft.removeChild(child.ref);
    }
  }

  void _driverChanged(DriverDraft next) {
    final VerificationDraft d = ref.read(verificationDraftProvider);
    final List<String> stale = <String>[
      if (!identical(next.licensePhoto, d.driver.licensePhoto)) VerificationDocument.license.fileName,
      if (!identical(next.carLicensePhoto, d.driver.carLicensePhoto)) VerificationDocument.carLicense.fileName,
    ];
    _draft
      ..update((VerificationDraft v) => v.copyWith(driver: next))
      ..forgetUploads(stale);
  }

  Future<void> _submit() async {
    final SessionState session = ref.read(sessionProvider);
    if (_busy || session is! SessionSignedIn) {
      return;
    }
    final VerificationRepository repository = ref.read(verificationRepositoryProvider);
    final VerificationDraft draft = ref.read(verificationDraftProvider);
    setState(() {
      _busy = true;
      _failure = null;
      _progress = 0;
    });
    try {
      await uploadAndSubmit(
        repository: repository,
        uid: session.uid,
        files: draft.files(),
        payload: draft.toPayload(),
        isUploaded: (String name) => ref.read(verificationDraftProvider).uploaded.contains(name),
        markUploaded: _draft.markUploaded,
        forgetUploads: _draft.forgetUploads,
        onProgress: (double p) {
          if (mounted) {
            setState(() => _progress = p);
          }
        },
      );
      if (!mounted) {
        return;
      }
      _draft.reset();
      // The account is now "pending"; the status screen says what happens next.
      context.go(AuthRoutes.verifyAccount);
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final VerificationDraft draft = ref.watch(verificationDraftProvider);
    final bool last = _step == VerificationStep.review;
    final bool complete = _stepComplete(draft);
    final VerificationFailure? failure = _failure;
    final double? progress = _progress;

    final (String title, String body) = switch (_step) {
      VerificationStep.details => (l10n.verifyDetailsTitle, l10n.verifyDetailsBody),
      VerificationStep.idPhotos => (l10n.verifyIdTitle, l10n.verifyIdBody),
      VerificationStep.selfie => (l10n.verifySelfieTitle, l10n.verifySelfieBody),
      VerificationStep.children => (l10n.verifyChildrenTitle, l10n.verifyChildrenBody),
      VerificationStep.driving => (l10n.verifyDrivingTitle, l10n.verifyDrivingBody),
      VerificationStep.review => (l10n.verifyReviewTitle, l10n.verifyReviewBody),
    };

    final List<Widget> content = switch (_step) {
      VerificationStep.details => <Widget>[_DetailsStep(draft: draft, today: _today)],
      VerificationStep.idPhotos => <Widget>[
        AppCaptureTile(
          key: const Key('verify.idFront'),
          title: l10n.verifyIdFront,
          helperText: l10n.captureDocumentHint,
          icon: Icons.badge_outlined,
          image: draft.idFront,
          actionLabel: draft.idFront == null ? l10n.captureTake : l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => unawaited(_capture(CaptureKind.idFront)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppCaptureTile(
          key: const Key('verify.idBack'),
          title: l10n.verifyIdBack,
          helperText: l10n.captureIdBackHint,
          icon: Icons.flip_outlined,
          image: draft.idBack,
          actionLabel: draft.idBack == null ? l10n.captureTake : l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => unawaited(_capture(CaptureKind.idBack)),
        ),
      ],
      VerificationStep.selfie => <Widget>[
        AppInlineMessage(message: l10n.verifySelfieHowTo, icon: Icons.face_retouching_natural_outlined),
        const SizedBox(height: AppSpacing.s16),
        AppCaptureTile(
          key: const Key('verify.selfie'),
          title: l10n.verifySelfieTile,
          icon: Icons.face_outlined,
          image: draft.selfie,
          actionLabel: draft.selfie == null ? l10n.captureTakeSelfie : l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => unawaited(_capture(CaptureKind.selfie)),
        ),
      ],
      VerificationStep.children => <Widget>[
        if (draft.children.isEmpty)
          AppInlineMessage(message: l10n.verifyChildrenEmpty, icon: Icons.child_care_outlined),
        for (final ChildDraft child in draft.children)
          AppListRow(
            key: Key('verify.child.${child.ref}'),
            title: child.firstName,
            subtitle: '${l10n.childAgeYears(child.age ?? 0)} · ${gradeLabel(l10n, child.grade ?? Grade.g1)} · ${child.schoolName}',
            leadingIcon: Icons.child_care_outlined,
            onTap: () => unawaited(_addOrEditChild(child)),
            trailing: IconButton(
              tooltip: l10n.childRemove,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => unawaited(_removeChild(child)),
            ),
          ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('verify.addChild'),
          label: l10n.childAddTitle,
          icon: Icons.add_rounded,
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: draft.children.length >= VerificationDraftController.maxChildren
              ? null
              : () => unawaited(_addOrEditChild()),
        ),
      ],
      VerificationStep.driving => <Widget>[
        AppCheckRow(
          key: const Key('verify.drives'),
          label: l10n.verifyDrivesLabel,
          helperText: l10n.verifyDrivesHelper,
          value: draft.drives,
          onChanged: (bool v) => _draft.update((VerificationDraft d) => d.copyWith(drives: v)),
        ),
        if (draft.drives) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          DriverForm(value: draft.driver, today: _today, onChanged: _driverChanged),
        ],
      ],
      VerificationStep.review => <Widget>[
        _ReviewSummary(draft: draft),
        const SizedBox(height: AppSpacing.s16),
        AppCheckRow(
          key: const Key('verify.consent'),
          label: l10n.verifyConsentLabel,
          helperText: l10n.verifyConsentHelper,
          value: draft.consent,
          onChanged: _busy ? null : (bool v) => _draft.update((VerificationDraft d) => d.copyWith(consent: v)),
        ),
        if (progress != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          Semantics(
            label: l10n.verifyUploading((progress * 100).round()),
            child: LinearProgressIndicator(value: progress),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(l10n.verifyUploading((progress * 100).round()), style: context.text.bodyMedium),
        ],
      ],
    };

    return SecureScreen(
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop) {
            _back();
          }
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              key: const Key('verify.back'),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const BackButtonIcon(),
              onPressed: _back,
            ),
            title: AppBarTitle(l10n.verifyTitle),
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: AppSpacing.screenPadding,
                    children: <Widget>[
                      AppStepProgress(current: _step.index + 1, total: VerificationStep.values.length),
                      const SizedBox(height: AppSpacing.s24),
                      Semantics(
                        header: true,
                        child: OneLineText(title, style: context.text.headlineSmall, scaleDown: true),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                      Text(
                        body,
                        style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppSpacing.s24),
                      ...content,
                      if (failure != null) ...<Widget>[
                        const SizedBox(height: AppSpacing.s16),
                        AppInlineMessage(
                          key: const Key('verify.failure'),
                          message: failure.message(l10n),
                          tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (!complete) ...<Widget>[
                        Text(
                          last ? l10n.verifyReviewIncomplete : l10n.verifyStepIncomplete,
                          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpacing.s8),
                      ],
                      AppButton(
                        key: const Key('verify.next'),
                        label: last ? l10n.verifySubmit : l10n.actionContinue,
                        expand: true,
                        loading: _busy,
                        onPressed: !complete ? null : (last ? () => unawaited(_submit()) : _next),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Step 1: name as on the ID, the ID number (kept only as a protected
/// code) and the expiry date from the back of the card.
class _DetailsStep extends ConsumerWidget {
  const _DetailsStep({required this.draft, required this.today});

  final VerificationDraft draft;
  final DateTime today;

  static const int _maxIdYears = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final VerificationDraftController controller = ref.read(verificationDraftProvider.notifier);
    String? nameError(String? v) => (v ?? '').trim().isEmpty || isValidPersonName(v ?? '') ? null : l10n.nameErrorInvalid;
    String? idError(String? v) {
      final String text = v ?? '';
      if (text.isEmpty) {
        return null;
      }
      return switch (EgyptNationalId.check(text, today)) {
        null => null,
        NationalIdProblem.length => l10n.idNumberErrorLength,
        NationalIdProblem.invalid => l10n.idNumberErrorInvalid,
        NationalIdProblem.underAge => l10n.idNumberErrorAge,
      };
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          key: const Key('verify.firstName'),
          label: l10n.firstNameLabel,
          helperText: l10n.nameAsOnIdHelper,
          initialValue: draft.firstName,
          prefixIcon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.givenName],
          validator: nameError,
          onChanged: (String v) => controller.update((VerificationDraft d) => d.copyWith(firstName: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('verify.lastName'),
          label: l10n.lastNameLabel,
          helperText: l10n.nameAsOnIdHelper,
          initialValue: draft.lastName,
          prefixIcon: Icons.person_outline_rounded,
          textInputAction: TextInputAction.next,
          autofillHints: const <String>[AutofillHints.familyName],
          validator: nameError,
          onChanged: (String v) => controller.update((VerificationDraft d) => d.copyWith(lastName: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('verify.nationalId'),
          label: l10n.idNumberLabel,
          helperText: l10n.idNumberHelper,
          initialValue: draft.nationalId,
          prefixIcon: Icons.badge_outlined,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          inputFormatters: const <TextInputFormatter>[DigitsInputFormatter(maxDigits: EgyptNationalId.length)],
          validator: idError,
          onChanged: (String v) => controller.update((VerificationDraft d) => d.copyWith(nationalId: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppDateField(
          key: const Key('verify.idExpiry'),
          label: l10n.idExpiryLabel,
          helperText: l10n.idExpiryHelper,
          placeholder: l10n.dateChoose,
          value: draft.idExpiry,
          firstDate: today,
          lastDate: DateTime(today.year + _maxIdYears, today.month, today.day),
          onChanged: (DateTime d) => controller.update((VerificationDraft v) => v.copyWith(idExpiry: d)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppInlineMessage(message: l10n.idPrivacyNote, icon: Icons.lock_outline_rounded),
      ],
    );
  }
}

class _ReviewSummary extends StatelessWidget {
  const _ReviewSummary({required this.draft});

  final VerificationDraft draft;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String id = EgyptNationalId.normalize(draft.nationalId);
    final String masked = id.length < 4 ? id : '•••• ${id.substring(id.length - 4)}';
    final DateTime? expiry = draft.idExpiry;
    return AppCard(
      padding: EdgeInsetsDirectional.zero,
      child: Column(
        children: <Widget>[
          AppListRow(
            title: l10n.verifyReviewName,
            subtitle: '${draft.firstName.trim()} ${draft.lastName.trim()}',
            leadingIcon: Icons.person_outline_rounded,
          ),
          AppListRow(
            title: l10n.idNumberLabel,
            subtitle: '\u2066$masked\u2069',
            leadingIcon: Icons.badge_outlined,
          ),
          AppListRow(
            title: l10n.idExpiryLabel,
            subtitle: expiry == null ? '' : MaterialLocalizations.of(context).formatMediumDate(expiry),
            leadingIcon: Icons.event_outlined,
          ),
          AppListRow(
            title: l10n.verifyReviewPhotos,
            subtitle: l10n.verifyReviewPhotosCount(draft.files().length),
            leadingIcon: Icons.photo_library_outlined,
          ),
          AppListRow(
            title: l10n.verifyChildrenTitle,
            subtitle: draft.children.map((ChildDraft c) => c.firstName.trim()).join(l10n.listSeparator),
            leadingIcon: Icons.child_care_outlined,
          ),
          AppListRow(
            title: l10n.verifyDrivingTitle,
            subtitle: draft.drives ? l10n.verifyReviewDrives : l10n.verifyReviewNoDriving,
            leadingIcon: Icons.directions_car_outlined,
          ),
        ],
      ),
    );
  }
}
