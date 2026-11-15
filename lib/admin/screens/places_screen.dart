import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/data/admin_places.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/places/place_models.dart' show sortByName;
import 'package:school_carpool/l10n/l10n.dart';

final _areasProvider = FutureProvider.autoDispose.family<List<AdminPlace>, String>(
  (Ref ref, String governorate) => ref.watch(adminPlacesApiProvider).areas(governorate),
);

final _districtsProvider = FutureProvider.autoDispose.family<List<AdminPlace>, String>(
  (Ref ref, String areaId) => ref.watch(adminPlacesApiProvider).districts(areaId),
);

final _requestsProvider = FutureProvider.autoDispose<List<AdminPlaceRequest>>(
  (Ref ref) => ref.watch(adminPlacesApiProvider).requests(),
);

/// Places (F4 grouping, F46 addresses): City -> Area -> District with the
/// number of schools and addresses, add, rename, deactivate and merge
/// duplicates; and the queue of districts parents typed ("my district
/// isn't listed"). Every change goes through an audited admin function.
///
/// States: no city yet (hint), loading (skeleton), empty (no areas: add
/// one), error and offline (retry), for areas, districts and requests.
class PlacesScreen extends StatelessWidget {
  const PlacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return DefaultTabController(
      length: 2,
      child: AdminPage(
        title: l10n.adminPlacesTitle,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TabBar(
              tabs: <Widget>[
                Tab(key: const Key('places.tab.places'), child: OneLineText(l10n.adminPlacesTab)),
                Tab(key: const Key('places.tab.requests'), child: OneLineText(l10n.adminPlaceRequestsTab)),
              ],
            ),
            const Expanded(child: TabBarView(children: <Widget>[_PlacesTab(), _RequestsTab()])),
          ],
        ),
      ),
    );
  }
}

class _PlacesTab extends ConsumerStatefulWidget {
  const _PlacesTab();

  @override
  ConsumerState<_PlacesTab> createState() => _PlacesTabState();
}

class _PlacesTabState extends ConsumerState<_PlacesTab> {
  String? _city;
  AdminPlace? _area;

