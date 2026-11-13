import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/my_schools.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_picker_screen.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Most driving schools (same as MAX_DRIVING_SCHOOLS on the server).
const int kMaxDrivingSchools = 5;

/// "My driving schools" (F24): every school the parent can drive to,
/// besides their children's schools. Parents of these schools see them on
/// the nearby map and they can open those maps. Picked with the school
/// picker (search, nearest first, or the map). Saved at once.
///
/// States: loading (skeleton rows), empty (no extra school yet: a short
/// note above "Add school"), error and offline (full screen with retry).
class DrivingSchoolsScreen extends ConsumerStatefulWidget {
  const DrivingSchoolsScreen({super.key});

  @override
  ConsumerState<DrivingSchoolsScreen> createState() => _DrivingSchoolsScreenState();
}

class _DrivingSchoolsScreenState extends ConsumerState<DrivingSchoolsScreen> {
  bool _saving = false;

  Future<void> _save(List<SchoolRef> next) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(mapRepositoryProvider).setDrivingSchools(<String>[for (final SchoolRef s in next) s.id]);
      showAppSnackBarOn(messenger, l10n.drivingSchoolsSaved);
    } on MapFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _add(List<SchoolRef> current, List<MySchool> mine) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final SchoolOption? picked = await openSchoolPicker(context);
    if (picked == null || !mounted) {
      return;
    }
    if (picked.pending) {
      showAppSnackBarOn(messenger, l10n.drivingSchoolsPendingNo);
      return;
    }
    if (mine.any((MySchool s) => s.id == picked.id)) {
      showAppSnackBarOn(messenger, l10n.drivingSchoolsAlready);
      return;
    }
    await _save(<SchoolRef>[...current, SchoolRef(id: picked.id, nameAr: picked.nameAr, nameEn: picked.nameEn)]);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final AsyncValue<List<MySchool>> schools = ref.watch(mySchoolsProvider);
    final List<SchoolRef> driving = ref.watch(myHomeProvider).value?.drivingSchools ?? const <SchoolRef>[];
    void retry() {
      ref
        ..invalidate(myHomeProvider)
        ..invalidate(childrenProvider);
    }

    final List<Widget> body = switch (schools) {
      AsyncData<List<MySchool>>(:final List<MySchool> value) => <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
          child: Text(
            l10n.drivingSchoolsIntro,
            style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
        if (value.any((MySchool s) => s.fromChild)) ...<Widget>[
          AppSectionHeader(l10n.drivingSchoolsChildrenSection),
          for (final MySchool s in value.where((MySchool s) => s.fromChild))
            AppListRow(
              key: Key('driving.child.${s.id}'),
              title: s.name(language),
              subtitle: l10n.drivingSchoolsFromChild,
              leadingIcon: Icons.child_care_outlined,
            ),
        ],
        AppSectionHeader(l10n.drivingSchoolsOtherSection),
        if (driving.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
            child: Text(
              l10n.drivingSchoolsEmpty,
              key: const Key('driving.empty'),
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        for (final SchoolRef s in driving)
          AppListRow(
            key: Key('driving.school.${s.id}'),
            title: s.name(language),
            leadingIcon: Icons.school_outlined,
            trailing: IconButton(
              key: Key('driving.remove.${s.id}'),
              tooltip: l10n.drivingSchoolsRemove,
              icon: const Icon(Icons.close_rounded),
              onPressed: _saving
                  ? null
                  : () => unawaited(_save(<SchoolRef>[
                      for (final SchoolRef x in driving)
                        if (x.id != s.id) x,
                    ])),
            ),
          ),
        if (driving.length < kMaxDrivingSchools)
          AppListRow(
            key: const Key('driving.add'),
            title: l10n.drivingSchoolsAdd,
            leadingIcon: Icons.add_rounded,
            onTap: _saving ? null : () => unawaited(_add(driving, value)),
          )
        else
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
            child: AppInlineMessage(message: l10n.drivingSchoolsMax(kMaxDrivingSchools)),
          ),
        if (_saving) const Padding(padding: AppSpacing.screenPadding, child: LinearProgressIndicator()),
      ],
      AsyncError<List<MySchool>>(:final Object error) when MapFailure.from(error).isOffline => <Widget>[
        SizedBox(height: _stateHeight, child: OfflineStateView(onRetry: retry)),
      ],
      AsyncError<List<MySchool>>() => <Widget>[
        SizedBox(height: _stateHeight, child: ErrorStateView(onRetry: retry)),
      ],
      _ => const <Widget>[
        Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()])),
      ],
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.drivingSchoolsTitle)),
      body: ListView(
        key: const Key('driving.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: body,
      ),
    );
  }

  static const double _stateHeight = AppSpacing.s64 * 6;
}
