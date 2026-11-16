import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/carpools/carpool_logic.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

final _areasProvider = FutureProvider.autoDispose.family<List<SchoolArea>, String>(
  (Ref ref, String schoolId) => ref.watch(carpoolRepositoryProvider).areas(schoolId),
);

/// Values to start the form with (from a "looking for a carpool" match).
class CreatePrefill {
  const CreatePrefill({this.schoolId, this.areaId, this.morning, this.afternoon, this.days});

  final String? schoolId;
  final String? areaId;
  final String? morning;
  final String? afternoon;
  final List<Weekday>? days;
}

/// Start a carpool (F5, F25, F36, F39) in four short steps with a progress
/// bar: 1 where (a child's school and area, or an activity place), 2 when
/// (morning and afternoon times, days), 3 who (children, seats up to the
/// car's passenger seats, the days you can drive), 4 rules and an optional
/// contribution per child. Each step says what to fix before Next.
///
/// States: loading (skeleton), no approved child (empty), error, offline;
/// no approved car (message with "Add your car"); the create call shows
/// progress and an inline error.
class CreateCarpoolScreen extends ConsumerStatefulWidget {
  const CreateCarpoolScreen({super.key, this.prefill = const CreatePrefill()});

  final CreatePrefill prefill;

  @override
  ConsumerState<CreateCarpoolScreen> createState() => _CreateCarpoolScreenState();
}

class _CreateCarpoolScreenState extends ConsumerState<CreateCarpoolScreen> {
  static const int _steps = 4;
  static const Duration _debounce = Duration(milliseconds: 400);

  int _step = 0;
  bool _tried = false;
  bool _saving = false;
  String? _error;

  // Step 1
  CarpoolKind _kind = CarpoolKind.school;
  String? _schoolId;
  String? _areaId;
  final TextEditingController _activityName = TextEditingController();
  final TextEditingController _placeQuery = TextEditingController();
  List<PlaceSuggestion> _suggestions = const <PlaceSuggestion>[];
  PlaceResult? _place;
  String? _sessionToken;
  Timer? _timer;
  int _placeRequest = 0;

  // Step 2
  String? _morning = RunTime.defaultMorning;
  String? _afternoon = RunTime.defaultAfternoon;
  List<Weekday> _days = Weekday.schoolDays;

  // Step 3
  final Set<String> _childIds = <String>{};
  int? _seats;
  List<Weekday> _driveDays = const <Weekday>[];

  // Step 4
  final Set<CarpoolRule> _rules = <CarpoolRule>{};
  bool _volunteer = false;
  bool _withContribution = false;
  final TextEditingController _amount = TextEditingController();
  ContributionPeriod _period = ContributionPeriod.week;
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    final CreatePrefill p = widget.prefill;
    _schoolId = p.schoolId;
    _areaId = p.areaId;
    if (p.morning != null || p.afternoon != null) {
      _morning = p.morning;
      _afternoon = p.afternoon;
    }
    final List<Weekday>? days = p.days;
    if (days != null && days.isNotEmpty) {
      _days = days;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _activityName.dispose();
    _placeQuery.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  void _onPlaceQuery(String _) {
    _timer?.cancel();
    final String text = _placeQuery.text.trim();
    if (text.length < 3) {
      _placeRequest++;
      setState(() => _suggestions = const <PlaceSuggestion>[]);
      return;
    }
    _sessionToken ??= newPlacesSessionToken();
    _timer = Timer(_debounce, () => unawaited(_searchPlaces(text)));
  }

  Future<void> _searchPlaces(String text) async {
    final int request = ++_placeRequest;
    final String language = Localizations.localeOf(context).languageCode;
    List<PlaceSuggestion> found = const <PlaceSuggestion>[];
    try {
      found = await ref
          .read(placesRepositoryProvider)
          .autocomplete(text, sessionToken: _sessionToken ?? newPlacesSessionToken(), language: language);
    } on MapFailure {
      found = const <PlaceSuggestion>[];
    }
    if (mounted && request == _placeRequest) {
      setState(() => _suggestions = found);
    }
  }

  Future<void> _pickPlace(PlaceSuggestion s) async {
    final String language = Localizations.localeOf(context).languageCode;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = context.l10n;
    final String token = _sessionToken ?? newPlacesSessionToken();
    _sessionToken = null;
    _placeRequest++;
    setState(() => _suggestions = const <PlaceSuggestion>[]);
    try {
      final PlaceResult place = await ref.read(placesRepositoryProvider).details(s.placeId, sessionToken: token, language: language);
      if (mounted) {
        setState(() => _place = place);
      }
    } on MapFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    }
  }

