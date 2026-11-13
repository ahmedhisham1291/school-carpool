import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_models.dart' show GeoPin, kGovernorates;
import 'package:school_carpool/admin/data/geo_pin_input.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart' show governorateLabel;
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Opens the "Other" form and returns the school saved for review, or null.
Future<SchoolOption?> openOtherSchoolForm(BuildContext context, {String name = '', String? governorate}) =>
    Navigator.of(context).push<SchoolOption>(
      MaterialPageRoute<SchoolOption>(
        builder: (BuildContext context) => OtherSchoolScreen(initialName: name, initialGovernorate: governorate),
      ),
    );

/// True when [name] is a usable school name (same rule as the server,
/// functions/src/schools/other.ts).
bool isValidSchoolName(String name) {
  final String trimmed = name.trim();
  return trimmed.length >= 3 &&
      trimmed.length <= 120 &&
      RegExp(r"^[\p{L}\p{M}\p{N} .,'’()&/-]+$", unicode: true).hasMatch(trimmed) &&
      normalizeText(trimmed).replaceAll(' ', '').length >= 3;
}

/// A school missing from the list (F4): its name, governorate and, if the
/// parent wants, a map pin pasted from Google Maps (the map picker comes
/// with Prompt 5). Saved awaiting review, visible only to this parent; the
/// parent picks it for the child and carries on meanwhile.
///
/// One short form (three fields), checked as the parent types. Nothing is
/// loaded, so no loading or empty state; saving shows the button's
/// spinner; errors and no connection appear above the button.
class OtherSchoolScreen extends ConsumerStatefulWidget {
  const OtherSchoolScreen({super.key, this.initialName = '', this.initialGovernorate});

  final String initialName;
  final String? initialGovernorate;

  @override
  ConsumerState<OtherSchoolScreen> createState() => _OtherSchoolScreenState();
}

class _OtherSchoolScreenState extends ConsumerState<OtherSchoolScreen> {
  late String _name = widget.initialName;
  late String? _governorate = widget.initialGovernorate;
  String _pin = '';
  bool _saving = false;
  OtherSchoolFailure? _failure;

  (GeoPin?, PinError?) get _parsedPin => _pin.trim().isEmpty ? (null, null) : parsePin(_pin);

  bool get _ready => isValidSchoolName(_name) && _governorate != null && _parsedPin.$2 == null;

  Future<void> _save() async {
    final String? governorate = _governorate;
    if (!_ready || governorate == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      final SchoolOption school = await ref
          .read(schoolRepositoryProvider)
          .addOther(name: _name, governorate: governorate, pin: _parsedPin.$1);
      showAppSnackBarOn(messenger, l10n.otherSchoolAdded);
      navigator.pop(school);
    } on OtherSchoolFailure catch (failure) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final OtherSchoolFailure? failure = _failure;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.otherSchoolTitle)),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: AppSpacing.screenPadding,
                children: <Widget>[
                  Text(l10n.otherSchoolBody, style: context.text.bodyLarge),
                  const SizedBox(height: AppSpacing.s24),
                  AppTextField(
                    key: const Key('other.name'),
                    label: l10n.otherSchoolNameLabel,
                    helperText: l10n.otherSchoolNameHelper,
                    initialValue: _name,
                    prefixIcon: Icons.school_outlined,
                    textInputAction: TextInputAction.next,
                    validator: (String? v) =>
                        (v ?? '').trim().isEmpty || isValidSchoolName(v ?? '') ? null : l10n.otherSchoolNameError,
                    onChanged: (String v) => setState(() => _name = v),
                  ),
                  const SizedBox(height: AppSpacing.s16),
                  AppSelectField<String>(
                    key: const Key('other.governorate'),
                    label: l10n.otherSchoolGovernorateLabel,
                    value: _governorate,
                    options: <(String, String)>[for (final String g in kGovernorates) (g, governorateLabel(l10n, g))],
                    onChanged: (String v) => setState(() => _governorate = v),
                  ),
                  const SizedBox(height: AppSpacing.s16),
                  AppTextField(
                    key: const Key('other.pin'),
                    label: l10n.otherSchoolPinLabel,
                    helperText: l10n.otherSchoolPinHelper(ltrIsolate('30.0444, 31.2357')),
                    prefixIcon: Icons.place_outlined,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    textDirection: TextDirection.ltr,
                    validator: (String? v) => switch ((v ?? '').trim().isEmpty ? null : parsePin(v ?? '').$2) {
                      null => null,
                      PinError.format => l10n.otherSchoolPinErrorFormat,
                      PinError.outsideEgypt => l10n.otherSchoolPinErrorOutside,
                    },
                    onChanged: (String v) => setState(() => _pin = v),
                  ),
                ],
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (failure != null) ...<Widget>[
                    AppInlineMessage(
                      key: const Key('other.error'),
                      message: failure.message(l10n),
                      tone: AppStateTone.error,
                      icon: failure.isOffline ? Icons.cloud_off_rounded : null,
                    ),
                    const SizedBox(height: AppSpacing.s8),
                  ] else if (!_ready) ...<Widget>[
                    Text(
                      l10n.otherSchoolIncomplete,
                      style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                  ],
                  AppButton(
                    key: const Key('other.save'),
                    label: l10n.otherSchoolSave,
                    expand: true,
                    loading: _saving,
                    onPressed: _ready ? () => unawaited(_save()) : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
