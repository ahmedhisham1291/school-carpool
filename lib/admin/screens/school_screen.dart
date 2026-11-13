import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/geo_pin_input.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _schoolProvider = FutureProvider.autoDispose.family<(School, List<Area>), String>(
  (Ref ref, String id) => ref.watch(adminApiProvider).school(id),
);

/// Add, edit or review one school (F4 data, F14).
///
/// - New (no [schoolId]): names in Arabic and English, governorate, city
///   and the map pin; Save.
/// - Edit: the same, plus the school's areas (add or edit each).
/// - Review ([reviewing], a school typed under "Other"): correct it, then
///   Approve as new (primary) or Merge into an existing school.
///
/// Map: Google Maps for the web is not set up yet (needs a browser key
/// restricted to the panel's domain), so the pin is typed as "latitude,
/// longitude" copied from Google Maps, and a placeholder shows where the
/// map goes.
///
/// States: loading (skeleton), error, offline and not found (retry), each
/// field checked as typed with how to fix it, saving (button spinner),
/// server refusal (message).
class SchoolScreen extends ConsumerWidget {
  const SchoolScreen({super.key, this.schoolId, this.reviewing = false});

  final String? schoolId;
  final bool reviewing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String? id = schoolId;
    final String title = reviewing ? l10n.adminReviewSchoolTitle : (id == null ? l10n.adminNewSchoolTitle : l10n.adminEditSchoolTitle);
    if (id == null) {
      return AdminPage(title: title, body: const _SchoolForm(school: null, areas: <Area>[], reviewing: false));
    }
    return AdminPage(
      title: title,
      body: AdminAsyncView<(School, List<Area>)>(
        value: ref.watch(_schoolProvider(id)),
        onRetry: () => ref.invalidate(_schoolProvider(id)),
        builder: ((School, List<Area>) data) =>
            _SchoolForm(key: ValueKey<String>(data.$1.id), school: data.$1, areas: data.$2, reviewing: reviewing),
      ),
    );
  }
}

class _SchoolForm extends ConsumerStatefulWidget {
  const _SchoolForm({required this.school, required this.areas, required this.reviewing, super.key});

  final School? school;
  final List<Area> areas;
  final bool reviewing;

  @override
  ConsumerState<_SchoolForm> createState() => _SchoolFormState();
}

class _SchoolFormState extends ConsumerState<_SchoolForm> {
  late final TextEditingController _nameAr = TextEditingController(text: widget.school?.nameAr);
  late final TextEditingController _nameEn = TextEditingController(text: widget.school?.nameEn);
  late final TextEditingController _city = TextEditingController(text: widget.school?.city);
  late final TextEditingController _pin = TextEditingController(
    text: widget.school?.pin == null ? '' : formatPin(widget.school!.pin!),
  );
  late String? _governorate = kGovernorates.contains(widget.school?.governorate) ? widget.school!.governorate : null;
  bool _busy = false;
  AdminFailure? _failure;

  @override
  void initState() {
    super.initState();
    for (final TextEditingController c in <TextEditingController>[_nameAr, _nameEn, _city, _pin]) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_nameAr, _nameEn, _city, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() {});

  static bool _nameOk(String v) => v.trim().length >= 2 && v.trim().length <= 120;

  String? _nameError(TextEditingController c) =>
      c.text.isEmpty || _nameOk(c.text) ? null : context.l10n.adminNameError;

  String? get _pinError {
    if (_pin.text.trim().isEmpty) {
      return null;
    }
    return switch (parsePin(_pin.text).$2) {
      PinError.format => context.l10n.adminPinFormatError,
      PinError.outsideEgypt => context.l10n.adminPinEgyptError,
      null => null,
    };
  }

  SchoolInput? get _input {
    final GeoPin? pin = parsePin(_pin.text).$1;
    final String? governorate = _governorate;
    if (!_nameOk(_nameAr.text) || !_nameOk(_nameEn.text) || _city.text.trim().length < 2 || pin == null || governorate == null) {
      return null;
    }
    return SchoolInput(
      id: widget.school?.id,
      nameAr: _nameAr.text.trim(),
      nameEn: _nameEn.text.trim(),
      governorate: governorate,
      city: _city.text.trim(),
      pin: pin,
    );
  }

  Future<void> _run(Future<void> Function() call) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await call();
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

  Future<void> _save(SchoolInput input) => _run(() async {
    final AppLocalizations l10n = context.l10n;
    final AdminApi api = ref.read(adminApiProvider);
    if (widget.reviewing) {
      await api.approveSchool(input);
      if (mounted) {
        adminToast(context, l10n.adminSchoolApproved);
        context.go(AdminRoutes.otherSchools);
      }
      return;
    }
    final String id = await api.saveSchool(input);
    if (mounted) {
      adminToast(context, l10n.adminSaved);
      if (widget.school == null) {
        context.go(AdminRoutes.school(id));
      }
    }
  });