  /// What is wrong on the current step, or null when it is complete.
  String? _stepError(AppLocalizations l10n, List<ChildRecord> children, int? carSeats) {
    switch (_step) {
      case 0:
        if (_kind == CarpoolKind.school) {
          return _schoolId == null ? l10n.carpoolErrorPickSchool : null;
        }
        if (_activityName.text.trim().length < 2) {
          return l10n.carpoolErrorActivityName;
        }
        return _place == null ? l10n.carpoolErrorActivityPlace : null;
      case 1:
        if (_morning == null && _afternoon == null) {
          return l10n.carpoolErrorNoTime;
        }
        return _days.isEmpty ? l10n.carpoolErrorNoDays : null;
      case 2:
        if (carSeats == null) {
          return l10n.carpoolErrorNoCar;
        }
        if (_childIds.isEmpty) {
          return l10n.carpoolErrorPickChild;
        }
        return _childIds.length > _seatsFor(carSeats) ? l10n.carpoolErrorTooManyChildren : null;
      default:
        if (!_volunteer) {
          return l10n.volunteerError;
        }
        if (!_withContribution || !ref.read(featureSwitchesProvider).contributions) {
          return null;
        }
        return _amountValid ? null : l10n.contributionAmountError;
    }
  }

  bool get _amountValid {
    final int? amount = int.tryParse(_amount.text.trim());
    return amount != null && amount >= 1 && amount <= 10000;
  }

  CarpoolDraft _draft(int carSeats) {
    final PlaceResult? place = _place;
    final int? amount = int.tryParse(_amount.text.trim());
    return CarpoolDraft(
      kind: _kind,
      schoolId: _kind == CarpoolKind.school ? _schoolId : null,
      areaId: _kind == CarpoolKind.school ? _areaId : null,
      activity: _kind == CarpoolKind.activity && place != null
          ? ActivityPlace(name: _activityName.text.trim(), label: place.label, lat: place.location.lat, lng: place.location.lng)
          : null,
      morning: _morning,
      afternoon: _afternoon,
      days: _days,
      driveDays: _driveDays.where(_days.contains).toList(),
      seats: _seatsFor(carSeats),
      childIds: _childIds.toList(),
      rules: CarpoolRule.values.where(_rules.contains).toList(),
      contribution: _withContribution && amount != null && ref.read(featureSwitchesProvider).contributions
          ? Contribution(amount: amount, period: _period, note: _note.text.trim())
          : null,
    );
  }

