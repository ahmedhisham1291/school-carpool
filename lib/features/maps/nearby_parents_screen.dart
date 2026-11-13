import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/maps/my_schools.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Nearby parents map (F22, spec section 10): verified parents of one of
/// the parent's schools within the chosen radius of their home, as blurred
/// discs (the server sends rounded, offset points only). Filter by school
/// and radius (slider); a list view shows the same parents. Tapping a disc
/// or a row opens the parent card: first name, Verified badge, school,
/// Join and Message (placeholders until Prompts 6 and 9).
///
/// States: loading (skeleton), empty (no home yet, no school yet, or nobody
/// nearby with a hint to widen the radius), error, offline and "too many
/// searches" (with retry).
class NearbyParentsScreen extends ConsumerStatefulWidget {
  const NearbyParentsScreen({super.key});

  @override
  ConsumerState<NearbyParentsScreen> createState() => _NearbyParentsScreenState();
}

class _NearbyParentsScreenState extends ConsumerState<NearbyParentsScreen> {
  String? _schoolId;
  int? _radiusKm;
  bool _showList = false;
  String? _searchedKey;
  AsyncValue<List<NearbyParent>> _results = const AsyncLoading<List<NearbyParent>>();
  MapCameraController? _camera;
  GeoPin? _cameraHome;
  int _request = 0;

  /// School pins (F40) by school ID; null while unknown or without a pin.
  final Map<String, GeoPin?> _schoolPins = <String, GeoPin?>{};

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _search(String schoolId, int radiusKm, String key) async {
    final int request = ++_request;
    _searchedKey = key;
    setState(() => _results = const AsyncLoading<List<NearbyParent>>());
    AsyncValue<List<NearbyParent>> next;
    try {
      next = AsyncData<List<NearbyParent>>(
        await ref.read(mapRepositoryProvider).nearby(schoolId: schoolId, radiusKm: radiusKm),
      );
    } on MapFailure catch (failure, stackTrace) {
      next = AsyncError<List<NearbyParent>>(failure, stackTrace);
    }
    if (mounted && request == _request) {
      setState(() => _results = next);
    }
  }

  Future<void> _loadSchoolPin(String schoolId) async {
    final GeoPin? pin = await ref.read(mapRepositoryProvider).schoolPin(schoolId);
    if (mounted) {
      setState(() => _schoolPins[schoolId] = pin);
    }
  }

  void _retry() {
    _searchedKey = null;
    setState(() {});
  }