  Future<void> _run(Future<void> Function() body, String done) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await body();
      showAppSnackBarOn(messenger, done);
    } on AdminFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    }
  }

  void _refresh() {
    final String? city = _city;
    if (city != null) {
      ref.invalidate(_areasProvider(city));
    }
    final AdminPlace? area = _area;
    if (area != null) {
      ref.invalidate(_districtsProvider(area.id));
    }
  }

  Future<void> _addOrRename(PlaceLevel level, [AdminPlace? place]) async {
    final AppLocalizations l10n = context.l10n;
    final String? city = _city;
    final AdminPlace? area = _area;
    final (String, String)? names = await showAppSheet<(String, String)>(
      context: context,
      title: place == null
          ? (level == PlaceLevel.area ? l10n.adminAddArea : l10n.adminAddDistrict)
          : l10n.adminRenamePlace,
      body: PlaceNameForm(nameAr: place?.nameAr ?? '', nameEn: place?.nameEn ?? ''),
    );
    if (names == null || !mounted) {
      return;
    }
    final AdminPlacesApi api = ref.read(adminPlacesApiProvider);
    await _run(() async {
      if (level == PlaceLevel.area) {
        await api.saveArea(nameAr: names.$1, nameEn: names.$2, id: place?.id, governorate: place == null ? city : null);
      } else {
        await api.saveDistrict(nameAr: names.$1, nameEn: names.$2, id: place?.id, areaId: place == null ? area?.id : null);
      }
      _refresh();
    }, l10n.adminSaved);
  }

  Future<void> _toggle(PlaceLevel level, AdminPlace place) async {
    final AppLocalizations l10n = context.l10n;
    if (place.active) {
      final bool ok = await showConfirmDialog(
        context: context,
        title: l10n.adminDeactivatePlaceTitle,
        body: l10n.adminDeactivatePlaceBody,
        confirmLabel: l10n.adminDeactivatePlace,
        destructive: true,
      );
      if (!ok || !mounted) {
        return;
      }
    }
    await _run(() async {
      await ref.read(adminPlacesApiProvider).setActive(level: level, id: place.id, active: !place.active);
      _refresh();
    }, l10n.adminSaved);
  }

  Future<void> _merge(PlaceLevel level, AdminPlace from, List<AdminPlace> siblings) async {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final AdminPlace? into = await showAppSheet<AdminPlace>(
      context: context,
      title: l10n.adminMergePlaceTitle(from.name(language)),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final AdminPlace p in siblings)
            if (p.id != from.id && p.active)
              AppListRow(
                key: Key('places.mergeInto.${p.id}'),
                title: p.name(language),
                subtitle: l10n.adminPlaceCounts(p.schoolCount, p.addressCount),
                inset: false,
                onTap: () => Navigator.of(context).pop(p),
              ),
        ],
      ),
    );
    if (into == null || !mounted) {
      return;
    }
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.adminMergeConfirmTitle,
      body: l10n.adminMergePlaceConfirmBody(from.name(language), into.name(language)),
      confirmLabel: l10n.adminMerge,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    await _run(() async {
      await ref.read(adminPlacesApiProvider).merge(level: level, fromId: from.id, intoId: into.id);
      if (level == PlaceLevel.area && _area?.id == from.id) {
        setState(() => _area = null);
      }
      _refresh();
    }, l10n.adminPlaceMerged);
  }

  Widget _row(PlaceLevel level, AdminPlace p, List<AdminPlace> siblings, {VoidCallback? onTap, bool selected = false}) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final String other = language == 'ar' ? p.nameEn : p.nameAr;
    return AppListRow(
      key: Key('places.${level.wire}.${p.id}'),
      title: p.name(language),
      subtitle: <String>[
        if (other.isNotEmpty) other,
        l10n.adminPlaceCounts(p.schoolCount, p.addressCount),
        if (!p.active) l10n.adminPlaceInactive,
        if (p.source == 'admin') l10n.adminPlaceAddedByAdmin,
      ].join(' · '),
      leadingIcon: selected ? Icons.radio_button_checked : (level == PlaceLevel.area ? Icons.map_outlined : Icons.place_outlined),
      showChevron: false,
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        key: Key('places.menu.${p.id}'),
        tooltip: l10n.adminPlaceActions,
        onSelected: (String action) => unawaited(switch (action) {
          'rename' => _addOrRename(level, p),
          'toggle' => _toggle(level, p),
          _ => _merge(level, p, siblings),
        }),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'rename', child: OneLineText(l10n.adminRenamePlace)),
          PopupMenuItem<String>(
            value: 'toggle',
            child: OneLineText(p.active ? l10n.adminDeactivatePlace : l10n.adminActivatePlace),
          ),
          if (p.active) PopupMenuItem<String>(value: 'merge', child: OneLineText(l10n.adminMergePlace)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final String? city = _city;
    final AdminPlace? area = _area;
    return ListView(
      key: const Key('places.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: AppDropdownMenu<String>(
            key: const Key('places.city'),
            label: l10n.placeCityLabel,
            hintText: l10n.placeCityHint,
            leadingIcon: Icons.location_city_outlined,
            value: city,
            items: sortByName(
              <AppDropdownItem<String>>[for (final String g in kGovernorates) AppDropdownItem<String>(g, governorateLabel(l10n, g))],
              (AppDropdownItem<String> i) => i.label,
            ),
            onSelected: (String g) => setState(() {
              _city = g;
              _area = null;
            }),
          ),
        ),
        if (city == null)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Text(l10n.adminPlacesHint, key: const Key('places.hint')),
          )
        else ...<Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Row(
              children: <Widget>[
                Expanded(child: AppSectionHeader(l10n.placeAreasHeader)),
                AppButton(
                  key: const Key('places.addArea'),
                  label: l10n.adminAddArea,
                  icon: Icons.add,
                  onPressed: () => unawaited(_addOrRename(PlaceLevel.area)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: AppSpacing.s64 * 5,
            child: AdminAsyncView<List<AdminPlace>>(
              value: ref.watch(_areasProvider(city)),
              onRetry: () => ref.invalidate(_areasProvider(city)),
              isEmpty: (List<AdminPlace> a) => a.isEmpty,
              empty: EmptyStateView(icon: Icons.map_outlined, title: l10n.adminPlacesEmptyTitle, body: l10n.adminPlacesEmptyBody),
              builder: (List<AdminPlace> areas) {
                final List<AdminPlace> sorted = sortByName(areas, (AdminPlace a) => a.name(language));
                return ListView(
                  children: <Widget>[
                    for (final AdminPlace a in sorted)
                      _row(PlaceLevel.area, a, sorted, selected: a.id == area?.id, onTap: () => setState(() => _area = a)),
                  ],
                );
              },
            ),
          ),
          if (area != null) ...<Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
              child: Row(
                children: <Widget>[
                  Expanded(child: AppSectionHeader(l10n.placeDistrictsOf(area.name(language)))),
                  AppButton(
                    key: const Key('places.addDistrict'),
                    label: l10n.adminAddDistrict,
                    icon: Icons.add,
                    variant: AppButtonVariant.secondary,
                    onPressed: () => unawaited(_addOrRename(PlaceLevel.district)),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: AppSpacing.s64 * 5,
              child: AdminAsyncView<List<AdminPlace>>(
                value: ref.watch(_districtsProvider(area.id)),
                onRetry: () => ref.invalidate(_districtsProvider(area.id)),
                isEmpty: (List<AdminPlace> d) => d.isEmpty,
                empty: EmptyStateView(icon: Icons.place_outlined, title: l10n.adminDistrictsEmptyTitle, body: l10n.adminDistrictsEmptyBody),
                builder: (List<AdminPlace> districts) {
                  final List<AdminPlace> sorted = sortByName(districts, (AdminPlace d) => d.name(language));
                  return ListView(
                    children: <Widget>[for (final AdminPlace d in sorted) _row(PlaceLevel.district, d, sorted)],
                  );
                },
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  Future<void> _resolve(BuildContext context, WidgetRef ref, AdminPlaceRequest r, PlaceRequestAction action) async {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AdminPlacesApi api = ref.read(adminPlacesApiProvider);
    String? districtId;
    (String, String)? names;
    switch (action) {
      case PlaceRequestAction.create:
        names = await showAppSheet<(String, String)>(
          context: context,
          title: l10n.adminAddDistrict,
          body: PlaceNameForm(nameAr: r.text, nameEn: ''),
        );
        if (names == null) {
          return;
        }
      case PlaceRequestAction.map:
        final List<AdminPlace> districts;
        try {
          districts = await api.districts(r.areaId);
        } on AdminFailure catch (failure) {
          showAppSnackBarOn(messenger, failure.message(l10n));
          return;
        }
        if (!context.mounted) {
          return;
        }
        final AdminPlace? chosen = await showAppSheet<AdminPlace>(
          context: context,
          title: l10n.adminPlaceRequestMapTitle(r.text),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final AdminPlace d in sortByName(districts.where((AdminPlace d) => d.active), (AdminPlace d) => d.name(language)))
                AppListRow(
                  key: Key('places.mapTo.${d.id}'),
                  title: d.name(language),
                  inset: false,
                  onTap: () => Navigator.of(context).pop(d),
                ),
            ],
          ),
        );
        if (chosen == null) {
          return;
        }
        districtId = chosen.id;
      case PlaceRequestAction.dismiss:
        final bool ok = await showConfirmDialog(
          context: context,
          title: l10n.adminPlaceRequestDismissTitle,
          body: l10n.adminPlaceRequestDismissBody,
          confirmLabel: l10n.adminPlaceRequestDismiss,
        );
        if (!ok) {
          return;
        }
    }
    try {
      await api.resolveRequest(id: r.id, action: action, districtId: districtId, nameAr: names?.$1, nameEn: names?.$2);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      ref.invalidate(_requestsProvider);
    } on AdminFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    return AdminAsyncView<List<AdminPlaceRequest>>(
      value: ref.watch(_requestsProvider),
      onRetry: () => ref.invalidate(_requestsProvider),
      isEmpty: (List<AdminPlaceRequest> r) => r.isEmpty,
      empty: EmptyStateView(icon: Icons.inbox_outlined, title: l10n.adminPlaceRequestsEmptyTitle, body: l10n.adminPlaceRequestsEmptyBody),
      builder: (List<AdminPlaceRequest> requests) => ListView(
        key: const Key('places.requests'),
        children: <Widget>[
          for (final AdminPlaceRequest r in requests)
            AppListRow(
              key: Key('places.request.${r.id}'),
              title: r.text,
              subtitle:
                  '${governorateLabel(l10n, r.governorate)} · ${language == 'ar' ? (r.areaNameAr.isEmpty ? r.areaNameEn : r.areaNameAr) : (r.areaNameEn.isEmpty ? r.areaNameAr : r.areaNameEn)}',
              leadingIcon: Icons.add_location_alt_outlined,
              showChevron: false,
              trailing: PopupMenuButton<PlaceRequestAction>(
                key: Key('places.requestMenu.${r.id}'),
                tooltip: l10n.adminPlaceActions,
                onSelected: (PlaceRequestAction a) => unawaited(_resolve(context, ref, r, a)),
                itemBuilder: (BuildContext context) => <PopupMenuEntry<PlaceRequestAction>>[
                  PopupMenuItem<PlaceRequestAction>(value: PlaceRequestAction.create, child: OneLineText(l10n.adminPlaceRequestAdd)),
                  PopupMenuItem<PlaceRequestAction>(value: PlaceRequestAction.map, child: OneLineText(l10n.adminPlaceRequestMap)),
                  PopupMenuItem<PlaceRequestAction>(value: PlaceRequestAction.dismiss, child: OneLineText(l10n.adminPlaceRequestDismiss)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Arabic and English names of a place; pops (ar, en) when both are 2 to 80 characters.
class PlaceNameForm extends StatefulWidget {
  const PlaceNameForm({required this.nameAr, required this.nameEn, super.key});

  final String nameAr;
  final String nameEn;

  @override
  State<PlaceNameForm> createState() => _PlaceNameFormState();
}

class _PlaceNameFormState extends State<PlaceNameForm> {
  late final TextEditingController _ar = TextEditingController(text: widget.nameAr);
  late final TextEditingController _en = TextEditingController(text: widget.nameEn);

  @override
  void dispose() {
    _ar.dispose();
    _en.dispose();
    super.dispose();
  }

  static bool _ok(String v) => v.trim().length >= 2 && v.trim().length <= 80;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final bool ready = _ok(_ar.text) && _ok(_en.text);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          key: const Key('placeName.ar'),
          label: l10n.adminNameAr,
          controller: _ar,
          textDirection: TextDirection.rtl,
          maxLength: 80,
          errorText: _ar.text.isNotEmpty && !_ok(_ar.text) ? l10n.adminPlaceNameError : null,
          onChanged: (String _) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('placeName.en'),
          label: l10n.adminNameEn,
          controller: _en,
          textDirection: TextDirection.ltr,
          maxLength: 80,
          errorText: _en.text.isNotEmpty && !_ok(_en.text) ? l10n.adminPlaceNameError : null,
          onChanged: (String _) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('placeName.save'),
          label: l10n.adminSave,
          expand: true,
          onPressed: ready ? () => Navigator.of(context).pop((_ar.text.trim(), _en.text.trim())) : null,
        ),
      ],
    );
  }
}
