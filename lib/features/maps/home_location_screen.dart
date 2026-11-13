import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/location_permission_screen.dart';
import 'package:school_carpool/features/maps/location_service.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Home picker (F21, spec section 10 "Location picker"): a map with a pin
/// fixed in the middle (the parent moves the map under it), an address
/// search (Places, through Cloud Functions, with a session token and a
/// 400 ms pause after typing) and "use my location" (our explanation
/// first, then the system prompt). Saving sends the exact point to
/// setHomeLocation; others only ever see an area of about 500 m.
///
/// States: loading (skeleton map and card), empty (no home yet: Cairo and
/// a hint to move the map), error and offline (full screen with retry).
class HomeLocationScreen extends ConsumerStatefulWidget {
  const HomeLocationScreen({super.key});

  @override
  ConsumerState<HomeLocationScreen> createState() => _HomeLocationScreenState();
}

class _HomeLocationScreenState extends ConsumerState<HomeLocationScreen> {
  /// Fewer Places requests (COST MODE): wait this long after the last key.
  static const Duration debounce = Duration(milliseconds: 400);
  static const int minQueryLength = 3;

  final TextEditingController _query = TextEditingController();
  MapCameraController? _camera;
  GeoPin? _center;
  String _label = '';
  GeoPin? _labelAt;
  String? _sessionToken;
  Timer? _timer;
  int _request = 0;
  List<PlaceSuggestion> _suggestions = const <PlaceSuggestion>[];
  bool _searching = false;
  String? _searchMessage;
  bool _saving = false;
  bool _locating = false;
  String? _saveError;

  @override
  void dispose() {
    _timer?.cancel();
    _query.dispose();
    _camera?.dispose();
    super.dispose();
  }

  MapCameraController _cameraFor(HomeLocation? home) {
    final GeoPin? saved = home?.location;
    _center ??= saved ?? Geo.cairo;
    if (saved != null && _label.isEmpty) {
      _label = home?.label ?? '';
      _labelAt = saved;
    }
    return _camera ??= MapCameraController(
      center: saved ?? Geo.cairo,
      zoom: saved == null ? AppMapTokens.cityZoom : AppMapTokens.streetZoom,
    );
  }

  void _onCameraIdle(GeoPin center) {
    final GeoPin? at = _labelAt;
    setState(() {
      _center = center;
      _saveError = null;
      // The address no longer matches once the pin moved away from it.
      if (at != null && Geo.distanceKm(at, center) > 0.05) {
        _label = '';
        _labelAt = null;
      }
    });
  }

  void _onQueryChanged(String _) {
    _timer?.cancel();
    final String text = _query.text.trim();
    if (text.length < minQueryLength) {
      _request++;
      setState(() {
        _suggestions = const <PlaceSuggestion>[];
        _searchMessage = null;
        _searching = false;
      });
      return;
    }
    _sessionToken ??= newPlacesSessionToken();
    _timer = Timer(debounce, () => unawaited(_search(text)));
  }

  Future<void> _search(String text) async {
    final int request = ++_request;
    final String language = Localizations.localeOf(context).languageCode;
    final AppLocalizations l10n = context.l10n;
    setState(() => _searching = true);
    List<PlaceSuggestion> found = const <PlaceSuggestion>[];
    String? message;
    try {
      found = await ref
          .read(placesRepositoryProvider)
          .autocomplete(text, sessionToken: _sessionToken ?? newPlacesSessionToken(), language: language, near: _center);
      if (found.isEmpty) {
        message = l10n.homeSearchNoResults;
      }
    } on MapFailure catch (failure) {
      message = failure.message(l10n);
    }
    if (!mounted || request != _request) {
      return;
    }
    setState(() {
      _searching = false;
      _suggestions = found;
      _searchMessage = message;
    });
  }

