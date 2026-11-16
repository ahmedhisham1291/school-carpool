import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/my_schools.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Areas of a school (public data, firestore.rules).
final _areasProvider = FutureProvider.autoDispose.family<List<SchoolArea>, String>(
  (Ref ref, String schoolId) => ref.watch(carpoolRepositoryProvider).areas(schoolId),
);

/// Find a carpool (F5, F6, F36, F39): by school (one of the parent's
/// schools), area and morning time, or activity carpools near home. Each
/// result shows times, days, free seats, rules and contribution. Opened
/// from the nearby map's Join with [parentUid]: only that parent's carpools.
///
/// States: loading (skeleton cards), empty (no school yet: add a child;
/// nothing found: start a carpool), error, offline, too many searches.
class CarpoolSearchScreen extends ConsumerStatefulWidget {
  const CarpoolSearchScreen({super.key, this.schoolId, this.parentUid, this.parentName});

  final String? schoolId;
  final String? parentUid;
  final String? parentName;

  @override
  ConsumerState<CarpoolSearchScreen> createState() => _CarpoolSearchScreenState();
}

class _CarpoolSearchScreenState extends ConsumerState<CarpoolSearchScreen> {
  CarpoolKind _kind = CarpoolKind.school;
  String? _schoolId;
  String? _areaId;
  String? _morning;
  int _radiusKm = 5;
  String? _parentUid;
  String? _searchedKey;
  int _request = 0;
  AsyncValue<List<Carpool>> _results = const AsyncLoading<List<Carpool>>();

  @override
  void initState() {
    super.initState();
    _schoolId = widget.schoolId;
    _parentUid = widget.parentUid;
  }

  Future<void> _search(CarpoolQuery query, String key) async {
    final int request = ++_request;
    _searchedKey = key;
    setState(() => _results = const AsyncLoading<List<Carpool>>());
    AsyncValue<List<Carpool>> next;
    try {
      next = AsyncData<List<Carpool>>(await ref.read(carpoolRepositoryProvider).search(query));
    } on CarpoolFailure catch (failure, stackTrace) {
      next = AsyncError<List<Carpool>>(failure, stackTrace);
    }
    if (mounted && request == _request) {
      setState(() => _results = next);
    }
  }

  void _retry() => setState(() => _searchedKey = null);

