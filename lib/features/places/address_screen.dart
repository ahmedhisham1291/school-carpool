import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_models.dart' show kGovernorates;
import 'package:school_carpool/admin/widgets/admin_labels.dart' show governorateLabel;
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/places/address_models.dart';
import 'package:school_carpool/features/places/address_repository.dart';
import 'package:school_carpool/features/places/place_models.dart';
import 'package:school_carpool/features/places/place_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _areasProvider = FutureProvider.autoDispose.family<List<PlaceArea>, String>(
  (Ref ref, String governorate) => ref.watch(placeRepositoryProvider).areas(governorate),
);

final _districtsProvider = FutureProvider.autoDispose.family<List<PlaceDistrict>, String>(
  (Ref ref, String areaId) => ref.watch(placeRepositoryProvider).districts(areaId),
);

/// The value of "My district isn't listed" in the District menu.
const String kDistrictNotListed = '__not_listed__';

/// Home address (F46, spec addendum "Address"): three short steps with a
/// progress bar.
///
/// 1. Place: City, Area and District dropdowns (filterable; Area waits for
///    City and District for Area; a new parent clears its children). The
///    District menu ends with "My district isn't listed", which opens a
///    text field (the admins review it). "Search instead" opens the address
///    search and fills the three from the chosen place.
/// 2. Street and building (checked as the parent types, with how to fix),
///    then optional floor, apartment and landmark.
/// 3. The pin: the server searches the address once and the map starts
///    there (or at the district when it found nothing: "move the map");
///    the parent moves the map under the pin and saves.
///
/// The exact pin and the street stay private (homes/{uid}); other parents
/// see the rounded point and the area only.
///
/// States: areas/districts loading (menu disabled, "Loading areas"), none
/// for the city (hint), error and offline (message with retry); the pin
/// step has loading (skeleton), error (start from the city and move the
/// map) and offline (retry); saving shows progress on the button.
class AddressScreen extends ConsumerStatefulWidget {
  const AddressScreen({super.key});

  @override
  ConsumerState<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends ConsumerState<AddressScreen> {
  static const int _steps = 3;

  int _step = 1;
  String? _city;
  String? _areaId;
  String? _districtId;
  bool _attemptedPlace = false;
  bool _attemptedStreet = false;

  final TextEditingController _districtText = TextEditingController();
  final TextEditingController _street = TextEditingController();
  final TextEditingController _building = TextEditingController();
  final TextEditingController _floor = TextEditingController();
  final TextEditingController _apartment = TextEditingController();
  final TextEditingController _landmark = TextEditingController();

  /// The pin: from "Search instead", the address search, or the parent.
  GeoPin? _pin;
  bool _approximate = false;
  HomeAddress? _geocodedFor;
  bool _locating = false;
  AddressFailure? _locateFailure;
  MapCameraController? _camera;

  bool _saving = false;
  String? _saveError;

  /// Set once the saved address was put in the form (or the parent started typing).
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    // Editing: start from the saved address (the parent changes a part),
    // as soon as the home is loaded, unless the parent already started.
    ref.listenManual<AsyncValue<HomeLocation?>>(
      myHomeProvider,
      (AsyncValue<HomeLocation?>? _, AsyncValue<HomeLocation?> next) {
        final HomeLocation? home = next.value;
        if (!_prefilled && home?.address != null) {
          setState(() => _prefill(home!));
        }
      },
      fireImmediately: true,
    );
    for (final TextEditingController c in <TextEditingController>[_districtText, _street, _building, _floor, _apartment, _landmark]) {
      c.addListener(_changed);
    }
  }

