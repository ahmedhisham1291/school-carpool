import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Driver's license and car details (spec section 3, step 6): plate,
/// model, color, passenger seats, both expiry dates and photos of the
/// driver's license and the car license. Used in the first verification
/// and on Profile > Driving. Only the expiry dates and car details are
/// kept after review; the photos are deleted.
class DriverForm extends ConsumerWidget {
  const DriverForm({required this.value, required this.onChanged, required this.today, super.key});

  final DriverDraft value;
  final ValueChanged<DriverDraft> onChanged;
  final DateTime today;

  static const int maxSeats = 8;
  static const int maxYears = 15;

  Future<void> _capture(BuildContext context, WidgetRef ref, CaptureKind kind) async {
    final CaptureLauncher launch = ref.read(captureLauncherProvider);
    final CaptureResult? result = await launch(context, CaptureRequest(kind));
    if (result == null) {
      return;
    }
    onChanged(
      kind == CaptureKind.license
          ? value.copyWith(licensePhoto: result.image)
          : value.copyWith(carLicensePhoto: result.image),
    );
  }

  String? _textError(AppLocalizations l10n, String? text, int max) {
    final String v = text ?? '';
    return v.trim().isEmpty || isValidFreeText(v, min: 2, max: max) ? null : l10n.textErrorInvalid;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final DateTime last = DateTime(today.year + maxYears, today.month, today.day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          key: const Key('driver.plate'),
          label: l10n.driverPlateLabel,
          helperText: l10n.driverPlateHelper,
          initialValue: value.plate,
          prefixIcon: Icons.pin_outlined,
          validator: (String? v) => _textError(l10n, v, 20),
          onChanged: (String v) => onChanged(value.copyWith(plate: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('driver.model'),
          label: l10n.driverModelLabel,
          helperText: l10n.driverModelHelper,
          initialValue: value.model,
          prefixIcon: Icons.directions_car_outlined,
          validator: (String? v) => _textError(l10n, v, 40),
          onChanged: (String v) => onChanged(value.copyWith(model: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('driver.color'),
          label: l10n.driverColorLabel,
          initialValue: value.color,
          prefixIcon: Icons.palette_outlined,
          validator: (String? v) => _textError(l10n, v, 30),
          onChanged: (String v) => onChanged(value.copyWith(color: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<int>(
          key: const Key('driver.seats'),
          label: l10n.driverSeatsLabel,
          helperText: l10n.driverSeatsHelper,
          value: value.seats,
          options: <(int, String)>[for (int n = 1; n <= maxSeats; n++) (n, l10n.driverSeatsCount(n))],
          onChanged: (int v) => onChanged(value.copyWith(seats: v)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppDateField(
          key: const Key('driver.licenseExpiry'),
          label: l10n.driverLicenseExpiryLabel,
          placeholder: l10n.dateChoose,
          value: value.licenseExpiry,
          firstDate: today,
          lastDate: last,
          onChanged: (DateTime d) => onChanged(value.copyWith(licenseExpiry: d)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppDateField(
          key: const Key('driver.carLicenseExpiry'),
          label: l10n.driverCarLicenseExpiryLabel,
          placeholder: l10n.dateChoose,
          value: value.carLicenseExpiry,
          firstDate: today,
          lastDate: last,
          onChanged: (DateTime d) => onChanged(value.copyWith(carLicenseExpiry: d)),
        ),
        const SizedBox(height: AppSpacing.s24),
        AppCaptureTile(
          key: const Key('driver.licenseTile'),
          title: l10n.driverLicensePhotoTitle,
          helperText: l10n.captureDocumentHint,
          icon: Icons.credit_card_outlined,
          image: value.licensePhoto,
          actionLabel: value.licensePhoto == null ? l10n.captureTake : l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => unawaited(_capture(context, ref, CaptureKind.license)),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppCaptureTile(
          key: const Key('driver.carLicenseTile'),
          title: l10n.driverCarLicensePhotoTitle,
          helperText: l10n.captureDocumentHint,
          icon: Icons.description_outlined,
          image: value.carLicensePhoto,
          actionLabel: value.carLicensePhoto == null ? l10n.captureTake : l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => unawaited(_capture(context, ref, CaptureKind.carLicense)),
        ),
      ],
    );
  }
}
