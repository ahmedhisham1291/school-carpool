import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/verification/driver_form.dart';
import 'package:school_carpool/features/verification/review_status_badge.dart';
import 'package:school_carpool/features/verification/screen_security.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_failure.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';

/// Profile > Driving: the car and license on record with their review
/// status, and a form for a verified parent to add or change them (a new
/// car is reviewed again, spec section 3). Before verification, driving
/// details are part of the verification steps.
///
/// States: loading (skeleton), none on record (form only), error and
/// offline (retry), sending (progress), and a note while a review is pending.
class DrivingScreen extends ConsumerStatefulWidget {
  const DrivingScreen({super.key});

  @override
  ConsumerState<DrivingScreen> createState() => _DrivingScreenState();
}

class _DrivingScreenState extends ConsumerState<DrivingScreen> {
  DriverDraft _draft = const DriverDraft();
  bool _editing = false;
  bool _busy = false;
  double? _progress;
  VerificationFailure? _failure;

  DateTime get _today {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> _submit() async {
    final SessionState session = ref.read(sessionProvider);
    final Uint8List? license = _draft.licensePhoto;
    final Uint8List? carLicense = _draft.carLicensePhoto;
    if (session is! SessionSignedIn || license == null || carLicense == null) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String done = context.l10n.drivingSentForReview;
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
        files: <String, Uint8List>{
          VerificationDocument.license.fileName: license,
          VerificationDocument.carLicense.fileName: carLicense,
        },
        payload: <String, Object?>{
          'children': const <Object?>[],
          'driver': _draft.toPayload(),
          'consents': const <String, String>{},
        },
        isUploaded: uploaded.contains,
        markUploaded: uploaded.add,
        forgetUploads: uploaded.removeAll,
        onProgress: (double p) {
          if (mounted) {
            setState(() => _progress = p);
          }
        },
      );
      messenger.showSnackBar(SnackBar(content: Text(done)));
      if (mounted) {
        setState(() {
          _editing = false;
          _draft = const DriverDraft();
        });
      }
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
    final Account? account = accountOf(ref.watch(sessionProvider));
    final AsyncValue<VehicleRecord?> vehicle = ref.watch(vehicleProvider);
    final bool verified = account?.status == AccountStatus.verified;
    final bool locked = account?.reviewPending ?? true;
    final VerificationFailure? failure = _failure;
    final double? progress = _progress;
    void retry() => ref.invalidate(vehicleProvider);

    if (vehicle case AsyncError<VehicleRecord?>(:final Object error)) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.drivingTitle)),
        body: VerificationFailure.from(error).isOffline
            ? OfflineStateView(onRetry: retry)
            : ErrorStateView(onRetry: retry),
      );
    }
    if (vehicle is! AsyncData<VehicleRecord?>) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.drivingTitle)),
        body: const Skeleton(child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow()])),
      );
    }
    final VehicleRecord? car = vehicle.value;
    final bool showForm = verified && !locked && (_editing || car == null);

    final Widget screen = Scaffold(
      appBar: AppBar(title: Semantics(header: true, child: Text(l10n.drivingTitle))),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: AppSpacing.screenPadding,
                children: <Widget>[
                  if (car != null) ...<Widget>[
                    _CarCard(car: car),
                    const SizedBox(height: AppSpacing.s24),
                  ] else if (!showForm)
                    Text(verified ? l10n.drivingNone : l10n.drivingAddInVerification, style: context.text.bodyLarge),
                  if (verified && locked)
                    AppInlineMessage(message: l10n.childrenLockedPending, icon: Icons.hourglass_top_rounded),
                  if (showForm) ...<Widget>[
                    Text(l10n.drivingFormBody, style: context.text.bodyLarge),
                    const SizedBox(height: AppSpacing.s16),
                    DriverForm(value: _draft, today: _today, onChanged: (DriverDraft d) => setState(() => _draft = d)),
                  ],
                  if (failure != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.s16),
                    AppInlineMessage(
                      message: failure.message(l10n),
                      tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
                    ),
                  ],
                  if (progress != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.s16),
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: AppSpacing.s8),
                    Text(l10n.verifyUploading((progress * 100).round()), style: context.text.bodyMedium),
                  ],
                ],
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: switch ((verified, showForm)) {
                (false, _) => AppButton(
                  label: l10n.verifyOpenStatus,
                  expand: true,
                  onPressed: () => context.go(AuthRoutes.verifyAccount),
                ),
                (true, true) => AppButton(
                  key: const Key('driving.submit'),
                  label: l10n.verifySubmit,
                  expand: true,
                  loading: _busy,
                  onPressed: _draft.isComplete(_today) ? () => unawaited(_submit()) : null,
                ),
                (true, false) => AppButton(
                  key: const Key('driving.change'),
                  label: l10n.drivingChange,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: locked ? null : () => setState(() => _editing = true),
                ),
              },
            ),
          ],
        ),
      ),
    );
    // License photos are captured on this screen while the form is open.
    return showForm ? SecureScreen(child: screen) : screen;
  }
}

class _CarCard extends StatelessWidget {
  const _CarCard({required this.car});

  final VehicleRecord car;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final MaterialLocalizations dates = MaterialLocalizations.of(context);
    final DateTime? license = car.licenseExpiry;
    final DateTime? carLicense = car.carLicenseExpiry;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ReviewStatusBadge(status: car.status),
          const SizedBox(height: AppSpacing.s16),
          Text('${car.model} · ${car.color}', style: context.text.titleMedium),
          const SizedBox(height: AppSpacing.s4),
          Text('${l10n.driverPlateLabel}: ${car.plate}', style: context.text.bodyLarge),
          Text(l10n.driverSeatsCount(car.seats), style: context.text.bodyLarge),
          if (license != null)
            Text('${l10n.driverLicenseExpiryLabel}: ${dates.formatMediumDate(license)}', style: context.text.bodyLarge),
          if (carLicense != null)
            Text(
              '${l10n.driverCarLicenseExpiryLabel}: ${dates.formatMediumDate(carLicense)}',
              style: context.text.bodyLarge,
            ),
        ],
      ),
    );
  }
}
