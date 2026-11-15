
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_models.dart' show kGovernorates;
import 'package:school_carpool/admin/widgets/admin_labels.dart' show governorateLabel;
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/places/place_models.dart';
import 'package:school_carpool/features/places/place_repository.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _areasProvider = FutureProvider.autoDispose.family<List<PlaceArea>, String>(
  (Ref ref, String governorate) => ref.watch(placeRepositoryProvider).areas(governorate),
);

final _schoolsProvider = FutureProvider.autoDispose.family<List<SchoolOption>, String>(
  (Ref ref, String areaId) => ref.watch(placeRepositoryProvider).schoolsInArea(areaId),
);

/// Opens "Browse by area" and returns the chosen school, or null.
Future<SchoolOption?> openBrowseSchools(BuildContext context, {String? governorate}) => Navigator.of(context).push<SchoolOption>(
  MaterialPageRoute<SchoolOption>(builder: (BuildContext context) => BrowseSchoolsScreen(initialGovernorate: governorate)),
);

/// Browse schools by City -> Area (F4): two filterable dropdowns (the Area
/// list waits for the City; a new City clears the Area), then the area's
/// schools in alphabetical order (the app's language, Arabic by default).
/// Search stays the main way to find a school; this is the second path.
///
/// States: no city yet (hint), areas loading (dropdown disabled, "Loading
/// areas"), no areas for the city (hint to search), schools loading
/// (skeleton rows), no schools in the area (empty view), error and offline
/// (with retry), and a note when the area has more schools than the list
/// shows (search finds the rest).
class BrowseSchoolsScreen extends ConsumerStatefulWidget {
  const BrowseSchoolsScreen({super.key, this.initialGovernorate});

  final String? initialGovernorate;

  @override
  ConsumerState<BrowseSchoolsScreen> createState() => _BrowseSchoolsScreenState();
}

class _BrowseSchoolsScreenState extends ConsumerState<BrowseSchoolsScreen> {
  late String? _city = widget.initialGovernorate;
  String? _areaId;

  void _pickCity(String city) {
    if (city == _city) {
      return;
    }
    // A new city clears the area (and its schools).
    setState(() {
      _city = city;
      _areaId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final String? city = _city;
    final String? areaId = _areaId;
    final AsyncValue<List<PlaceArea>>? areas = city == null ? null : ref.watch(_areasProvider(city));
    final List<PlaceArea> areaList = sortByName(areas?.value ?? const <PlaceArea>[], (PlaceArea a) => a.name(language));

    final String? areaHelper = switch (areas) {
      null => l10n.placeAreaWaitCity,
      AsyncLoading<List<PlaceArea>>() => l10n.placeAreasLoading,
      AsyncError<List<PlaceArea>>() => null,
      AsyncData<List<PlaceArea>>(:final List<PlaceArea> value) when value.isEmpty => l10n.placeAreasNone,
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.schoolBrowseTitle)),
      body: SafeArea(
        top: false,
        child: ListView(
          key: const Key('browse.list'),
          padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AppDropdownMenu<String>(
                    key: const Key('browse.city'),
                    label: l10n.placeCityLabel,
                    hintText: l10n.placeCityHint,
                    leadingIcon: Icons.location_city_outlined,
                    value: city,
                    items: sortByName(
                      <AppDropdownItem<String>>[for (final String g in kGovernorates) AppDropdownItem<String>(g, governorateLabel(l10n, g))],
                      (AppDropdownItem<String> i) => i.label,
                    ),
                    onSelected: _pickCity,
                  ),
                  const SizedBox(height: AppSpacing.s16),
                  AppDropdownMenu<String>(
                    // A new city builds a new, empty Area menu.
                    key: Key('browse.area.${city ?? ''}'),
                    label: l10n.placeAreaLabel,
                    hintText: l10n.placeAreaHint,
                    helperText: areaHelper,
                    leadingIcon: Icons.map_outlined,
                    value: areaId,
                    items: <AppDropdownItem<String>>[for (final PlaceArea a in areaList) AppDropdownItem<String>(a.id, a.name(language))],
                    onSelected: areaList.isEmpty ? null : (String id) => setState(() => _areaId = id),
                  ),
                  if (areas is AsyncError<List<PlaceArea>>) ...<Widget>[
                    const SizedBox(height: AppSpacing.s8),
                    _RetryMessage(
                      offline: PlaceFailure.from(areas.error).isOffline,
                      onRetry: () => ref.invalidate(_areasProvider(city!)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            if (city == null || areaId == null)
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                child: Text(
                  l10n.schoolBrowseHint,
                  key: const Key('browse.hint'),
                  style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              )
            else
              _AreaSchools(
                areaId: areaId,
                area: areaList.where((PlaceArea a) => a.id == areaId).firstOrNull,
              ),
          ],
        ),
      ),
    );
  }
}

class _AreaSchools extends ConsumerWidget {
  const _AreaSchools({required this.areaId, required this.area});

  final String areaId;
  final PlaceArea? area;

  static const double _stateHeight = AppSpacing.s64 * 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final AsyncValue<List<SchoolOption>> schools = ref.watch(_schoolsProvider(areaId));
    void retry() => ref.invalidate(_schoolsProvider(areaId));
    return switch (schools) {
      AsyncData<List<SchoolOption>>(:final List<SchoolOption> value) when value.isEmpty => SizedBox(
        height: _stateHeight,
        child: EmptyStateView(
          key: const Key('browse.empty'),
          icon: Icons.school_outlined,
          title: l10n.schoolBrowseEmptyTitle,
          body: l10n.schoolBrowseEmptyBody,
        ),
      ),
      AsyncData<List<SchoolOption>>(:final List<SchoolOption> value) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSectionHeader(l10n.schoolBrowseCount(value.length)),
          for (final SchoolOption s in sortByName(value, (SchoolOption s) => s.name(language)))
            AppListRow(
              key: Key('browse.school.${s.id}'),
              title: s.name(language),
              subtitle: s.place(language).isEmpty ? null : s.place(language),
              leadingIcon: Icons.school_outlined,
              onTap: () => Navigator.of(context).pop(s),
            ),
          if (value.length >= kAreaSchoolsLimit || (area?.schoolCount ?? 0) > value.length)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: AppInlineMessage(key: const Key('browse.more'), message: l10n.schoolBrowseMore),
            ),
        ],
      ),
      AsyncError<List<SchoolOption>>(:final Object error) when PlaceFailure.from(error).isOffline =>
        SizedBox(height: _stateHeight, child: OfflineStateView(onRetry: retry)),
      AsyncError<List<SchoolOption>>() => SizedBox(height: _stateHeight, child: ErrorStateView(onRetry: retry)),
      _ => const Skeleton(
        key: Key('browse.loading'),
        child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()]),
      ),
    };
  }
}

class _RetryMessage extends StatelessWidget {
  const _RetryMessage({required this.offline, required this.onRetry});

  final bool offline;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Row(
      children: <Widget>[
        Expanded(
          child: AppInlineMessage(
            key: const Key('places.error'),
            message: offline ? l10n.errorOfflineShort : l10n.placeLoadError,
            tone: AppStateTone.error,
          ),
        ),
        const SizedBox(width: AppSpacing.s8),
        AppButton(label: l10n.actionRetry, variant: AppButtonVariant.tertiary, onPressed: onRetry),
      ],
    );
  }
}
