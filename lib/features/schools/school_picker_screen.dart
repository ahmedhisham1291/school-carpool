import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_models.dart' show kGovernorates;
import 'package:school_carpool/admin/widgets/admin_labels.dart' show governorateLabel;
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/schools/other_school_screen.dart';
import 'package:school_carpool/features/schools/school_models.dart';
import 'package:school_carpool/features/schools/school_repository.dart';
import 'package:school_carpool/features/schools/school_search.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Opens the school picker and returns the chosen school, or null.
Future<SchoolOption?> openSchoolPicker(BuildContext context) => Navigator.of(context).push<SchoolOption>(
  MaterialPageRoute<SchoolOption>(builder: (BuildContext context) => const SchoolPickerScreen()),
);

/// Search and pick a child's school (F4, spec section 3 step 5): results
/// appear as the parent types, in Arabic or English, tolerant of spelling
/// differences, optionally limited to one governorate. The parent's own
/// schools awaiting review come first. "Other" is always the last row:
/// the parent adds a missing school and carries on.
///
/// Once the parent's home is set (Prompt 5, F40), the schools nearest to it
/// come first before typing, with their distance, and a map view shows
/// the home and the school pins: tap a pin, then "Choose school".
///
/// States: before typing (own pending schools, nearest schools or a hint),
/// loading (skeleton rows), results, no results (empty view), error and
/// offline (with retry). "Other" stays available in every state.
class SchoolPickerScreen extends ConsumerStatefulWidget {
  const SchoolPickerScreen({super.key});

  @override
  ConsumerState<SchoolPickerScreen> createState() => _SchoolPickerScreenState();
}

sealed class _Results {
  const _Results();
}

class _Idle extends _Results {
  const _Idle();
}

class _Loading extends _Results {
  const _Loading();
}

class _Found extends _Results {
  const _Found(this.schools);

  final List<SchoolOption> schools;
}

class _Failed extends _Results {
  const _Failed({required this.offline});

  final bool offline;
}

class _SchoolPickerScreenState extends ConsumerState<SchoolPickerScreen> {
  /// Waits this long after the last key press before searching (fewer
  /// searches on Algolia's free plan, docs/COSTS.md).
  static const Duration debounce = Duration(milliseconds: 300);

  /// Room for an empty, error or offline view above the "Other" row.
  static const double _stateHeight = AppSpacing.s64 * 5;

  final TextEditingController _query = TextEditingController();
  Timer? _timer;
  String? _governorate;
  _Results _results = const _Idle();
  int _request = 0;

