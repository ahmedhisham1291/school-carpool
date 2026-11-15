import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/admin_places.dart';
import 'package:school_carpool/admin/data/school_filters.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/places/place_models.dart' show sortByName;
import 'package:school_carpool/l10n/l10n.dart';

/// A paged list of schools by status, with an optional governorate filter
/// (the "Other" schools queue). The Schools page uses [SchoolsScreen].
class SchoolList extends ConsumerStatefulWidget {
  const SchoolList({required this.status, required this.onOpen, required this.empty, super.key});

  final SchoolStatus status;
  final ValueChanged<School> onOpen;
  final Widget empty;

  @override
  ConsumerState<SchoolList> createState() => _SchoolListState();
}

class _SchoolListState extends ConsumerState<SchoolList> {
  String? _governorate;

  /// City -> Area filter (placeAreas): loaded when a city is chosen.
  String? _areaId;
  List<AdminPlace> _areas = const <AdminPlace>[];

  Future<void> _loadAreas(String? governorate) async {
    setState(() {
      _areas = const <AdminPlace>[];
      _areaId = null;
    });
    if (governorate == null) {
      return;
    }
    try {
      final List<AdminPlace> areas = await ref.read(adminPlacesApiProvider).areas(governorate);
      if (mounted && governorate == _governorate) {
        setState(() => _areas = areas);
      }
    } on Object {
      // The area filter is optional: the list still works by city.
    }
  }
  AsyncValue<List<School>> _schools = const AsyncLoading<List<School>>();
  String? _next;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _schools = const AsyncLoading<List<School>>();
        _next = null;
      }
    });
    try {
      final PagedResult<School> page = await ref
          .read(adminApiProvider)
          .schools(status: widget.status, governorate: _governorate, afterId: more ? _next : null, placeAreaId: _areaId);
      if (!mounted) {
        return;
      }
      setState(() {
        final List<School> before = more ? (_schools.value ?? const <School>[]) : const <School>[];
        _schools = AsyncData<List<School>>(<School>[...before, ...page.items]);
        _next = page.nextAfterId;
      });
    } on AdminFailure catch (failure, stack) {
      if (mounted) {
        setState(() => _schools = AsyncError<List<School>>(failure, stack));
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          // '' stands for every governorate (the field takes no null choice).
          child: AppSelectField<String>(
            key: const Key('schools.governorate'),
            label: l10n.adminGovernorate,
            options: <(String, String)>[
              ('', l10n.adminAllGovernorates),
              for (final String g in kGovernorates) (g, governorateLabel(l10n, g)),
            ],
            value: _governorate ?? '',
            onChanged: (String g) {
              setState(() => _governorate = g.isEmpty ? null : g);
              unawaited(_loadAreas(_governorate));
              unawaited(_load());
            },
          ),
        ),
        if (_governorate != null && _areas.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s16),
            // '' stands for every area of the city.
            child: AppSelectField<String>(
              key: const Key('schools.area'),
              label: l10n.placeAreaLabel,
              options: <(String, String)>[
                ('', l10n.adminAllAreas),
                for (final AdminPlace a in sortByName(_areas, (AdminPlace a) => a.name(Localizations.localeOf(context).languageCode)))
                  (a.id, a.name(Localizations.localeOf(context).languageCode)),
              ],
              value: _areaId ?? '',
              onChanged: (String id) {
                setState(() => _areaId = id.isEmpty ? null : id);
                unawaited(_load());
              },
            ),
          ),
        Expanded(
          child: AdminAsyncView<List<School>>(
            value: _schools,
            onRetry: () => unawaited(_load()),
            isEmpty: (List<School> s) => s.isEmpty,
            empty: widget.empty,
            builder: (List<School> schools) => ListView.builder(
              itemCount: schools.length + (_next == null ? 0 : 1),
              itemBuilder: (BuildContext context, int i) {
                if (i == schools.length) {
                  return Padding(
                    padding: AppSpacing.screenPadding,
                    child: AppButton(
                      label: l10n.adminLoadMore,
                      variant: AppButtonVariant.tertiary,
                      loading: _loadingMore,
                      onPressed: () => unawaited(_load(more: true)),
                    ),
                  );
                }
                final School s = schools[i];
                final bool arabic = Localizations.localeOf(context).languageCode == 'ar';
                return AppListRow(
                  key: Key('schools.${s.id}'),
                  title: arabic ? s.nameAr : s.nameEn,
                  subtitle: <String>[
                    governorateLabel(l10n, s.governorate),
                    // The Area column (City -> Area); "no area" when unknown.
                    if (arabic ? s.placeAreaNameAr : s.placeAreaNameEn case final String area when area.isNotEmpty)
                      area
                    else
                      l10n.adminNoArea,
                    if (s.city.isNotEmpty) s.city,
                  ].join(' · '),
                  leadingIcon: s.pin == null ? Icons.location_off_outlined : Icons.location_on_outlined,
                  onTap: () => widget.onOpen(s),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Schools and areas (F4 data, F14): search every school by name (Arabic
/// or English, spelling variants and small typos), filter by City -> Area
/// -> District and, with "Show hidden and unapproved", by status,
/// visibility and source; open one to edit it, or add a new school (the
/// one primary action). The filters live in the URL ([SchoolFilters]), so
/// a filtered view can be bookmarked.
///
/// States: loading (skeleton), empty ("No schools match" + clear filters,
/// or "No schools yet"), error and offline (retry).
class SchoolsScreen extends ConsumerStatefulWidget {
  const SchoolsScreen({super.key, this.filters = const SchoolFilters()});

  final SchoolFilters filters;

  @override
  ConsumerState<SchoolsScreen> createState() => _SchoolsScreenState();
}

/// The width of one filter field (the fields wrap on narrow screens).
const double _fieldWidth = AppSpacing.s64 * 4;

/// From this width the results are a table; below it, list rows.
const double _tableBreakpoint = AppSpacing.maxContentWidth;

/// Wait this long after the last key before searching.
const Duration _typingPause = Duration(milliseconds: 400);

class _SchoolsScreenState extends ConsumerState<SchoolsScreen> {
  late final TextEditingController _query = TextEditingController(text: widget.filters.query);
  Timer? _debounce;
  bool _started = false;

  AsyncValue<List<School>> _schools = const AsyncLoading<List<School>>();
  SchoolSearchPage? _firstPage;
  String? _next;
  bool _loadingMore = false;

  /// Answers to an older search are dropped.
  int _generation = 0;

  /// Sources seen in the results, offered in the source filter.
  final Set<String> _seenSources = <String>{};

  String? _areasFor;
  Future<List<AdminPlace>>? _areas;
  String? _districtsFor;
  Future<List<AdminPlace>>? _districts;

  SchoolFilters get _filters => widget.filters;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load(fromLifecycle: true));
    }
  }

  @override
  void didUpdateWidget(SchoolsScreen old) {
    super.didUpdateWidget(old);
    if (old.filters != widget.filters) {
      // Back, forward or a bookmark: the field shows the URL's text.
      if (_query.text.trim() != widget.filters.query.trim()) {
        _query.text = widget.filters.query;
      }
      unawaited(_load(fromLifecycle: true));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Puts [next] in the URL; the router rebuilds this screen with it.
  void _apply(SchoolFilters next) {
    _debounce?.cancel();
    if (next == _filters) {
      return;
    }
    final Map<String, String> query = next.toQuery();
    context.go(Uri(path: AdminRoutes.schools, queryParameters: query.isEmpty ? null : query).toString());
  }

  void _typed(String text) {
    _debounce?.cancel();
    _debounce = Timer(_typingPause, () {
      if (mounted) {
        _apply(_filters.withQuery(text));
      }
    });
  }

  void _clearAll() {
    _query.clear();
    _apply(_filters.cleared());
  }

  /// [fromLifecycle]: called while the framework is about to build anyway
  /// (first build, new URL), so the fields are set without setState.
  Future<void> _load({bool more = false, bool fromLifecycle = false}) async {
    final int generation = more ? _generation : ++_generation;
    final String language = Localizations.localeOf(context).languageCode;
    void reset() {
      if (more) {
        _loadingMore = true;
      } else {
        _schools = const AsyncLoading<List<School>>();
        _firstPage = null;
        _next = null;
      }
    }

    if (fromLifecycle) {
      reset();
    } else {
      setState(reset);
    }
    try {
      final SchoolSearchPage page = await ref
          .read(adminApiProvider)
          .searchSchools(_filters, languageCode: language, afterId: more ? _next : null);
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        final List<School> before = more ? (_schools.value ?? const <School>[]) : const <School>[];
        _schools = AsyncData<List<School>>(<School>[...before, ...page.items]);
        if (!more) {
          _firstPage = page;
        }
        _next = page.nextAfterId;
        _seenSources.addAll(page.items.map((School s) => s.source).where((String s) => s.isNotEmpty));
      });
    } on AdminFailure catch (failure, stack) {
      if (mounted && generation == _generation) {
        setState(() => _schools = AsyncError<List<School>>(failure, stack));
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<List<AdminPlace>> _areasOf(String city) {
    if (_areasFor != city || _areas == null) {
      _areasFor = city;
      _areas = ref.read(adminPlacesApiProvider).areas(city);
    }
    return _areas!;
  }

  Future<List<AdminPlace>> _districtsOf(String areaId) {
    if (_districtsFor != areaId || _districts == null) {
      _districtsFor = areaId;
      _districts = ref.read(adminPlacesApiProvider).districts(areaId);
    }
    return _districts!;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AdminPage(
      title: l10n.adminSchoolsTitle,
      actions: <Widget>[
        AppButton(
          key: const Key('schools.add'),
          label: l10n.adminAddSchool,
          icon: Icons.add,
          onPressed: () => context.go(AdminRoutes.newSchool),
        ),
      ],
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool table = constraints.maxWidth >= _tableBreakpoint;
          return CustomScrollView(
            key: const Key('schools.scroll'),
            slivers: <Widget>[
              SliverToBoxAdapter(child: _filterBar(context, constraints.maxWidth)),
              SliverToBoxAdapter(child: _summary(context)),
              ..._results(context, table: table),
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.s32)),
            ],
          );
        },
      ),
    );
  }

  Widget _field(double maxWidth, Widget child) =>
      SizedBox(width: maxWidth < _fieldWidth + AppSpacing.screenGutter * 2 ? maxWidth - AppSpacing.screenGutter * 2 : _fieldWidth, child: child);

  Widget _filterBar(BuildContext context, double maxWidth) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final SchoolFilters f = _filters;
    final String? city = f.city;
    final String? areaId = f.areaId;
    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppTextField(
            key: const Key('schools.query'),
            label: l10n.adminSchoolsSearchLabel,
            hintText: l10n.adminSchoolsSearchHint,
            controller: _query,
            prefixIcon: Icons.search,
            textInputAction: TextInputAction.search,
            onChanged: _typed,
            onFieldSubmitted: (String text) => _apply(f.withQuery(text)),
          ),
          const SizedBox(height: AppSpacing.s16),
          Wrap(
            spacing: AppSpacing.s16,
            runSpacing: AppSpacing.s16,
            children: <Widget>[
              _field(
                maxWidth,
                AppDropdownMenu<String>(
                  key: const Key('schools.city'),
                  label: l10n.placeCityLabel,
                  leadingIcon: Icons.location_city_outlined,
                  value: city ?? '',
                  items: <AppDropdownItem<String>>[
                    AppDropdownItem<String>('', l10n.adminAllCities),
                    ...sortByName(
                      <AppDropdownItem<String>>[for (final String g in kGovernorates) AppDropdownItem<String>(g, governorateLabel(l10n, g))],
                      (AppDropdownItem<String> i) => i.label,
                    ),
                  ],
                  onSelected: (String g) => _apply(f.withCity(g.isEmpty ? null : g)),
                ),
              ),
              _field(
                maxWidth,
                FutureBuilder<List<AdminPlace>>(
                  // A new city clears the area: a new key starts a new field.
                  key: ValueKey<String>('schools.areas.${city ?? ''}'),
                  future: city == null ? null : _areasOf(city),
                  builder: (BuildContext context, AsyncSnapshot<List<AdminPlace>> snap) {
                    final List<AdminPlace> areas = snap.data ?? const <AdminPlace>[];
                    return AppDropdownMenu<String>(
                      key: Key('schools.area.${city ?? ''}'),
                      label: l10n.placeAreaLabel,
                      helperText: snap.hasError ? AdminFailure.from(snap.error!).message(l10n) : null,
                      value: areaId ?? '',
                      items: <AppDropdownItem<String>>[
                        AppDropdownItem<String>('', l10n.adminAllAreas),
                        for (final AdminPlace a in sortByName(areas, (AdminPlace a) => a.name(language))) AppDropdownItem<String>(a.id, a.name(language)),
                      ],
                      onSelected: city == null || areas.isEmpty ? null : (String id) => _apply(f.withArea(id.isEmpty ? null : id)),
                    );
                  },
                ),
              ),
              _field(
                maxWidth,
                FutureBuilder<List<AdminPlace>>(
                  key: ValueKey<String>('schools.districts.${areaId ?? ''}'),
                  future: areaId == null ? null : _districtsOf(areaId),
                  builder: (BuildContext context, AsyncSnapshot<List<AdminPlace>> snap) {
                    final List<AdminPlace> districts = snap.data ?? const <AdminPlace>[];
                    return AppDropdownMenu<String>(
                      key: Key('schools.district.${areaId ?? ''}'),
                      label: l10n.placeDistrictLabel,
                      helperText: snap.hasError ? AdminFailure.from(snap.error!).message(l10n) : null,
                      value: f.districtId ?? '',
                      items: <AppDropdownItem<String>>[
                        AppDropdownItem<String>('', l10n.adminAllDistricts),
                        for (final AdminPlace d in sortByName(districts, (AdminPlace d) => d.name(language))) AppDropdownItem<String>(d.id, d.name(language)),
                      ],
                      onSelected: areaId == null || districts.isEmpty ? null : (String id) => _apply(f.withDistrict(id.isEmpty ? null : id)),
                    );
                  },
                ),
              ),
              _field(
                maxWidth,
                AppDropdownMenu<String>(
                  key: const Key('schools.sort'),
                  label: l10n.adminSortLabel,
                  leadingIcon: Icons.sort,
                  value: f.sortFor(language).code,
                  items: <AppDropdownItem<String>>[
                    AppDropdownItem<String>(SchoolSort.nameAr.code, l10n.adminSortNameAr),
                    AppDropdownItem<String>(SchoolSort.nameEn.code, l10n.adminSortNameEn),
                  ],
                  onSelected: (String code) => _apply(f.withSort(SchoolSort.fromCode(code) ?? SchoolSort.nameEn)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          AppSwitchRow(
            key: const Key('schools.all'),
            title: l10n.adminSchoolsShowAll,
            subtitle: l10n.adminSchoolsShowAllHelp,
            leadingIcon: Icons.visibility_outlined,
            value: f.includeAll,
            onChanged: (bool on) => _apply(f.withIncludeAll(on)),
          ),
          if (f.includeAll) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            Wrap(
              spacing: AppSpacing.s16,
              runSpacing: AppSpacing.s16,
              children: <Widget>[
                _field(
                  maxWidth,
                  AppDropdownMenu<String>(
                    key: const Key('schools.status'),
                    label: l10n.adminSchoolStatusLabel,
                    value: f.status?.code ?? '',
                    items: <AppDropdownItem<String>>[
                      AppDropdownItem<String>('', l10n.adminAnyStatus),
                      for (final SchoolStatus s in SchoolStatus.values) AppDropdownItem<String>(s.code, schoolStatusLabel(l10n, s)),
                    ],
                    onSelected: (String code) =>
                        _apply(f.withStatus(SchoolStatus.values.where((SchoolStatus s) => s.code == code).firstOrNull)),
                  ),
                ),
                _field(
                  maxWidth,
                  AppDropdownMenu<String>(
                    key: const Key('schools.visibility'),
                    label: l10n.adminVisibilityLabel,
                    value: f.visibility?.code ?? '',
                    items: <AppDropdownItem<String>>[
                      AppDropdownItem<String>('', l10n.adminAnyVisibility),
                      AppDropdownItem<String>(SchoolVisibility.inSearch.code, l10n.adminVisibilityInSearch),
                      AppDropdownItem<String>(SchoolVisibility.hidden.code, l10n.adminVisibilityHidden),
                    ],
                    onSelected: (String code) => _apply(f.withVisibility(SchoolVisibility.fromCode(code))),
                  ),
                ),
                _field(
                  maxWidth,
                  AppDropdownMenu<String>(
                    key: const Key('schools.source'),
                    label: l10n.adminSourceLabel,
                    value: f.source ?? '',
                    items: <AppDropdownItem<String>>[
                      AppDropdownItem<String>('', l10n.adminAnySource),
                      for (final String s in <String>{...kSchoolSources, ..._seenSources, ?f.source}) AppDropdownItem<String>(s, s),
                    ],
                    onSelected: (String s) => _apply(f.withSource(s.isEmpty ? null : s)),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.s8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: const Key('schools.clear'),
              label: l10n.adminClearFilters,
              icon: Icons.filter_alt_off_outlined,
              variant: AppButtonVariant.tertiary,
              onPressed: f.isFiltered ? _clearAll : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final SchoolSearchPage? page = _firstPage;
    final int? total = page?.total;
    if (page == null || _schools is! AsyncData<List<School>> || (total ?? 0) == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (total != null)
            Semantics(
              liveRegion: true,
              child: OneLineText(
                page.totalExact ? l10n.adminSchoolsCount(total) : l10n.adminSchoolsCountAtLeast(total),
                key: const Key('schools.count'),
                style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          if (page.degraded) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppInlineMessage(message: l10n.adminSchoolsDegraded, tone: AppStateTone.warning),
          ],
        ],
      ),
    );
  }

  List<Widget> _results(BuildContext context, {required bool table}) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<School>> value = _schools;
    if (value is! AsyncData<List<School>> || value.value.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: AdminAsyncView<List<School>>(
            value: value,
            onRetry: () => unawaited(_load()),
            isEmpty: (List<School> s) => s.isEmpty,
            empty: _filters.isFiltered
                ? EmptyStateView(
                    key: const Key('schools.noMatch'),
                    icon: Icons.search_off_outlined,
                    title: l10n.adminSchoolsNoMatchTitle,
                    body: l10n.adminSchoolsNoMatchBody,
                    actionLabel: l10n.adminClearFilters,
                    onAction: _clearAll,
                  )
                : EmptyStateView(icon: Icons.school_outlined, title: l10n.adminSchoolsEmptyTitle, body: l10n.adminSchoolsEmptyBody),
            builder: (_) => const SizedBox.shrink(),
          ),
        ),
      ];
    }
    final List<School> schools = value.value;
    return <Widget>[
      if (table) const SliverToBoxAdapter(child: _SchoolsTableHeader()),
      SliverList.builder(
        itemCount: schools.length + (_next == null ? 0 : 1),
        itemBuilder: (BuildContext context, int i) {
          if (i == schools.length) {
            return Padding(
              padding: AppSpacing.screenPadding,
              child: AppButton(
                key: const Key('schools.more'),
                label: l10n.adminLoadMore,
                variant: AppButtonVariant.tertiary,
                loading: _loadingMore,
                onPressed: _loadingMore ? null : () => unawaited(_load(more: true)),
              ),
            );
          }
          final School s = schools[i];
          void open() => context.go(AdminRoutes.school(s.id));
          return table ? _SchoolsTableRow(school: s, onTap: open) : _SchoolListRow(school: s, onTap: open);
        },
      ),
    ];
  }
}

String schoolStatusLabel(AppLocalizations l10n, SchoolStatus status) => switch (status) {
  SchoolStatus.active => l10n.adminSchoolStatusActive,
  SchoolStatus.awaitingReview => l10n.adminSchoolStatusAwaiting,
  SchoolStatus.merged => l10n.adminSchoolStatusMerged,
};

AppBadgeTone _statusTone(SchoolStatus status) => switch (status) {
  SchoolStatus.active => AppBadgeTone.success,
  SchoolStatus.awaitingReview => AppBadgeTone.warning,
  SchoolStatus.merged => AppBadgeTone.neutral,
};

String _areaName(School s, String language) {
  final String preferred = language == 'ar' ? s.placeAreaNameAr : s.placeAreaNameEn;
  return preferred.isNotEmpty ? preferred : (language == 'ar' ? s.placeAreaNameEn : s.placeAreaNameAr);
}

String _districtName(School s, String language) {
  final String preferred = language == 'ar' ? s.placeDistrictNameAr : s.placeDistrictNameEn;
  return preferred.isNotEmpty ? preferred : (language == 'ar' ? s.placeDistrictNameEn : s.placeDistrictNameAr);
}

/// Column widths (flex) of the schools table, header and rows alike.
const List<int> _columnFlex = <int>[3, 3, 2, 2, 2, 1, 2];

/// Text in [direction] inside a cell, starting at the cell's start side:
/// an Arabic name reads right to left inside the English panel.
class _DirectedCell extends StatelessWidget {
  const _DirectedCell(this.text, this.direction, {this.style});

  final String text;
  final TextDirection direction;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Directionality(textDirection: direction, child: OneLineText(text, style: style)),
  );
}

class _SchoolsTableHeader extends StatelessWidget {
  const _SchoolsTableHeader();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<String> labels = <String>[
      l10n.adminSortNameAr,
      l10n.adminSortNameEn,
      l10n.placeCityLabel,
      l10n.placeAreaLabel,
      l10n.placeDistrictLabel,
      l10n.adminSourceLabel,
      l10n.adminSchoolStatusLabel,
    ];
    final TextStyle? style = context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant);
    return Semantics(
      container: true,
      header: true,
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: context.colors.outlineVariant, width: AppBorders.hairline)),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < labels.length; i++)
              Expanded(
                flex: _columnFlex[i],
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpacing.s8),
                  child: OneLineText(labels[i], style: style),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SchoolsTableRow extends StatelessWidget {
  const _SchoolsTableRow({required this.school, required this.onTap});

  final School school;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final School s = school;
    final String area = _areaName(s, language);
    final String district = _districtName(s, language);
    final List<Widget> cells = <Widget>[
      _DirectedCell(s.nameAr.isEmpty ? '—' : s.nameAr, TextDirection.rtl, style: context.text.titleSmall),
      _DirectedCell(s.nameEn.isEmpty ? '—' : s.nameEn, TextDirection.ltr, style: context.text.titleSmall),
      OneLineText(s.governorate.isEmpty ? '—' : governorateLabel(l10n, s.governorate)),
      OneLineText(area.isEmpty ? l10n.adminNoArea : area),
      OneLineText(district.isEmpty ? '—' : district),
      OneLineText(ltrIsolate(s.source)),
      Row(
        children: <Widget>[
          Flexible(child: AppStatusBadge(label: schoolStatusLabel(l10n, s.status), tone: _statusTone(s.status))),
          if (s.searchHidden) ...<Widget>[
            const SizedBox(width: AppSpacing.s4),
            Flexible(child: AppStatusBadge(label: l10n.adminVisibilityHidden, icon: Icons.visibility_off_outlined)),
          ],
        ],
      ),
    ];
    return Semantics(
      button: true,
      label: <String>[
        s.nameEn,
        s.nameAr,
        if (area.isNotEmpty) area,
        schoolStatusLabel(l10n, s.status),
        if (s.searchHidden) l10n.adminVisibilityHidden,
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        key: Key('schools.${s.id}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTouchTarget + AppSpacing.s8),
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.colors.outlineVariant, width: AppBorders.hairline)),
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < cells.length; i++)
                Expanded(
                  flex: _columnFlex[i],
                  child: Padding(padding: const EdgeInsetsDirectional.only(end: AppSpacing.s8), child: cells[i]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The narrow layout: one list row per school.
class _SchoolListRow extends StatelessWidget {
  const _SchoolListRow({required this.school, required this.onTap});

  final School school;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final School s = school;
    final String area = _areaName(s, language);
    final String district = _districtName(s, language);
    final String primary = language == 'ar' ? s.nameAr : s.nameEn;
    final String other = language == 'ar' ? s.nameEn : s.nameAr;
    return AppListRow(
      key: Key('schools.${s.id}'),
      title: primary.isNotEmpty ? primary : other,
      subtitle: <String>[
        if (s.governorate.isNotEmpty) governorateLabel(l10n, s.governorate),
        if (area.isNotEmpty) area else l10n.adminNoArea,
        if (district.isNotEmpty) district,
        if (s.searchHidden) l10n.adminVisibilityHidden,
      ].join(' · '),
      leadingIcon: s.pin == null ? Icons.location_off_outlined : Icons.location_on_outlined,
      trailing: AppStatusBadge(label: schoolStatusLabel(l10n, s.status), tone: _statusTone(s.status)),
      onTap: onTap,
    );
  }
}