  Future<void> _chooseSchool(List<MySchool> schools) async {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final String? picked = await showAppSheet<String>(
      context: context,
      title: l10n.nearbySchoolSheetTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final MySchool s in schools)
            AppListRow(
              key: Key('nearby.school.${s.id}'),
              title: s.name(language),
              subtitle: s.fromChild ? l10n.drivingSchoolsFromChild : l10n.nearbyDrivingSchool,
              inset: false,
              showChevron: false,
              trailing: s.id == _schoolId ? const Icon(Icons.check_rounded) : null,
              onTap: () => Navigator.of(context).pop(s.id),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() => _schoolId = picked);
    }
  }

  Future<void> _chooseRadius(int current) async {
    final AppLocalizations l10n = context.l10n;
    final int? picked = await showAppSheet<int>(
      context: context,
      title: l10n.nearbyRadiusSheetTitle,
      body: _RadiusSlider(initial: current),
    );
    if (picked == null || picked == current || !mounted) {
      return;
    }
    setState(() => _radiusKm = picked);
    try {
      // Remembered for next time and for the new-parent alerts.
      await ref.read(mapRepositoryProvider).updateSettings(radiusKm: picked);
    } on MapFailure {
      // Best effort: this search still uses the new radius.
    }
  }

  Future<void> _openCard(NearbyParent parent, String schoolName) async {
    final AppLocalizations l10n = context.l10n;
    await showAppSheet<void>(
      context: context,
      title: parent.firstName,
      body: _ParentCard(parent: parent, schoolName: schoolName),
      primaryAction: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppButton(
            key: const Key('parent.join'),
            label: l10n.parentJoin,
            icon: Icons.group_add_outlined,
            expand: true,
            onPressed: () => showAppSnackBar(context, l10n.parentJoinSoon),
          ),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('parent.message'),
            label: l10n.parentMessage,
            icon: Icons.chat_bubble_outline_rounded,
            variant: AppButtonVariant.secondary,
            expand: true,
            onPressed: () => showAppSnackBar(context, l10n.parentMessageSoon),
          ),
        ],
      ),
    );
  }

  Future<void> _setHome() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (BuildContext context) => const HomeLocationScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Account? account = accountOf(ref.watch(sessionProvider));
    final AsyncValue<HomeLocation?> homeValue = ref.watch(myHomeProvider);
    final AsyncValue<List<MySchool>> schoolsValue = ref.watch(mySchoolsProvider);
    void reload() {
      ref
        ..invalidate(myHomeProvider)
        ..invalidate(childrenProvider);
    }

    Widget body;
    if (account != null && account.status != AccountStatus.verified) {
      body = EmptyStateView(icon: Icons.verified_outlined, title: l10n.nearbyTitle, body: l10n.mapErrorNotVerified);
    } else if (homeValue is AsyncError<HomeLocation?> || schoolsValue is AsyncError<List<MySchool>>) {
      final Object error = homeValue.error ?? schoolsValue.error ?? const MapFailure(MapFailureKind.unknown);
      body = MapFailure.from(error).isOffline ? OfflineStateView(onRetry: reload) : ErrorStateView(onRetry: reload);
    } else if (!homeValue.hasValue || !schoolsValue.hasValue) {
      body = const _NearbySkeleton();
    } else {
      body = _content(context, homeValue.value, schoolsValue.value ?? const <MySchool>[]);
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.nearbyTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('nearby.toggle'),
            tooltip: _showList ? l10n.nearbyShowMap : l10n.nearbyShowList,
            icon: Icon(_showList ? Icons.map_outlined : Icons.view_list_outlined),
            onPressed: () => setState(() => _showList = !_showList),
          ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, HomeLocation? home, List<MySchool> schools) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final GeoPin? homePin = home?.location;
    if (home == null || homePin == null) {
      return EmptyStateView(
        key: const Key('nearby.noHome'),
        icon: Icons.home_work_outlined,
        title: l10n.nearbyNoHomeTitle,
        body: l10n.nearbyNoHomeBody,
        actionLabel: l10n.nearbySetHome,
        onAction: () => unawaited(_setHome()),
      );
    }
    if (schools.isEmpty) {
      return EmptyStateView(
        key: const Key('nearby.noSchool'),
        icon: Icons.school_outlined,
        title: l10n.nearbyNoSchoolTitle,
        body: l10n.nearbyNoSchoolBody,
        actionLabel: l10n.nearbyAddSchool,
        onAction: () => context.go(ProfileRoutes.drivingSchools),
      );
    }

    final MySchool school = schools.firstWhere((MySchool s) => s.id == _schoolId, orElse: () => schools.first);
    final int radius = _radiusKm ?? (Geo.radiusChoicesKm.contains(home.radiusKm) ? home.radiusKm : Geo.defaultRadiusKm);
    final String key = '${school.id}|$radius|${homePin.lat},${homePin.lng}';
    if (key != _searchedKey) {
      _searchedKey = key;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          unawaited(_search(school.id, radius, key));
        }
      });
    }
    if (!_schoolPins.containsKey(school.id)) {
      _schoolPins[school.id] = null;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) => unawaited(_loadSchoolPin(school.id)));
    }
    final MapCameraController camera = _camera ??= MapCameraController(center: homePin, zoom: AppMapTokens.areaZoom);
    // Follow a home saved while this screen is open.
    if (_cameraHome != null && !Geo.same(_cameraHome, homePin)) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) => camera.moveTo(homePin));
    }
    _cameraHome = homePin;
    final GeoPin? schoolPin = _schoolPins[school.id];
    final String schoolName = school.name(language);
    final List<NearbyParent> parents = _results.value ?? const <NearbyParent>[];

    final Widget filters = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, AppSpacing.s8),
      child: Wrap(
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s8,
        children: <Widget>[
          AppChip(
            key: const Key('nearby.schoolChip'),
            label: schoolName,
            icon: Icons.school_outlined,
            selected: true,
            onSelected: (bool _) => unawaited(_chooseSchool(schools)),
          ),
          AppChip(
            key: const Key('nearby.radiusChip'),
            label: l10n.nearbyRadiusKm(radius),
            icon: Icons.radar_rounded,
            onSelected: (bool _) => unawaited(_chooseRadius(radius)),
          ),
        ],
      ),
    );

    final Widget status = switch (_results) {
      AsyncData<List<NearbyParent>>(:final List<NearbyParent> value) when value.isEmpty => EmptyStateView(
        key: const Key('nearby.empty'),
        icon: Icons.people_outline_rounded,
        title: l10n.nearbyEmptyTitle,
        body: radius < Geo.radiusChoicesKm.last ? l10n.nearbyEmptyBody : null,
        actionLabel: radius < Geo.radiusChoicesKm.last ? l10n.nearbyWiderRadius : null,
        onAction: radius < Geo.radiusChoicesKm.last
            ? () => setState(() => _radiusKm = Geo.radiusChoicesKm.firstWhere((int r) => r > radius))
            : null,
      ),
      AsyncData<List<NearbyParent>>(:final List<NearbyParent> value) => Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter, vertical: AppSpacing.s16),
        child: Text(
          l10n.nearbyCount(value.length),
          key: const Key('nearby.count'),
          style: context.text.titleSmall,
        ),
      ),
      AsyncError<List<NearbyParent>>(:final Object error) => switch (MapFailure.from(error)) {
        final MapFailure f when f.isOffline => OfflineStateView(onRetry: _retry),
        final MapFailure f when f.kind == MapFailureKind.rateLimited => Padding(
          padding: AppSpacing.screenPadding,
          child: AppInlineMessage(key: const Key('nearby.limited'), message: f.message(l10n), tone: AppStateTone.warning),
        ),
        _ => ErrorStateView(onRetry: _retry),
      },
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonListRow()])),
    };

    final Widget hidden = home.showOnMap
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s8),
            child: AppInlineMessage(key: const Key('nearby.hidden'), message: l10n.nearbyYouAreHidden),
          );

    if (_showList) {
      return ListView(
        key: const Key('nearby.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          filters,
          hidden,
          status,
          for (final NearbyParent p in parents)
            AppListRow(
              key: Key('nearby.row.${p.id}'),
              title: p.firstName,
              subtitle: schoolName,
              leadingIcon: Icons.person_outline_rounded,
              trailing: AppStatusBadge(label: l10n.statusVerified, tone: AppBadgeTone.success),
              onTap: () => unawaited(_openCard(p, schoolName)),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        filters,
        hidden,
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: AppMapView(
                  config: MapViewConfig(
                    camera: camera,
                    semanticLabel: l10n.nearbyMapLabel(parents.length),
                    radiusKm: radius.toDouble(),
                    // The server measures from the rounded home, so the ring does too.
                    radiusCenter: Geo.roundToGrid(homePin),
                    markers: <MapMarker>[
                      MapMarker(id: 'home', at: homePin, kind: MapMarkerKind.home, label: l10n.homePinLabel),
                      if (schoolPin != null)
                        MapMarker(id: 'school.${school.id}', at: schoolPin, kind: MapMarkerKind.school, label: schoolName),
                    ],
                    areas: <MapArea>[
                      for (final NearbyParent p in parents)
                        MapArea(
                          id: p.id,
                          center: p.point,
                          label: l10n.nearbyAreaLabel(p.firstName),
                          onTap: () => unawaited(_openCard(p, schoolName)),
                        ),
                    ],
                  ),
                ),
              ),
              if (_results.isLoading) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: AppMapTokens.mapHeight),
          child: SingleChildScrollView(child: status),
        ),
      ],
    );
  }
}

