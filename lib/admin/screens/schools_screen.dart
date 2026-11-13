import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// A paged list of schools by status, with an optional governorate filter.
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
      final AdminPage<School> page = await ref
          .read(adminApiProvider)
          .schools(status: widget.status, governorate: _governorate, afterId: more ? _next : null);
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
          child: AppSelectField<String?>(
            key: const Key('schools.governorate'),
            label: l10n.adminGovernorate,
            options: <(String?, String)>[
              (null, l10n.adminAllGovernorates),
              for (final String g in kGovernorates) (g, governorateLabel(l10n, g)),
            ],
            value: _governorate,
            onChanged: (String? g) {
              setState(() => _governorate = g);
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
                  subtitle: '${governorateLabel(l10n, s.governorate)} · ${s.city}',
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

/// Schools and areas (F4 data, F14): the active list, filter by
/// governorate, open one to edit its names, pin and areas, or add a new
/// school (the one primary action).
///
/// States: loading (skeleton), empty (no schools yet: add one), error and
/// offline (retry).
class SchoolsScreen extends StatelessWidget {
  const SchoolsScreen({super.key});

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
      body: SchoolList(
        status: SchoolStatus.active,
        onOpen: (School s) => context.go(AdminRoutes.school(s.id)),
        empty: EmptyStateView(
          icon: Icons.school_outlined,
          title: l10n.adminSchoolsEmptyTitle,
          body: l10n.adminSchoolsEmptyBody,
        ),
      ),
    );
  }
}