  Future<void> _pick(PlaceSuggestion suggestion) async {
    final String language = Localizations.localeOf(context).languageCode;
    final AppLocalizations l10n = context.l10n;
    final String token = _sessionToken ?? newPlacesSessionToken();
    // The details call ends the session; the next search starts a new one.
    _sessionToken = null;
    _request++;
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = const <PlaceSuggestion>[];
      _searching = true;
    });
    try {
      final PlaceResult place = await ref
          .read(placesRepositoryProvider)
          .details(suggestion.placeId, sessionToken: token, language: language);
      if (!mounted) {
        return;
      }
      _camera?.moveTo(place.location, zoom: AppMapTokens.streetZoom);
      setState(() {
        _searching = false;
        _searchMessage = null;
        _center = place.location;
        _label = place.label;
        _labelAt = place.location;
        _query.text = suggestion.primary;
      });
    } on MapFailure catch (failure) {
      if (mounted) {
        setState(() {
          _searching = false;
          _searchMessage = failure.message(l10n);
        });
      }
    }
  }

  Future<void> _useMyLocation() async {
    final LocationService location = ref.read(locationServiceProvider);
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    LocationAccess access = await location.access();
    if (!mounted) {
      return;
    }
    if (access == LocationAccess.serviceOff) {
      showAppSnackBarOn(messenger, l10n.locationServiceOff);
      return;
    }
    if (access == LocationAccess.deniedForever) {
      if (await LocationPermissionScreen.open(context, blocked: true)) {
        await location.openSettings();
      }
      return;
    }
    if (access != LocationAccess.granted) {
      if (!await LocationPermissionScreen.open(context, blocked: false)) {
        return;
      }
      access = await location.request();
      if (access != LocationAccess.granted) {
        showAppSnackBarOn(messenger, access == LocationAccess.serviceOff ? l10n.locationServiceOff : l10n.locationFailed);
        return;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => _locating = true);
    try {
      final GeoPin here = await location.current();
      if (!mounted) {
        return;
      }
      _camera?.moveTo(here, zoom: AppMapTokens.streetZoom);
      setState(() {
        _center = here;
        _label = '';
        _labelAt = null;
        _saveError = null;
      });
    } on LocationFailure catch (failure) {
      showAppSnackBarOn(
        messenger,
        failure.kind == LocationFailureKind.serviceOff ? l10n.locationServiceOff : l10n.locationFailed,
      );
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  Future<void> _save() async {
    final GeoPin? center = _center;
    if (center == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    if (!Geo.inEgypt(center)) {
      setState(() => _saveError = l10n.mapErrorOutsideEgypt);
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await ref.read(mapRepositoryProvider).setHome(center, label: _label);
      showAppSnackBarOn(messenger, l10n.homeSaved);
      if (mounted && navigator.canPop()) {
        navigator.pop();
      }
    } on MapFailure catch (failure) {
      if (mounted) {
        setState(() => _saveError = failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HomeLocation?> home = ref.watch(myHomeProvider);
    void retry() => ref.invalidate(myHomeProvider);

    final Widget body = switch (home) {
      AsyncData<HomeLocation?>(:final HomeLocation? value) => _picker(context, value),
      AsyncError<HomeLocation?>(:final Object error) when MapFailure.from(error).isOffline =>
        OfflineStateView(onRetry: retry),
      AsyncError<HomeLocation?>() => ErrorStateView(onRetry: retry),
      _ => const _PickerSkeleton(),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.homeLocationTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _picker(BuildContext context, HomeLocation? home) {
    final AppLocalizations l10n = context.l10n;
    final MapCameraController camera = _cameraFor(home);
    final bool hasHome = home?.location != null;
    final String? searchMessage = _searchMessage;
    final String? saveError = _saveError;

    return Column(
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
            key: const Key('home.search'),
            controller: _query,
            label: l10n.homeSearchLabel,
            hintText: l10n.homeSearchHint,
            prefixIcon: Icons.search_rounded,
            textInputAction: TextInputAction.search,
            helperText: searchMessage,
            onChanged: _onQueryChanged,
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: AppMapView(
                  config: MapViewConfig(
                    camera: camera,
                    semanticLabel: l10n.homeMapLabel,
                    onCameraIdle: _onCameraIdle,
                  ),
                ),
              ),
              // The pin's tip marks the middle of the map.
              const IgnorePointer(
                child: Align(
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(bottom: AppMapTokens.centerPinSize),
                    child: _CenterPin(),
                  ),
                ),
              ),
              PositionedDirectional(
                end: AppSpacing.s16,
                bottom: AppSpacing.s16,
                child: IconButton.filledTonal(
                  key: const Key('home.myLocation'),
                  tooltip: l10n.homeUseLocation,
                  iconSize: AppIconSize.md,
                  constraints: const BoxConstraints.tightFor(
                    width: AppSpacing.minTouchTarget,
                    height: AppSpacing.minTouchTarget,
                  ),
                  onPressed: _locating ? null : () => unawaited(_useMyLocation()),
                  icon: const Icon(Icons.my_location_rounded),
                ),
              ),
              if (_searching)
                const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
              if (_suggestions.isNotEmpty)
                PositionedDirectional(
                  top: AppSpacing.s8,
                  start: AppSpacing.screenGutter,
                  end: AppSpacing.screenGutter,
                  child: AppCard(
                    padding: EdgeInsetsDirectional.zero,
                    elevation: AppElevation.medium,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final PlaceSuggestion s in _suggestions)
                          AppListRow(
                            key: Key('home.suggestion.${s.placeId}'),
                            title: s.primary,
                            subtitle: s.secondary.isEmpty ? null : s.secondary,
                            leadingIcon: Icons.place_outlined,
                            showChevron: false,
                            inset: false,
                            onTap: () => unawaited(_pick(s)),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_label.isNotEmpty) ...<Widget>[
                Text(_label, key: const Key('home.label'), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.titleSmall),
                const SizedBox(height: AppSpacing.s4),
              ],
              Text(
                hasHome ? l10n.homePrivacyNote : '${l10n.homeMoveHint} ${l10n.homePrivacyNote}',
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              if (saveError != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(key: const Key('home.error'), message: saveError, tone: AppStateTone.error),
              ],
              const SizedBox(height: AppSpacing.s16),
              AppButton(
                key: const Key('home.save'),
                label: l10n.homeSave,
                icon: Icons.check_rounded,
                expand: true,
                loading: _saving,
                onPressed: _saving ? null : () => unawaited(_save()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CenterPin extends StatelessWidget {
  const _CenterPin();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Icon(Icons.location_on_rounded, size: AppMapTokens.centerPinSize, color: context.colors.primary),
  );
}

class _PickerSkeleton extends StatelessWidget {
  const _PickerSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s48),
          SizedBox(height: AppSpacing.s16),
          SkeletonBox(height: AppMapTokens.mapHeight),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
        ],
      ),
    ),
  );
}