/// The parent card (F22): first name (the sheet title), Verified badge and
/// school. Nothing else about the parent is shown or sent.
class _ParentCard extends StatelessWidget {
  const _ParentCard({required this.parent, required this.schoolName});

  final NearbyParent parent;
  final String schoolName;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      key: Key('parent.card.${parent.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppStatusBadge(label: l10n.statusVerified, tone: AppBadgeTone.success, icon: Icons.verified_rounded),
        const SizedBox(height: AppSpacing.s16),
        AppListRow(title: schoolName, subtitle: l10n.parentCardSchool, leadingIcon: Icons.school_outlined, inset: false),
        Text(
          l10n.parentCardPrivacy,
          style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The radius slider in its sheet: snaps to 1, 2, 3, 5 and 10 km.
class _RadiusSlider extends StatefulWidget {
  const _RadiusSlider({required this.initial});

  final int initial;

  @override
  State<_RadiusSlider> createState() => _RadiusSliderState();
}

class _RadiusSliderState extends State<_RadiusSlider> {
  late int _index = Geo.radiusChoicesKm.contains(widget.initial)
      ? Geo.radiusChoicesKm.indexOf(widget.initial)
      : Geo.radiusChoicesKm.indexOf(Geo.defaultRadiusKm);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final int km = Geo.radiusChoicesKm[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        OneLineText(l10n.nearbyRadiusKm(km), key: const Key('nearby.radiusValue'), style: context.text.titleMedium),
        Slider(
          key: const Key('nearby.radiusSlider'),
          value: _index.toDouble(),
          max: (Geo.radiusChoicesKm.length - 1).toDouble(),
          divisions: Geo.radiusChoicesKm.length - 1,
          label: l10n.nearbyRadiusKm(km),
          semanticFormatterCallback: (double v) => l10n.nearbyRadiusKm(Geo.radiusChoicesKm[v.round()]),
          onChanged: (double v) => setState(() => _index = v.round()),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('nearby.radiusDone'),
          label: l10n.nearbyRadiusApply,
          expand: true,
          onPressed: () => Navigator.of(context).pop(km),
        ),
      ],
    );
  }
}

class _NearbySkeleton extends StatelessWidget {
  const _NearbySkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s40, width: AppSpacing.s64 * 3),
          SizedBox(height: AppSpacing.s16),
          SkeletonBox(height: AppMapTokens.mapHeight),
          SizedBox(height: AppSpacing.s16),
          SkeletonListRow(),
        ],
      ),
    ),
  );
}