  Future<T?> _pick<T>(String title, List<(T?, String)> options, T? current, String keyPrefix) async {
    final _Choice<T>? picked = await showAppSheet<_Choice<T>>(
      context: context,
      title: title,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (T? value, String label) in options)
            AppListRow(
              key: Key('$keyPrefix.${value ?? 'any'}'),
              title: label,
              inset: false,
              showChevron: false,
              trailing: value == current ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop(_Choice<T>(value)),
            ),
        ],
      ),
    );
    return picked == null ? current : picked.value;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<MySchool>> schoolsValue = ref.watch(mySchoolsProvider);
    void reload() {
      ref
        ..invalidate(childrenProvider)
        ..invalidate(myHomeProvider);
    }

    final Widget body = switch (schoolsValue) {
      AsyncError<List<MySchool>>(:final Object error) => carpoolErrorView(error, reload),
      AsyncData<List<MySchool>>(:final List<MySchool> value) => _content(context, value),
      _ => const CarpoolListSkeleton(),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.carpoolFind)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, List<MySchool> schools) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    if (schools.isEmpty && _kind == CarpoolKind.school) {
      return EmptyStateView(
        key: const Key('search.noSchool'),
        icon: Icons.school_outlined,
        title: l10n.nearbyNoSchoolTitle,
        body: l10n.carpoolSearchNoSchoolBody,
        actionLabel: l10n.carpoolSearchActivities,
        onAction: () => setState(() => _kind = CarpoolKind.activity),
      );
    }
    final MySchool? school = schools.isEmpty
        ? null
        : schools.firstWhere((MySchool s) => s.id == _schoolId, orElse: () => schools.first);
    final List<SchoolArea> areas = school == null
        ? const <SchoolArea>[]
        : ref.watch(_areasProvider(school.id)).value ?? const <SchoolArea>[];
    final SchoolArea? area = areas.where((SchoolArea a) => a.id == _areaId).firstOrNull;

    final CarpoolQuery query = _kind == CarpoolKind.school
        ? CarpoolQuery(schoolId: school?.id, areaId: area?.id, morning: _morning, parentUid: _parentUid)
        : CarpoolQuery(kind: CarpoolKind.activity, morning: _morning, radiusKm: _radiusKm);
    final String key = query.toJson().toString();
    if (key != _searchedKey) {
      _searchedKey = key;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          unawaited(_search(query, key));
        }
      });
    }

    final String targetLabel = _kind == CarpoolKind.activity ? l10n.carpoolActivities : (school?.name(language) ?? '');
    final List<Widget> chips = <Widget>[
      AppChip(
        key: const Key('search.targetChip'),
        label: targetLabel,
        icon: _kind == CarpoolKind.activity ? Icons.sports_soccer_outlined : Icons.school_outlined,
        selected: true,
        onSelected: (bool _) => unawaited(_chooseTarget(schools)),
      ),
      if (_kind == CarpoolKind.school && areas.isNotEmpty)
        AppChip(
          key: const Key('search.areaChip'),
          label: area?.name(language) ?? l10n.carpoolAnyArea,
          icon: Icons.place_outlined,
          selected: area != null,
          onSelected: (bool _) => unawaited(_chooseArea(areas, language)),
        ),
      if (_kind == CarpoolKind.activity)
        AppChip(
          key: const Key('search.radiusChip'),
          label: l10n.nearbyRadiusKm(_radiusKm),
          icon: Icons.radar_rounded,
          onSelected: (bool _) => unawaited(_chooseRadius()),
        ),
      AppChip(
        key: const Key('search.timeChip'),
        label: _morning == null ? l10n.carpoolAnyTime : l10n.carpoolMorningAt(_morning!),
        icon: Icons.schedule_rounded,
        selected: _morning != null,
        onSelected: (bool _) => unawaited(_chooseTime()),
      ),
      if (_parentUid != null)
        AppChip(
          key: const Key('search.parentChip'),
          label: l10n.carpoolOnlyParent(widget.parentName ?? ''),
          icon: Icons.close_rounded,
          selected: true,
          onSelected: (bool _) => setState(() => _parentUid = null),
        ),
    ];

    final List<Widget> results = switch (_results) {
      AsyncData<List<Carpool>>(:final List<Carpool> value) when value.isEmpty => <Widget>[
        EmptyStateView(
          key: const Key('search.empty'),
          icon: Icons.search_off_rounded,
          title: l10n.carpoolSearchEmptyTitle,
          body: l10n.carpoolSearchEmptyBody,
          actionLabel: l10n.carpoolCreate,
          onAction: () => context.go(CarpoolRoutes.create),
        ),
      ],
      AsyncData<List<Carpool>>(:final List<Carpool> value) => <Widget>[
        for (final Carpool c in value)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s16),
            child: CarpoolCard(
              key: Key('search.result.${c.id}'),
              carpool: c,
              showContribution: ref.watch(featureSwitchesProvider).contributions,
              badge: switch (c.myStatus) {
                MembershipStatus.approved => AppStatusBadge(label: l10n.carpoolMember, tone: AppBadgeTone.success),
                MembershipStatus.requested => AppStatusBadge(label: l10n.carpoolRequested, tone: AppBadgeTone.warning),
                _ => null,
              },
              onTap: () => context.go(CarpoolRoutes.detail(c.id)),
            ),
          ),
      ],
      AsyncError<List<Carpool>>(:final Object error) => <Widget>[
        switch (CarpoolFailure.from(error)) {
          final CarpoolFailure f when f.isOffline => OfflineStateView(onRetry: _retry),
          final CarpoolFailure f when f.kind == CarpoolFailureKind.rateLimited || f.kind == CarpoolFailureKind.noHome => Padding(
            padding: AppSpacing.screenPadding,
            child: AppInlineMessage(key: const Key('search.message'), message: f.message(l10n), tone: AppStateTone.warning),
          ),
          _ => ErrorStateView(onRetry: _retry),
        },
      ],
      _ => <Widget>[const CarpoolListSkeleton()],
    };

    return ListView(
      key: const Key('search.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, AppSpacing.s16),
          child: Wrap(spacing: AppSpacing.s8, runSpacing: AppSpacing.s8, children: chips),
        ),
        ...results,
      ],
    );
  }

  Future<void> _chooseTarget(List<MySchool> schools) async {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    const String activity = '__activity';
    final String current = _kind == CarpoolKind.activity ? activity : (_schoolId ?? schools.firstOrNull?.id ?? '');
    final String? picked = await _pick<String>(
      l10n.carpoolSearchForSheet,
      <(String?, String)>[
        for (final MySchool s in schools) (s.id, s.name(language)),
        (activity, l10n.carpoolActivities),
      ],
      current,
      'search.target',
    );
    if (!mounted || picked == null || picked == current) {
      return;
    }
    setState(() {
      _areaId = null;
      _parentUid = null;
      if (picked == activity) {
        _kind = CarpoolKind.activity;
      } else {
        _kind = CarpoolKind.school;
        _schoolId = picked;
      }
    });
  }

  Future<void> _chooseArea(List<SchoolArea> areas, String language) async {
    final String? picked = await _pick<String>(
      context.l10n.carpoolAreaLabel,
      <(String?, String)>[(null, context.l10n.carpoolAnyArea), for (final SchoolArea a in areas) (a.id, a.name(language))],
      _areaId,
      'search.area',
    );
    if (mounted) {
      setState(() => _areaId = picked);
    }
  }

  Future<void> _chooseTime() async {
    final String? picked = await _pick<String>(
      context.l10n.carpoolMorningTitle,
      <(String?, String)>[(null, context.l10n.carpoolAnyTime), for (final String t in RunTime.choices()) (t, t)],
      _morning,
      'search.time',
    );
    if (mounted) {
      setState(() => _morning = picked);
    }
  }

  Future<void> _chooseRadius() async {
    final int? picked = await _pick<int>(
      context.l10n.nearbyRadiusSheetTitle,
      <(int?, String)>[for (final int km in Geo.radiusChoicesKm) (km, context.l10n.nearbyRadiusKm(km))],
      _radiusKm,
      'search.radius',
    );
    if (mounted && picked != null) {
      setState(() => _radiusKm = picked);
    }
  }
}

/// A sheet answer, so "Any" (null) differs from "closed without a choice".
class _Choice<T> {
  const _Choice(this.value);

  final T? value;
}
