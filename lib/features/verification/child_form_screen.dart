import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_picker_screen.dart';
import 'package:school_carpool/features/verification/capture_screen.dart';
import 'package:school_carpool/features/verification/screen_security.dart';
import 'package:school_carpool/features/verification/verification_draft.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Opens the child form and returns the child, or null when cancelled.
Future<ChildDraft?> openChildForm(BuildContext context, ChildDraft initial) => Navigator.of(context).push<ChildDraft>(
  MaterialPageRoute<ChildDraft>(builder: (BuildContext context) => ChildFormScreen(initial: initial)),
);

/// Child details with a photo of the school ID card (spec section 3, step
/// 5; F3). Uses the school ID card, never the child's national ID or birth
/// certificate. The school comes from the schools list (F4), or is added
/// under "Other" and picked while it awaits review.
///
/// One screen with a few fields, checked as the parent types; the button
/// stays off and says what is missing. No loading, empty or offline state:
/// nothing is loaded or sent here (the caller uploads).
class ChildFormScreen extends ConsumerStatefulWidget {
  const ChildFormScreen({required this.initial, super.key});

  final ChildDraft initial;

  @override
  ConsumerState<ChildFormScreen> createState() => _ChildFormScreenState();
}

class _ChildFormScreenState extends ConsumerState<ChildFormScreen> {
  late ChildDraft _child = widget.initial;

  static const int _minAge = 2;
  static const int _maxAge = 19;

  /// The school as picked in this session (to show "awaiting review").
  SchoolOption? _school;

  void _set({String? firstName, int? age, Grade? grade, SchoolOption? school, Uint8List? photo}) => setState(() {
    final String language = Localizations.localeOf(context).languageCode;
    _school = school ?? _school;
    _child = ChildDraft(
      ref: _child.ref,
      childId: _child.childId,
      firstName: firstName ?? _child.firstName,
      age: age ?? _child.age,
      grade: grade ?? _child.grade,
      schoolId: school?.id ?? _child.schoolId,
      schoolName: school?.name(language) ?? _child.schoolName,
      schoolIdPhoto: photo ?? _child.schoolIdPhoto,
    );
  });

  Future<void> _pickSchool() async {
    final SchoolOption? school = await openSchoolPicker(context);
    if (school != null && mounted) {
      _set(school: school);
    }
  }

  Future<void> _capture() async {
    final CaptureLauncher launch = ref.read(captureLauncherProvider);
    final CaptureResult? result = await launch(context, const CaptureRequest(CaptureKind.schoolId));
    if (result != null && mounted) {
      _set(photo: result.image);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final bool editing = widget.initial.firstName.isNotEmpty;
    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(title: AppBarTitle(editing ? l10n.childEditTitle : l10n.childAddTitle)),
        body: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: AppSpacing.screenPadding,
                  children: <Widget>[
                    Text(l10n.childFormBody, style: context.text.bodyLarge),
                    const SizedBox(height: AppSpacing.s24),
                    AppTextField(
                      key: const Key('child.firstName'),
                      label: l10n.childFirstNameLabel,
                      helperText: l10n.childFirstNameHelper,
                      initialValue: _child.firstName,
                      prefixIcon: Icons.person_outline_rounded,
                      textInputAction: TextInputAction.next,
                      validator: (String? v) =>
                          (v ?? '').trim().isEmpty || isValidPersonName(v ?? '') ? null : l10n.nameErrorInvalid,
                      onChanged: (String v) => _set(firstName: v),
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AppSelectField<int>(
                      key: const Key('child.age'),
                      label: l10n.childAgeLabel,
                      value: _child.age,
                      options: <(int, String)>[
                        for (int age = _minAge; age <= _maxAge; age++) (age, l10n.childAgeYears(age)),
                      ],
                      onChanged: (int v) => _set(age: v),
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AppSelectField<Grade>(
                      key: const Key('child.grade'),
                      label: l10n.childGradeLabel,
                      value: _child.grade,
                      options: <(Grade, String)>[for (final Grade g in Grade.values) (g, gradeLabel(l10n, g))],
                      onChanged: (Grade v) => _set(grade: v),
                    ),
                    const SizedBox(height: AppSpacing.s16),
                    AppPickerField(
                      key: const Key('child.school'),
                      label: l10n.childSchoolLabel,
                      placeholder: l10n.childSchoolPlaceholder,
                      helperText: _school?.pending ?? false ? l10n.childSchoolPendingHelper : l10n.childSchoolHelper,
                      prefixIcon: Icons.school_outlined,
                      // A child from before the schools list has a name but no school: pick again.
                      value: _child.schoolId.isEmpty ? null : _child.schoolName,
                      onTap: () => unawaited(_pickSchool()),
                    ),
                    const SizedBox(height: AppSpacing.s24),
                    AppCaptureTile(
                      key: const Key('child.schoolIdTile'),
                      title: l10n.childSchoolIdTitle,
                      helperText: l10n.childSchoolIdHelper,
                      icon: Icons.badge_outlined,
                      image: _child.schoolIdPhoto,
                      actionLabel: _child.schoolIdPhoto == null ? l10n.captureTake : l10n.captureRetake,
                      doneLabel: l10n.captureDone,
                      todoLabel: l10n.captureTodo,
                      onCapture: () => unawaited(_capture()),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: AppSpacing.screenPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (!_child.isComplete) ...<Widget>[
                      Text(
                        l10n.childFormIncomplete,
                        style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                    ],
                    AppButton(
                      key: const Key('child.save'),
                      label: l10n.childSave,
                      expand: true,
                      onPressed: _child.isComplete ? () => Navigator.of(context).pop(_child) : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