  void _prefill(HomeLocation home) {
    final HomeAddress? saved = home.address;
    if (saved == null) {
      return;
    }
    _prefilled = true;
    _city = saved.governorate;
    _areaId = saved.placeAreaId;
    _districtId = saved.placeDistrictId ?? (saved.districtText.isNotEmpty ? kDistrictNotListed : null);
    _districtText.text = saved.districtText;
    _street.text = saved.street;
    _building.text = saved.building;
    _floor.text = saved.floor;
    _apartment.text = saved.apartment;
    _landmark.text = saved.landmark;
    _pin = home.location;
    _geocodedFor = _draft();
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_districtText, _street, _building, _floor, _apartment, _landmark]) {
      c.dispose();
    }
    _camera?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- state

  void _pickCity(String city) {
    _prefilled = true;
    if (city == _city) {
      return;
    }
    setState(() {
      _city = city;
      _areaId = null;
      _districtId = null;
      _districtText.clear();
    });
  }

  void _pickArea(String areaId) {
    if (areaId == _areaId) {
      return;
    }
    setState(() {
      _areaId = areaId;
      _districtId = null;
      _districtText.clear();
    });
  }

  void _pickDistrict(String id) => setState(() => _districtId = id);

  bool get _notListed => _districtId == kDistrictNotListed;

  bool get _placeReady =>
      _city != null && _areaId != null && _districtId != null && (!_notListed || AddressRules.districtText(_districtText.text) == null);

  bool get _streetReady =>
      AddressRules.street(_street.text) == null &&
      AddressRules.building(_building.text) == null &&
      AddressRules.shortExtra(_floor.text) == null &&
      AddressRules.shortExtra(_apartment.text) == null &&
      AddressRules.landmark(_landmark.text) == null;

  HomeAddress? _draft() {
    final String? city = _city;
    final String? area = _areaId;
    final String? district = _districtId;
    if (city == null || area == null || district == null) {
      return null;
    }
    return HomeAddress(
      governorate: city,
      placeAreaId: area,
      placeDistrictId: district == kDistrictNotListed ? null : district,
      districtText: district == kDistrictNotListed ? AddressRules.clean(_districtText.text) : '',
      street: AddressRules.clean(_street.text),
      building: AddressRules.clean(_building.text),
      floor: AddressRules.clean(_floor.text),
      apartment: AddressRules.clean(_apartment.text),
      landmark: AddressRules.clean(_landmark.text),
    );
  }

  String? _problem(AddressFieldProblem? p, {required String fix}) {
    final AppLocalizations l10n = context.l10n;
    return switch (p) {
      null => null,
      AddressFieldProblem.required => l10n.addressRequired,
      AddressFieldProblem.tooShort => fix,
      AddressFieldProblem.tooLong => l10n.addressTooLong,
      AddressFieldProblem.characters => fix,
    };
  }

  /// An error under a field once the parent has typed in it or pressed Next.
  String? _fieldError(TextEditingController c, AddressFieldProblem? p, {required String fix, required bool attempted}) =>
      (attempted || c.text.isNotEmpty) ? _problem(p, fix: fix) : null;

  // ---------------------------------------------------------------- actions

  Future<void> _searchInstead() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlaceResult? place = await Navigator.of(context).push<PlaceResult>(
      MaterialPageRoute<PlaceResult>(builder: (BuildContext context) => const HomeLocationScreen(pickOnly: true)),
    );
    if (place == null || !mounted) {
      return;
    }
    try {
      final PlaceHit hit = await ref.read(addressRepositoryProvider).placeForPoint(place.location);
      if (!mounted) {
        return;
      }
      setState(() {
        _pin = place.location;
        _approximate = false;
        _city = hit.governorate ?? _city;
        _areaId = hit.placeAreaId;
        _districtId = hit.placeDistrictId;
        _districtText.clear();
        // The chosen place is the pin: no second search for it.
        _geocodedFor = null;
      });
      showAppSnackBarOn(messenger, hit.placeAreaId == null ? l10n.addressSearchNoArea : l10n.addressSearchFilled);
    } on AddressFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    }
  }

  void _next() {
    if (_step == 1) {
      setState(() => _attemptedPlace = true);
      if (_placeReady) {
        setState(() => _step = 2);
      }
      return;
    }
    if (_step == 2) {
      setState(() => _attemptedStreet = true);
      if (_streetReady) {
        setState(() => _step = 3);
        unawaited(_locate());
      }
    }
  }

  void _back() {
    if (_step > 1) {
      setState(() => _step--);
    }
  }

  /// Finds the start pin once per address (a pin from "Search instead" is used as it is).
  Future<void> _locate({bool force = false}) async {
    final HomeAddress? draft = _draft();
    if (draft == null) {
      return;
    }
    if (!force && _pin != null && (_geocodedFor == null || _geocodedFor == draft)) {
      _moveCamera(_pin!);
      return;
    }
    final String language = Localizations.localeOf(context).languageCode;
    setState(() {
      _locating = true;
      _locateFailure = null;
    });
    try {
      final GeocodeResult result = await ref
          .read(addressRepositoryProvider)
          .geocode(draft, sessionToken: newPlacesSessionToken(), language: language);
      if (!mounted) {
        return;
      }
      setState(() {
        _pin = result.location ?? _pin ?? Geo.cairo;
        _approximate = result.approximate || result.location == null;
        _geocodedFor = draft;
      });
      _moveCamera(_pin!);
    } on AddressFailure catch (failure) {
      if (mounted) {
        setState(() => _locateFailure = failure);
      }
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  void _moveCamera(GeoPin at) {
    final MapCameraController? camera = _camera;
    if (camera == null) {
      _camera = MapCameraController(center: at, zoom: AppMapTokens.streetZoom);
    } else {
      camera.moveTo(at, zoom: AppMapTokens.streetZoom);
    }
  }

  /// Error (not offline): start from where we are and let the parent place the pin.
  void _placeMyself() {
    setState(() {
      _locateFailure = null;
      _pin ??= Geo.cairo;
      _approximate = true;
    });
    _moveCamera(_pin!);
  }

  Future<void> _save() async {
    final HomeAddress? draft = _draft();
    final GeoPin? pin = _pin;
    if (draft == null || pin == null) {
      return;
    }
    final AppLocalizations l10n = context.l10n;
    if (!Geo.inEgypt(pin)) {
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
      await ref.read(addressRepositoryProvider).save(draft, pin);
      showAppSnackBarOn(messenger, l10n.addressSaved);
      if (mounted && navigator.canPop()) {
        navigator.pop();
      }
    } on AddressFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saveError = failure.message(l10n);
        // Take the parent to the part to fix.
        if (failure.kind == AddressFailureKind.area || failure.kind == AddressFailureKind.district) {
          _step = 1;
        } else if (failure.kind == AddressFailureKind.street ||
            failure.kind == AddressFailureKind.building ||
            failure.kind == AddressFailureKind.extra) {
          _step = 2;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  // ---------------------------------------------------------------- views

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return PopScope(
      canPop: _step == 1,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          _back();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: AppBarTitle(l10n.addressTitle)),
        body: SafeArea(
          top: false,
          child: switch (_step) {
            1 => _placeStep(context),
            2 => _streetStep(context),
            _ => _pinStep(context),
          },
        ),
      ),
    );
  }

  Widget _scroll(List<Widget> children, Widget action) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Expanded(
        child: ListView(
          padding: AppSpacing.screenPadding,
          children: children,
        ),
      ),
      Padding(padding: AppSpacing.screenPadding, child: action),
    ],
  );

  Widget _placeStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final String? city = _city;
    final String? areaId = _areaId;
    final AsyncValue<List<PlaceArea>>? areas = city == null ? null : ref.watch(_areasProvider(city));
    final AsyncValue<List<PlaceDistrict>>? districts = areaId == null ? null : ref.watch(_districtsProvider(areaId));
    final List<PlaceArea> areaList = sortByName(areas?.value ?? const <PlaceArea>[], (PlaceArea a) => a.name(language));
    final List<PlaceDistrict> districtList = sortByName(districts?.value ?? const <PlaceDistrict>[], (PlaceDistrict d) => d.name(language));
    final Object? loadError = areas?.error ?? districts?.error;
    final bool districtsLoading = districts is AsyncLoading<List<PlaceDistrict>>;

    return _scroll(
      <Widget>[
        const AppStepProgress(current: 1, total: _steps),
        const SizedBox(height: AppSpacing.s24),
        OneLineText(l10n.addressPlaceTitle, style: context.text.titleLarge, scaleDown: true),
        const SizedBox(height: AppSpacing.s16),
        AppDropdownMenu<String>(
          key: const Key('address.city'),
          label: l10n.placeCityLabel,
          hintText: l10n.placeCityHint,
          leadingIcon: Icons.location_city_outlined,
          value: city,
          errorText: _attemptedPlace && city == null ? l10n.addressChooseCity : null,
          items: sortByName(
            <AppDropdownItem<String>>[for (final String g in kGovernorates) AppDropdownItem<String>(g, governorateLabel(l10n, g))],
            (AppDropdownItem<String> i) => i.label,
          ),
          onSelected: _pickCity,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppDropdownMenu<String>(
          key: Key('address.area.${city ?? ''}'),
          label: l10n.placeAreaLabel,
          hintText: l10n.placeAreaHint,
          leadingIcon: Icons.map_outlined,
          value: areaId,
          helperText: switch (areas) {
            null => l10n.placeAreaWaitCity,
            AsyncLoading<List<PlaceArea>>() => l10n.placeAreasLoading,
            AsyncData<List<PlaceArea>>(:final List<PlaceArea> value) when value.isEmpty => l10n.addressNoAreas,
            _ => null,
          },
          errorText: _attemptedPlace && city != null && areaId == null ? l10n.addressChooseArea : null,
          items: <AppDropdownItem<String>>[for (final PlaceArea a in areaList) AppDropdownItem<String>(a.id, a.name(language))],
          onSelected: areaList.isEmpty ? null : _pickArea,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppDropdownMenu<String>(
          key: Key('address.district.${areaId ?? ''}'),
          label: l10n.placeDistrictLabel,
          hintText: l10n.placeAreaHint,
          leadingIcon: Icons.place_outlined,
          value: _districtId,
          helperText: areaId == null ? l10n.addressDistrictWaitArea : (districtsLoading ? l10n.addressDistrictsLoading : null),
          errorText: _attemptedPlace && areaId != null && _districtId == null ? l10n.addressChooseDistrict : null,
          items: <AppDropdownItem<String>>[for (final PlaceDistrict d in districtList) AppDropdownItem<String>(d.id, d.name(language))],
          pinnedLast: AppDropdownItem<String>(kDistrictNotListed, l10n.addressDistrictNotListed, icon: Icons.edit_outlined),
          onSelected: areaId == null || districtsLoading ? null : _pickDistrict,
        ),
        if (_notListed) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('address.districtText'),
            label: l10n.addressDistrictTextLabel,
            helperText: l10n.addressDistrictTextHelper,
            controller: _districtText,
            maxLength: 80,
            textInputAction: TextInputAction.done,
            errorText: _fieldError(
              _districtText,
              AddressRules.districtText(_districtText.text),
              fix: l10n.addressDistrictTextFix,
              attempted: _attemptedPlace,
            ),
          ),
        ],
        if (loadError != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(
            key: const Key('address.loadError'),
            message: PlaceFailure.from(loadError).isOffline ? l10n.errorOfflineShort : l10n.placeLoadError,
            tone: AppStateTone.error,
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              label: l10n.actionRetry,
              variant: AppButtonVariant.tertiary,
              onPressed: () {
                if (city != null) {
                  ref.invalidate(_areasProvider(city));
                }
                if (areaId != null) {
                  ref.invalidate(_districtsProvider(areaId));
                }
              },
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.s8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppButton(
            key: const Key('address.search'),
            label: l10n.addressSearchInstead,
            icon: Icons.search_rounded,
            variant: AppButtonVariant.tertiary,
            onPressed: () => unawaited(_searchInstead()),
          ),
        ),
      ],
      AppButton(key: const Key('address.next1'), label: l10n.addressNext, expand: true, onPressed: _next),
    );
  }

  Widget _streetStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return _scroll(
      <Widget>[
        const AppStepProgress(current: 2, total: _steps),
        const SizedBox(height: AppSpacing.s24),
        OneLineText(l10n.addressStreetTitle, style: context.text.titleLarge, scaleDown: true),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('address.street'),
          label: l10n.addressStreetLabel,
          hintText: l10n.addressStreetHint,
          controller: _street,
          maxLength: 120,
          textInputAction: TextInputAction.next,
          errorText: _fieldError(_street, AddressRules.street(_street.text), fix: l10n.addressStreetError, attempted: _attemptedStreet),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('address.building'),
          label: l10n.addressBuildingLabel,
          hintText: l10n.addressBuildingHint,
          controller: _building,
          maxLength: 10,
          textInputAction: TextInputAction.next,
          errorText: _fieldError(_building, AddressRules.building(_building.text), fix: l10n.addressBuildingError, attempted: _attemptedStreet),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSectionHeader(l10n.addressOptionalHeader),
        AppTextField(
          key: const Key('address.floor'),
          label: l10n.addressFloorLabel,
          controller: _floor,
          maxLength: 10,
          textInputAction: TextInputAction.next,
          errorText: _fieldError(_floor, AddressRules.shortExtra(_floor.text), fix: l10n.addressExtraError, attempted: _attemptedStreet),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('address.apartment'),
          label: l10n.addressApartmentLabel,
          controller: _apartment,
          maxLength: 10,
          textInputAction: TextInputAction.next,
          errorText: _fieldError(_apartment, AddressRules.shortExtra(_apartment.text), fix: l10n.addressExtraError, attempted: _attemptedStreet),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('address.landmark'),
          label: l10n.addressLandmarkLabel,
          hintText: l10n.addressLandmarkHint,
          controller: _landmark,
          maxLength: 120,
          textInputAction: TextInputAction.done,
          errorText: _fieldError(_landmark, AddressRules.landmark(_landmark.text), fix: l10n.addressExtraError, attempted: _attemptedStreet),
        ),
      ],
      AppButton(key: const Key('address.next2'), label: l10n.addressNext, expand: true, onPressed: _next),
    );
  }

  Widget _pinStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AddressFailure? failure = _locateFailure;
    final GeoPin? pin = _pin;
    final MapCameraController? camera = _camera;
    if (_locating) {
      return const Skeleton(
        key: Key('address.locating'),
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
    if (failure != null) {
      return failure.isOffline
          ? OfflineStateView(onRetry: () => unawaited(_locate(force: true)))
          : ErrorStateView(
              key: const Key('address.locateError'),
              body: l10n.addressLocateError,
              onRetry: _placeMyself,
            );
    }
    if (pin == null || camera == null) {
      return const SizedBox.shrink();
    }
    final String? saveError = _saveError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, AppSpacing.s8),
          child: AppStepProgress(current: 3, total: _steps),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: AppMapView(
                  config: MapViewConfig(
                    camera: camera,
                    semanticLabel: l10n.addressMapLabel,
                    onCameraIdle: (GeoPin center) => setState(() {
                      _pin = center;
                      _saveError = null;
                    }),
                  ),
                ),
              ),
              // The pin's tip marks the middle of the map.
              IgnorePointer(
                child: Align(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(bottom: AppMapTokens.centerPinSize),
                    child: ExcludeSemantics(
                      child: Icon(Icons.location_on_rounded, size: AppMapTokens.centerPinSize, color: context.colors.primary),
                    ),
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
              Text(
                _draft()?.label(Localizations.localeOf(context).languageCode) ?? '',
                key: const Key('address.summary'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.titleSmall,
              ),
              const SizedBox(height: AppSpacing.s8),
              AppInlineMessage(
                key: const Key('address.pinHint'),
                message: _approximate ? l10n.addressPinApproximate : l10n.addressPinHint,
                icon: _approximate ? Icons.info_outline : Icons.pan_tool_alt_outlined,
                tone: _approximate ? AppStateTone.warning : AppStateTone.neutral,
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(l10n.homePrivacyNote, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
              if (saveError != null) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(key: const Key('address.error'), message: saveError, tone: AppStateTone.error),
              ],
              const SizedBox(height: AppSpacing.s16),
              AppButton(
                key: const Key('address.save'),
                label: l10n.addressSave,
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