  Future<void> _merge() async {
    final School? school = widget.school;
    if (school == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final School? into = await showAppSheet<School>(
      context: context,
      title: l10n.adminMergeTitle,
      body: _MergePicker(governorate: _governorate ?? school.governorate, excludeId: school.id),
    );
    if (into == null || !mounted) {
      return;
    }
    final bool arabic = Localizations.localeOf(context).languageCode == 'ar';
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.adminMergeConfirmTitle,
      body: l10n.adminMergeConfirmBody(arabic ? into.nameAr : into.nameEn),
      confirmLabel: l10n.adminMerge,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() async {
      await ref.read(adminApiProvider).mergeSchool(schoolId: school.id, intoId: into.id);
      if (mounted) {
        adminToast(context, l10n.adminSchoolMerged);
        context.go(AdminRoutes.otherSchools);
      }
    });
  }

  Future<void> _editArea([Area? area]) async {
    final School? school = widget.school;
    if (school == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    final bool? saved = await showAppSheet<bool>(
      context: context,
      title: area == null ? l10n.adminAddArea : l10n.adminEditArea,
      body: _AreaForm(schoolId: school.id, area: area),
    );
    if ((saved ?? false) && mounted) {
      adminToast(context, l10n.adminSaved);
      ref.invalidate(_schoolProvider(school.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final SchoolInput? input = _input;
    final AdminFailure? failure = _failure;
    final GeoPin? pin = parsePin(_pin.text).$1;
    final bool editing = widget.school != null && !widget.reviewing;
    final bool arabic = Localizations.localeOf(context).languageCode == 'ar';

    return ListView(
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        if (widget.reviewing) ...<Widget>[
          AppInlineMessage(message: l10n.adminReviewSchoolNote, icon: Icons.info_outline),
          const SizedBox(height: AppSpacing.s16),
        ],
        AppTextField(
          key: const Key('school.nameAr'),
          label: l10n.adminNameAr,
          controller: _nameAr,
          textDirection: TextDirection.rtl,
          errorText: _nameError(_nameAr),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('school.nameEn'),
          label: l10n.adminNameEn,
          controller: _nameEn,
          textDirection: TextDirection.ltr,
          errorText: _nameError(_nameEn),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<String>(
          key: const Key('school.governorate'),
          label: l10n.adminGovernorate,
          options: <(String, String)>[for (final String g in kGovernorates) (g, governorateLabel(l10n, g))],
          value: _governorate,
          onChanged: (String g) => setState(() => _governorate = g),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(key: const Key('school.city'), label: l10n.adminCity, controller: _city),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('school.pin'),
          label: l10n.adminPinLabel,
          helperText: l10n.adminPinHelp,
          hintText: l10n.adminPinHint,
          controller: _pin,
          textDirection: TextDirection.ltr,
          errorText: _pinError,
        ),
        const SizedBox(height: AppSpacing.s16),
        _MapPlaceholder(pin: pin),
        if (failure != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(
            message: failure.message(l10n),
            tone: failure.isOffline ? AppStateTone.warning : AppStateTone.error,
          ),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('school.save'),
          label: widget.reviewing ? l10n.adminApproveSchool : l10n.adminSave,
          expand: true,
          loading: _busy,
          onPressed: input != null && !_busy ? () => unawaited(_save(input)) : null,
        ),
        if (widget.reviewing) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('school.merge'),
            label: l10n.adminMergeInto,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: _busy ? null : () => unawaited(_merge()),
          ),
        ],
        if (editing) ...<Widget>[
          const SizedBox(height: AppSpacing.s32),
          Row(
            children: <Widget>[
              Expanded(child: AppSectionHeader(l10n.adminAreas)),
              AppButton(
                key: const Key('school.addArea'),
                label: l10n.adminAddArea,
                icon: Icons.add,
                variant: AppButtonVariant.tertiary,
                onPressed: () => unawaited(_editArea()),
              ),
            ],
          ),
          if (widget.areas.isEmpty)
            AppInlineMessage(message: l10n.adminNoAreas)
          else
            for (final Area a in widget.areas)
              AppListRow(
                key: Key('area.${a.id}'),
                title: arabic ? a.nameAr : a.nameEn,
                subtitle: ltrIsolate(formatPin(a.center)),
                leadingIcon: Icons.place_outlined,
                onTap: () => unawaited(_editArea(a)),
              ),
        ],
      ],
    );
  }
}

/// Where the map goes once Google Maps for the web is set up.
class _MapPlaceholder extends StatelessWidget {
  const _MapPlaceholder({required this.pin});

  final GeoPin? pin;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final GeoPin? p = pin;
    return AppCard(
      semanticLabel: l10n.adminMapPlaceholder,
      child: Row(
        children: <Widget>[
          Icon(p == null ? Icons.location_off_outlined : Icons.location_on, color: context.colors.primary),
          const SizedBox(width: AppSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                OneLine(l10n.adminMapPlaceholder, style: context.text.titleSmall),
                OneLine(
                  p == null ? l10n.adminNoPin : ltrIsolate(formatPin(p)),
                  style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pick the active school a typed one duplicates (same governorate first).
class _MergePicker extends ConsumerStatefulWidget {
  const _MergePicker({required this.governorate, required this.excludeId});

  final String governorate;
  final String excludeId;

  @override
  ConsumerState<_MergePicker> createState() => _MergePickerState();
}

class _MergePickerState extends ConsumerState<_MergePicker> {
  final TextEditingController _filter = TextEditingController();
  late final Future<PagedResult<School>> _schools = ref
      .read(adminApiProvider)
      .schools(status: SchoolStatus.active, governorate: widget.governorate);

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String q = _filter.text.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(label: l10n.adminFilterSchools, controller: _filter, prefixIcon: Icons.search),
        const SizedBox(height: AppSpacing.s8),
        FutureBuilder<PagedResult<School>>(
          future: _schools,
          builder: (BuildContext context, AsyncSnapshot<PagedResult<School>> snap) {
            if (snap.hasError) {
              return AppInlineMessage(message: AdminFailure.from(snap.error!).message(l10n), tone: AppStateTone.error);
            }
            final PagedResult<School>? page = snap.data;
            if (page == null) {
              return const AdminSkeletonList(rows: 3);
            }
            final List<School> shown = page.items
                .where((School s) => s.id != widget.excludeId)
                .where((School s) => q.isEmpty || s.nameAr.contains(q) || s.nameEn.toLowerCase().contains(q))
                .toList();
            if (shown.isEmpty) {
              return AppInlineMessage(message: l10n.adminNoSchoolsFound);
            }
            final bool arabic = Localizations.localeOf(context).languageCode == 'ar';
            return Column(
              children: <Widget>[
                for (final School s in shown)
                  AppListRow(
                    key: Key('merge.${s.id}'),
                    title: arabic ? s.nameAr : s.nameEn,
                    subtitle: s.city,
                    leadingIcon: Icons.school_outlined,
                    onTap: () => Navigator.of(context).pop<School>(s),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Add or edit an area: names and its center pin. Pops true when saved.
class _AreaForm extends ConsumerStatefulWidget {
  const _AreaForm({required this.schoolId, required this.area});

  final String schoolId;
  final Area? area;

  @override
  ConsumerState<_AreaForm> createState() => _AreaFormState();
}

class _AreaFormState extends ConsumerState<_AreaForm> {
  late final TextEditingController _nameAr = TextEditingController(text: widget.area?.nameAr);
  late final TextEditingController _nameEn = TextEditingController(text: widget.area?.nameEn);
  late final TextEditingController _pin = TextEditingController(
    text: widget.area == null ? '' : formatPin(widget.area!.center),
  );
  bool _busy = false;
  AdminFailure? _failure;

  @override
  void initState() {
    super.initState();
    for (final TextEditingController c in <TextEditingController>[_nameAr, _nameEn, _pin]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_nameAr, _nameEn, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(GeoPin center) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await ref
          .read(adminApiProvider)
          .saveArea(
            id: widget.area?.id,
            schoolId: widget.schoolId,
            nameAr: _nameAr.text.trim(),
            nameEn: _nameEn.text.trim(),
            center: center,
          );
      if (mounted) {
        Navigator.of(context).pop<bool>(true);
      }
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (GeoPin? pin, PinError? pinError) = parsePin(_pin.text);
    final bool valid = _nameAr.text.trim().length >= 2 && _nameEn.text.trim().length >= 2 && pin != null;
    final AdminFailure? failure = _failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(label: l10n.adminNameAr, controller: _nameAr, textDirection: TextDirection.rtl),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(label: l10n.adminNameEn, controller: _nameEn, textDirection: TextDirection.ltr),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          label: l10n.adminAreaCenter,
          helperText: l10n.adminPinHelp,
          controller: _pin,
          textDirection: TextDirection.ltr,
          errorText: _pin.text.trim().isEmpty
              ? null
              : switch (pinError) {
                  PinError.format => l10n.adminPinFormatError,
                  PinError.outsideEgypt => l10n.adminPinEgyptError,
                  null => null,
                },
        ),
        if (failure != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(message: failure.message(l10n), tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          label: l10n.adminSave,
          expand: true,
          loading: _busy,
          onPressed: valid && pin != null && !_busy ? () => unawaited(_save(pin)) : null,
        ),
      ],
    );
  }
}