  /// Schools nearest to the home, loaded once (one search on the free plan).
  List<SchoolOption> _nearest = const <SchoolOption>[];
  GeoPin? _nearestFor;
  bool _showMap = false;
  SchoolOption? _mapChoice;
  MapCameraController? _camera;

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    _camera?.dispose();
    super.dispose();
  }

  void _loadNearest(GeoPin home) {
    if (Geo.same(_nearestFor, home)) {
      return;
    }
    _nearestFor = home;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => unawaited(_fetchNearest(home)));
  }

  Future<void> _fetchNearest(GeoPin home) async {
    try {
      final List<SchoolOption> found = await ref.read(schoolSearchProvider).nearest(home);
      if (mounted) {
        setState(() => _nearest = found);
      }
    } on Object {
      // The search still works; the nearest list is a shortcut only.
    }
  }

  void _onChanged(String _) {
    _timer?.cancel();
    if (_query.text.trim().length < kMinSchoolQueryLength) {
      _request++;
      setState(() => _results = const _Idle());
      return;
    }
    _timer = Timer(debounce, () => unawaited(_search()));
  }

  Future<void> _search() async {
    final String query = _query.text.trim();
    if (query.length < kMinSchoolQueryLength) {
      return;
    }
    final int request = ++_request;
    setState(() => _results = const _Loading());
    final _Results next = await _run(query);
    // A newer search (or a cleared field) wins over a slow answer.
    if (mounted && request == _request) {
      setState(() => _results = next);
    }
  }

  Future<_Results> _run(String query) async {
    try {
      return _Found(await ref.read(schoolSearchProvider).search(query, governorate: _governorate));
    } on SchoolSearchFailure catch (failure) {
      return _Failed(offline: failure.isOffline);
    } on Object {
      return const _Failed(offline: false);
    }
  }

  Future<void> _chooseGovernorate() async {
    final AppLocalizations l10n = context.l10n;
    // A record: null means "all governorates", so "closed without choosing" is the outer null.
    final ({String? code})? choice = await showAppSheet<({String? code})>(
      context: context,
      title: l10n.schoolGovernorateSheetTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppListRow(
            key: const Key('school.gov.all'),
            title: l10n.schoolAllGovernorates,
            inset: false,
            showChevron: false,
            trailing: _governorate == null ? const Icon(Icons.check_rounded) : null,
            onTap: () => Navigator.of(context).pop((code: null)),
          ),
          for (final String code in kGovernorates)
            AppListRow(
              key: Key('school.gov.$code'),
              title: governorateLabel(l10n, code),
              inset: false,
              showChevron: false,
              trailing: _governorate == code ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop((code: code)),
            ),
        ],
      ),
    );
    if (choice == null || !mounted || choice.code == _governorate) {
      return;
    }
    setState(() => _governorate = choice.code);
    unawaited(_search());
  }

  Future<void> _addOther() async {
    final SchoolOption? added = await openOtherSchoolForm(
      context,
      name: _query.text.trim(),
      governorate: _governorate,
    );
    if (added != null && mounted) {
      Navigator.of(context).pop(added);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final List<SchoolOption> pending = ref.watch(myPendingSchoolsProvider).value ?? const <SchoolOption>[];
    final String query = _query.text.trim();
    final List<SchoolOption> myMatches = query.length < kMinSchoolQueryLength
        ? pending
        : SchoolMatcher(pending).search(query, governorate: _governorate);
    final String? gov = _governorate;
    final GeoPin? home = ref.watch(myHomeProvider).value?.location;
    if (home != null) {
      _loadNearest(home);
    }

    Widget row(SchoolOption school) {
      final String place = school.place(language);
      final GeoPin? at = school.location;
      final String where = <String>[
        if (home != null && at != null) l10n.schoolDistanceKm(Geo.distanceKm(home, at).toStringAsFixed(1)),
        if (place.isNotEmpty) place,
        governorateLabel(l10n, school.governorate),
      ].join(' · ');
      return AppListRow(
        key: Key('school.result.${school.id}'),
        title: school.name(language),
        subtitle: school.pending ? l10n.schoolAwaitingReview : where,
        leadingIcon: school.pending ? Icons.hourglass_empty_rounded : Icons.school_outlined,
        onTap: () => Navigator.of(context).pop(school),
      );
    }

    final List<Widget> body = <Widget>[
      for (final SchoolOption s in myMatches) row(s),
      ...switch (_results) {
        _Idle() when _nearest.isNotEmpty => <Widget>[
          AppSectionHeader(l10n.schoolNearestSection),
          for (final SchoolOption s in _nearest)
            if (!myMatches.any((SchoolOption m) => m.id == s.id)) row(s),
        ],
        _Idle() => <Widget>[
          if (myMatches.isEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.screenGutter,
                AppSpacing.s16,
                AppSpacing.screenGutter,
                AppSpacing.s16,
              ),
              child: Text(
                l10n.schoolSearchHint,
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
        ],
        _Loading() => const <Widget>[
          Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()])),
        ],
        _Found(schools: final List<SchoolOption> schools) when schools.isEmpty && myMatches.isEmpty => <Widget>[
          SizedBox(
            height: _stateHeight,
            child: EmptyStateView(
              icon: Icons.search_off_rounded,
              title: l10n.schoolNoResultsTitle,
              body: l10n.schoolNoResultsBody,
            ),
          ),
        ],
        _Found(schools: final List<SchoolOption> schools) => <Widget>[
          for (final SchoolOption s in schools)
            if (!myMatches.any((SchoolOption m) => m.id == s.id)) row(s),
        ],
        _Failed(offline: true) => <Widget>[
          SizedBox(height: _stateHeight, child: OfflineStateView(onRetry: () => unawaited(_search()))),
        ],
        _Failed() => <Widget>[
          SizedBox(height: _stateHeight, child: ErrorStateView(onRetry: () => unawaited(_search()))),
        ],
      },
      // Always the last row of every list.
      AppListRow(
        key: const Key('school.other'),
        title: l10n.schoolOtherTitle,
        subtitle: l10n.schoolOtherSubtitle,
        leadingIcon: Icons.add_rounded,
        onTap: () => unawaited(_addOther()),
      ),
    ];

    final List<SchoolOption> onMap = switch (_results) {
      _Found(schools: final List<SchoolOption> schools) => schools,
      _ => _nearest,
    };

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.schoolPickerTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('school.mapToggle'),
            tooltip: _showMap ? l10n.nearbyShowList : l10n.schoolShowMap,
            icon: Icon(_showMap ? Icons.view_list_outlined : Icons.map_outlined),
            onPressed: () => setState(() => _showMap = !_showMap),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.screenGutter,
                AppSpacing.s8,
                AppSpacing.screenGutter,
                AppSpacing.s8,
              ),
              child: AppTextField(
                key: const Key('school.search'),
                controller: _query,
                label: l10n.schoolSearchLabel,
                hintText: l10n.schoolSearchPlaceholder,
                prefixIcon: Icons.search_rounded,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onFieldSubmitted: (String _) => unawaited(_search()),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: AppChip(
                  key: const Key('school.governorate'),
                  label: gov == null ? l10n.schoolAllGovernorates : governorateLabel(l10n, gov),
                  icon: Icons.place_outlined,
                  selected: gov != null,
                  onSelected: (bool _) => unawaited(_chooseGovernorate()),
                ),
              ),
            ),
            Expanded(
              child: _showMap
                  ? _mapView(context, home, onMap)
                  : ListView(
                      key: const Key('school.results'),
                      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
                      children: body,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// F40: the home and the school pins; tap a pin, then "Choose school".
  Widget _mapView(BuildContext context, GeoPin? home, List<SchoolOption> schools) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final SchoolOption? choice = _mapChoice;
    final GeoPin? first = schools.map((SchoolOption s) => s.location).whereType<GeoPin>().firstOrNull;
    final MapCameraController camera = _camera ??= MapCameraController(
      center: home ?? first ?? Geo.cairo,
      zoom: home != null || first != null ? AppMapTokens.areaZoom : AppMapTokens.cityZoom,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AppMapView(
            config: MapViewConfig(
              camera: camera,
              semanticLabel: l10n.schoolMapLabel,
              markers: <MapMarker>[
                if (home != null) MapMarker(id: 'home', at: home, kind: MapMarkerKind.home, label: l10n.homePinLabel),
                for (final SchoolOption s in schools)
                  if (s.location case final GeoPin at)
                    MapMarker(
                      id: s.id,
                      at: at,
                      kind: s.id == choice?.id ? MapMarkerKind.selectedSchool : MapMarkerKind.school,
                      label: s.name(language),
                      onTap: () => setState(() => _mapChoice = s),
                    ),
              ],
            ),
          ),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              OneLineText(
                choice == null ? l10n.schoolMapHint : choice.name(language),
                key: const Key('school.mapChoice'),
                style: choice == null
                    ? context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)
                    : context.text.titleSmall,
              ),
              const SizedBox(height: AppSpacing.s16),
              AppButton(
                key: const Key('school.mapChoose'),
                label: l10n.schoolChoose,
                expand: true,
                onPressed: choice == null ? null : () => Navigator.of(context).pop(choice),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