  Future<void> _next(List<ChildRecord> children, int? carSeats) async {
    final AppLocalizations l10n = context.l10n;
    final String? error = _stepError(l10n, children, carSeats);
    if (error != null) {
      setState(() => _tried = true);
      return;
    }
    if (_step < _steps - 1) {
      setState(() {
        _step++;
        _tried = false;
        _error = null;
      });
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final String id = await ref.read(carpoolRepositoryProvider).create(_draft(carSeats ?? 1));
      showAppSnackBarOn(messenger, l10n.carpoolCreated);
      if (mounted) {
        context.go(CarpoolRoutes.detail(id));
      }
    } on CarpoolFailure catch (failure) {
      if (mounted) {
        setState(() => _error = failure.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _back() {
    if (_step == 0) {
      context.go(AppTab.carpools.path);
    } else {
      setState(() {
        _step--;
        _tried = false;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ChildRecord>> children = ref.watch(childrenProvider);
    final AsyncValue<VehicleRecord?> vehicle = ref.watch(vehicleProvider);
    final Object? error = children.error ?? vehicle.error;
    final Widget body;
    if (error != null) {
      body = carpoolErrorView(error, () {
        ref
          ..invalidate(childrenProvider)
          ..invalidate(vehicleProvider);
      });
    } else if (!children.hasValue || !vehicle.hasValue) {
      body = const CarpoolListSkeleton();
    } else {
      final List<ChildRecord> approved = (children.value ?? const <ChildRecord>[])
          .where((ChildRecord c) => c.status == ReviewStatus.approved)
          .toList();
      body = approved.isEmpty
          ? EmptyStateView(
              key: const Key('create.noChild'),
              icon: Icons.child_care_outlined,
              title: l10n.carpoolNoChildTitle,
              body: l10n.carpoolNoChildBody,
              actionLabel: l10n.carpoolAddChild,
              onAction: () => context.go(ProfileRoutes.children),
            )
          : _form(context, approved, _carSeats(vehicle.value));
    }
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _back();
        }
      },
      child: Scaffold(
        appBar: AppBar(title: AppBarTitle(l10n.carpoolCreate)),
        body: SafeArea(top: false, child: body),
      ),
    );
  }

  /// Seats offered: the parent's choice, never more than the car's passenger seats.
  int _seatsFor(int carSeats) {
    final int? chosen = _seats;
    return chosen != null && chosen >= 1 && chosen <= carSeats ? chosen : carSeats;
  }

  /// Passenger seats of an approved car with valid papers, or null.
  int? _carSeats(VehicleRecord? v) {
    if (v == null || v.status != ReviewStatus.approved || v.seats < 1) {
      return null;
    }
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    for (final DateTime? d in <DateTime?>[v.licenseExpiry, v.carLicenseExpiry]) {
      if (d == null || d.isBefore(today)) {
        return null;
      }
    }
    return v.seats;
  }

  Widget _form(BuildContext context, List<ChildRecord> approved, int? carSeats) {
    final AppLocalizations l10n = context.l10n;
    final String? stepError = _tried ? _stepError(l10n, approved, carSeats) : null;
    final String? saveError = _error;
    final Widget step = switch (_step) {
      0 => _where(context, approved),
      1 => _when(context),
      2 => _who(context, approved, carSeats),
      _ => _rulesStep(context),
    };
    return ListView(
      key: const Key('create.list'),
      padding: const EdgeInsetsDirectional.fromSTEB(0, AppSpacing.s16, 0, AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: AppStepProgress(current: _step + 1, total: _steps),
        ),
        step,
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s24, AppSpacing.screenGutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (stepError != null) ...<Widget>[
                AppInlineMessage(key: const Key('create.stepError'), message: stepError, tone: AppStateTone.error),
                const SizedBox(height: AppSpacing.s16),
              ],
              if (saveError != null) ...<Widget>[
                AppInlineMessage(key: const Key('create.saveError'), message: saveError, tone: AppStateTone.error),
                const SizedBox(height: AppSpacing.s16),
              ],
              AppButton(
                key: const Key('create.next'),
                label: _step == _steps - 1 ? l10n.carpoolCreateAction : l10n.actionNext,
                expand: true,
                loading: _saving,
                onPressed: _saving ? null : () => unawaited(_next(approved, carSeats)),
              ),
              if (_step > 0) ...<Widget>[
                const SizedBox(height: AppSpacing.s8),
                AppButton(
                  key: const Key('create.back'),
                  label: l10n.actionBack,
                  variant: AppButtonVariant.tertiary,
                  expand: true,
                  onPressed: _saving ? null : _back,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _where(BuildContext context, List<ChildRecord> approved) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final Map<String, String> schools = <String, String>{
      for (final ChildRecord c in approved)
        if (c.schoolId.isNotEmpty) c.schoolId: c.schoolName,
    };
    final List<SchoolArea> areas = _kind == CarpoolKind.school && _schoolId != null
        ? ref.watch(_areasProvider(_schoolId!)).value ?? const <SchoolArea>[]
        : const <SchoolArea>[];
    final PlaceResult? place = _place;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSectionHeader(l10n.carpoolStepWhere),
          Wrap(
            spacing: AppSpacing.s8,
            children: <Widget>[
              AppChip(
                key: const Key('create.kind.school'),
                label: l10n.carpoolKindSchool,
                icon: Icons.school_outlined,
                selected: _kind == CarpoolKind.school,
                onSelected: (bool _) => setState(() => _kind = CarpoolKind.school),
              ),
              // R9: activity carpools (F39) only while their switch is on.
              if (ref.watch(featureSwitchesProvider).activityCarpools)
                AppChip(
                  key: const Key('create.kind.activity'),
                  label: l10n.carpoolKindActivity,
                  icon: Icons.sports_soccer_outlined,
                  selected: _kind == CarpoolKind.activity,
                  onSelected: (bool _) => setState(() => _kind = CarpoolKind.activity),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s16),
          if (_kind == CarpoolKind.school) ...<Widget>[
            AppSelectField<String>(
              key: const Key('create.school'),
              label: l10n.carpoolSchoolLabel,
              options: <(String, String)>[for (final MapEntry<String, String> s in schools.entries) (s.key, s.value)],
              value: schools.containsKey(_schoolId) ? _schoolId : null,
              helperText: l10n.carpoolSchoolHelper,
              onChanged: (String v) => setState(() {
                _schoolId = v;
                _areaId = null;
                _childIds.clear();
              }),
            ),
            if (areas.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.s16),
              AppSelectField<String>(
                key: const Key('create.area'),
                label: l10n.carpoolAreaLabel,
                options: <(String, String)>[('', l10n.carpoolAnyArea), for (final SchoolArea a in areas) (a.id, a.name(language))],
                value: _areaId ?? '',
                onChanged: (String v) => setState(() => _areaId = v.isEmpty ? null : v),
              ),
            ],
          ] else ...<Widget>[
            AppTextField(
              key: const Key('create.activityName'),
              label: l10n.carpoolActivityNameLabel,
              hintText: l10n.carpoolActivityNameHint,
              controller: _activityName,
              maxLength: 60,
              onChanged: (String _) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.s16),
            AppTextField(
              key: const Key('create.place'),
              label: l10n.carpoolActivityPlaceLabel,
              helperText: l10n.carpoolActivityPlaceHelper,
              prefixIcon: Icons.search_rounded,
              controller: _placeQuery,
              onChanged: _onPlaceQuery,
            ),
            for (final PlaceSuggestion s in _suggestions)
              AppListRow(
                key: Key('create.suggestion.${s.placeId}'),
                title: s.primary,
                subtitle: s.secondary,
                leadingIcon: Icons.place_outlined,
                inset: false,
                showChevron: false,
                onTap: () => unawaited(_pickPlace(s)),
              ),
            if (place != null)
              AppListRow(
                key: const Key('create.placePicked'),
                title: place.label,
                subtitle: l10n.carpoolActivityPlacePicked,
                leadingIcon: Icons.check_circle_outline_rounded,
                inset: false,
                showChevron: false,
              ),
          ],
        ],
      ),
    );
  }

  Widget _when(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: AppSectionHeader(l10n.carpoolStepWhen),
        ),
        RunTimeField(
          key: const Key('create.morning'),
          title: l10n.carpoolMorningTitle,
          subtitle: l10n.carpoolMorningHelper,
          value: _morning,
          defaultTime: RunTime.defaultMorning,
          onChanged: (String? v) => setState(() => _morning = v),
        ),
        const SizedBox(height: AppSpacing.s8),
        RunTimeField(
          key: const Key('create.afternoon'),
          title: l10n.carpoolAfternoonTitle,
          subtitle: l10n.carpoolAfternoonHelper,
          value: _afternoon,
          defaultTime: RunTime.defaultAfternoon,
          onChanged: (String? v) => setState(() => _afternoon = v),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s24, AppSpacing.screenGutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.carpoolDaysLabel, style: context.text.labelLarge),
              const SizedBox(height: AppSpacing.s8),
              DaysPicker(
                selected: _days,
                keyPrefix: 'create.day',
                onChanged: (List<Weekday> d) => setState(() => _days = d),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _who(BuildContext context, List<ChildRecord> approved, int? carSeats) {
    final AppLocalizations l10n = context.l10n;
    final List<ChildRecord> riding = _kind == CarpoolKind.school
        ? approved.where((ChildRecord c) => c.schoolId == _schoolId).toList()
        : approved;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSectionHeader(l10n.carpoolStepWho),
          if (carSeats == null) ...<Widget>[
            AppInlineMessage(key: const Key('create.noCar'), message: l10n.carpoolNeedCar, tone: AppStateTone.warning),
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              key: const Key('create.addCar'),
              label: l10n.carpoolAddCar,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () => context.go(ProfileRoutes.driving),
            ),
          ] else ...<Widget>[
            Text(l10n.carpoolChildrenLabel, style: context.text.labelLarge),
            for (final ChildRecord c in riding)
              AppCheckRow(
                key: Key('create.child.${c.id}'),
                label: l10n.childWithGrade(c.firstName, gradeLabel(l10n, c.grade)),
                value: _childIds.contains(c.id),
                onChanged: (bool on) => setState(() => on ? _childIds.add(c.id) : _childIds.remove(c.id)),
              ),
            const SizedBox(height: AppSpacing.s16),
            AppSelectField<int>(
              key: const Key('create.seats'),
              label: l10n.carpoolSeatsLabel,
              helperText: l10n.carpoolSeatsHelper(carSeats),
              options: <(int, String)>[for (final int s in seatChoices(carSeats)) (s, l10n.carpoolSeatsCount(s))],
              value: _seatsFor(carSeats),
              onChanged: (int v) => setState(() => _seats = v),
            ),
            const SizedBox(height: AppSpacing.s24),
            Text(l10n.carpoolDriveDaysLabel, style: context.text.labelLarge),
            Text(
              l10n.carpoolDriveDaysHelper,
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.s8),
            DaysPicker(
              selected: _driveDays,
              only: _days,
              keyPrefix: 'create.driveDay',
              onChanged: (List<Weekday> d) => setState(() => _driveDays = d),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rulesStep(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppSectionHeader(l10n.carpoolStepRules),
          Text(l10n.carpoolRulesHelper, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              for (final CarpoolRule r in CarpoolRule.values)
                AppChip(
                  key: Key('create.rule.${r.code}'),
                  label: ruleLabel(l10n, r),
                  selected: _rules.contains(r),
                  onSelected: (bool on) => setState(() => on ? _rules.add(r) : _rules.remove(r)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s16),
          AppCheckRow(
            key: const Key('create.volunteer'),
            label: l10n.volunteerAccept,
            helperText: l10n.volunteerAcceptHelper,
            value: _volunteer,
            onChanged: (bool on) => setState(() => _volunteer = on),
          ),
          // No money in the app (owner, 16 Nov 2026): the contribution per
          // child (F25) only while its switch is on.
          if (ref.watch(featureSwitchesProvider).contributions) ...<Widget>[
            AppSectionHeader(l10n.contributionSection),
            AppSwitchRow(
              key: const Key('create.contribution'),
              title: l10n.contributionSwitch,
              subtitle: contributionHelperText(l10n, ref.watch(featureSwitchesProvider)),
              value: _withContribution,
              onChanged: (bool on) => setState(() => _withContribution = on),
            ),
            if (_withContribution) ...<Widget>[
              const SizedBox(height: AppSpacing.s8),
              AppTextField(
                key: const Key('create.amount'),
                label: l10n.contributionAmountLabel,
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
                maxLength: 5,
                textDirection: TextDirection.ltr,
                errorText: _tried && !_amountValid ? l10n.contributionAmountError : null,
                onChanged: (String _) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.s16),
              AppSelectField<ContributionPeriod>(
                key: const Key('create.period'),
                label: l10n.contributionPeriodLabel,
                options: <(ContributionPeriod, String)>[
                  for (final ContributionPeriod p in ContributionPeriod.values) (p, periodLabel(l10n, p)),
                ],
                value: _period,
                onChanged: (ContributionPeriod p) => setState(() => _period = p),
              ),
              const SizedBox(height: AppSpacing.s16),
              AppTextField(
                key: const Key('create.note'),
                label: l10n.contributionNoteLabel,
                hintText: l10n.contributionNoteHint,
                controller: _note,
                maxLength: 120,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
