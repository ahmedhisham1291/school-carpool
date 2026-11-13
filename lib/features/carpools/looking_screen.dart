import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

final _areasProvider = FutureProvider.autoDispose.family<List<SchoolArea>, String>(
  (Ref ref, String schoolId) => ref.watch(carpoolRepositoryProvider).areas(schoolId),
);

/// "Looking for a carpool" (F32): a parent with no group posts school,
/// area, times and days; verified parents of the same school see the
/// posts (first name, area, times, days, number of children). When three
/// families match, a card suggests starting a group with those settings.
///
/// States: loading (skeleton), no school (empty), no posts (empty with
/// "Post my request"), error, offline, too many tries.
class LookingScreen extends ConsumerStatefulWidget {
  const LookingScreen({super.key});

  @override
  ConsumerState<LookingScreen> createState() => _LookingScreenState();
}

/// A child's school the parent can post for.
typedef _School = ({String id, String name});

class _LookingScreenState extends ConsumerState<LookingScreen> {
  String? _schoolId;
  String? _loadedKey;
  int _request = 0;
  bool _saving = false;
  AsyncValue<WantedList> _list = const AsyncLoading<WantedList>();

  Future<void> _load(String schoolId) async {
    final int request = ++_request;
    _loadedKey = schoolId;
    setState(() => _list = const AsyncLoading<WantedList>());
    AsyncValue<WantedList> next;
    try {
      next = AsyncData<WantedList>(await ref.read(carpoolRepositoryProvider).listWanted(schoolId: schoolId));
    } on CarpoolFailure catch (failure, stackTrace) {
      next = AsyncError<WantedList>(failure, stackTrace);
    }
    if (mounted && request == _request) {
      setState(() => _list = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ChildRecord>> children = ref.watch(childrenProvider);
    final Widget body = switch (children) {
      AsyncError<List<ChildRecord>>(:final Object error) => carpoolErrorView(error, () => ref.invalidate(childrenProvider)),
      AsyncData<List<ChildRecord>>(:final List<ChildRecord> value) => _content(context, value),
      _ => const CarpoolListSkeleton(),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.lookingTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, List<ChildRecord> allChildren) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final List<ChildRecord> approved = allChildren.where((ChildRecord c) => c.status == ReviewStatus.approved && c.schoolId.isNotEmpty).toList();
    final Map<String, _School> schoolMap = <String, _School>{
      for (final ChildRecord c in approved) c.schoolId: (id: c.schoolId, name: c.schoolName),
    };
    final List<_School> schools = schoolMap.values.toList();
    if (schools.isEmpty) {
      return EmptyStateView(
        key: const Key('looking.noSchool'),
        icon: Icons.school_outlined,
        title: l10n.nearbyNoSchoolTitle,
        body: l10n.lookingNoSchoolBody,
      );
    }
    final _School school = schools.firstWhere((_School s) => s.id == _schoolId, orElse: () => schools.first);
    if (_loadedKey != school.id) {
      _loadedKey = school.id;
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) {
          unawaited(_load(school.id));
        }
      });
    }
    final List<ChildRecord> schoolChildren = approved.where((ChildRecord c) => c.schoolId == school.id).toList();
    final List<SchoolArea> areas = ref.watch(_areasProvider(school.id)).value ?? const <SchoolArea>[];

    final List<Widget> children = <Widget>[
      if (schools.length > 1)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, 0),
          child: Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              for (final _School s in schools)
                AppChip(
                  key: Key('looking.school.${s.id}'),
                  label: s.name,
                  selected: s.id == school.id,
                  onSelected: (bool _) => setState(() => _schoolId = s.id),
                ),
            ],
          ),
        ),
    ];

    switch (_list) {
      case AsyncData<WantedList>(:final WantedList value):
        final WantedSuggestion? suggestion = value.suggestion;
        final WantedPost? mine = value.mine;
        final List<WantedPost> others = value.posts.where((WantedPost p) => !p.mine).toList();
        if (suggestion != null) {
          children.add(
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: AppCard(
                key: const Key('looking.suggestion'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    OneLineText(l10n.lookingMatchTitle(suggestion.families), style: context.text.titleSmall),
                    Text(l10n.lookingMatchBody, style: context.text.bodyMedium),
                    const SizedBox(height: AppSpacing.s16),
                    AppButton(
                      key: const Key('looking.start'),
                      label: l10n.carpoolCreate,
                      expand: true,
                      onPressed: () => context.go(
                        CarpoolRoutes.createFrom(
                          schoolId: school.id,
                          areaId: suggestion.areaId,
                          morning: suggestion.morning,
                          afternoon: suggestion.afternoon,
                          days: suggestion.days,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        children
          ..add(AppSectionHeader(l10n.lookingMineSection))
          ..add(
            mine == null
                ? Padding(
                    padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(l10n.lookingPostIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                        const SizedBox(height: AppSpacing.s16),
                        AppButton(
                          key: const Key('looking.post'),
                          label: l10n.lookingPost,
                          icon: Icons.campaign_outlined,
                          expand: true,
                          loading: _saving,
                          onPressed: _saving ? null : () => unawaited(_post(school.id, schoolChildren, areas)),
                        ),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _PostRow(post: mine, language: language),
                      Padding(
                        padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
                        child: AppButton(
                          key: const Key('looking.delete'),
                          label: l10n.lookingDelete,
                          variant: AppButtonVariant.tertiary,
                          expand: true,
                          loading: _saving,
                          onPressed: _saving ? null : () => unawaited(_delete(school.id)),
                        ),
                      ),
                    ],
                  ),
          )
          ..add(AppSectionHeader(l10n.lookingOthersSection));
        if (others.isEmpty) {
          children.add(
            EmptyStateView(key: const Key('looking.empty'), icon: Icons.people_outline_rounded, title: l10n.lookingEmptyTitle, body: l10n.lookingEmptyBody),
          );
        } else {
          for (final WantedPost p in others) {
            children.add(_PostRow(post: p, language: language));
          }
        }
      case AsyncError<WantedList>(:final Object error):
        final CarpoolFailure f = CarpoolFailure.from(error);
        children.add(
          f.isOffline
              ? OfflineStateView(onRetry: () => unawaited(_load(school.id)))
              : f.kind == CarpoolFailureKind.rateLimited
              ? Padding(
                  padding: AppSpacing.screenPadding,
                  child: AppInlineMessage(message: f.message(l10n), tone: AppStateTone.warning),
                )
              : ErrorStateView(onRetry: () => unawaited(_load(school.id))),
        );
      default:
        children.add(const CarpoolListSkeleton());
    }

    return ListView(
      key: const Key('looking.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: children,
    );
  }

  Future<void> _post(String schoolId, List<ChildRecord> children, List<SchoolArea> areas) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final WantedDraft? draft = await showAppSheet<WantedDraft>(
      context: context,
      title: l10n.lookingPost,
      body: _PostForm(schoolId: schoolId, children: children, areas: areas),
    );
    if (draft == null || !mounted) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(carpoolRepositoryProvider).saveWanted(draft);
      showAppSnackBarOn(messenger, l10n.lookingPosted);
      await _load(schoolId);
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete(String schoolId) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.lookingDeleteTitle,
      body: l10n.lookingDeleteBody,
      confirmLabel: l10n.lookingDelete,
      destructive: true,
    );
    if (!sure || !mounted) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(carpoolRepositoryProvider).deleteWanted();
      showAppSnackBarOn(messenger, l10n.lookingDeleted);
      await _load(schoolId);
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

/// One post: first name, area, times, days and number of children.
class _PostRow extends StatelessWidget {
  const _PostRow({required this.post, required this.language});

  final WantedPost post;
  final String language;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String area = post.areaName(language);
    return AppListRow(
      key: Key('looking.post.${post.id}'),
      title: post.mine ? l10n.carpoolYou(post.firstName) : post.firstName,
      subtitle: <String>[
        if (area.isNotEmpty) area,
        timesText(l10n, post.morning, post.afternoon),
        daysText(l10n, post.days),
      ].join(l10n.dotSeparator),
      leadingIcon: Icons.person_outline_rounded,
      showChevron: false,
      trailing: AppStatusBadge(label: l10n.lookingChildren(post.childrenCount)),
    );
  }
}

/// The post form (F32): area, times, days and which children.
class _PostForm extends StatefulWidget {
  const _PostForm({required this.schoolId, required this.children, required this.areas});

  final String schoolId;
  final List<ChildRecord> children;
  final List<SchoolArea> areas;

  @override
  State<_PostForm> createState() => _PostFormState();
}

class _PostFormState extends State<_PostForm> {
  String? _areaId;
  String? _morning = RunTime.defaultMorning;
  String? _afternoon;
  List<Weekday> _days = Weekday.schoolDays;
  late final Set<String> _childIds = <String>{for (final ChildRecord c in widget.children) c.id};

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final bool ready = (_morning != null || _afternoon != null) && _days.isNotEmpty && _childIds.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.areas.isNotEmpty) ...<Widget>[
          AppSelectField<String>(
            key: const Key('looking.form.area'),
            label: l10n.carpoolAreaLabel,
            options: <(String, String)>[('', l10n.carpoolAnyArea), for (final SchoolArea a in widget.areas) (a.id, a.name(language))],
            value: _areaId ?? '',
            onChanged: (String v) => setState(() => _areaId = v.isEmpty ? null : v),
          ),
          const SizedBox(height: AppSpacing.s16),
        ],
        RunTimeField(
          key: const Key('looking.form.morning'),
          title: l10n.carpoolMorningTitle,
          subtitle: l10n.carpoolMorningHelper,
          value: _morning,
          defaultTime: RunTime.defaultMorning,
          onChanged: (String? v) => setState(() => _morning = v),
        ),
        RunTimeField(
          key: const Key('looking.form.afternoon'),
          title: l10n.carpoolAfternoonTitle,
          subtitle: l10n.carpoolAfternoonHelper,
          value: _afternoon,
          defaultTime: RunTime.defaultAfternoon,
          onChanged: (String? v) => setState(() => _afternoon = v),
        ),
        const SizedBox(height: AppSpacing.s16),
        Text(l10n.carpoolDaysLabel, style: context.text.labelLarge),
        const SizedBox(height: AppSpacing.s8),
        DaysPicker(selected: _days, keyPrefix: 'looking.day', onChanged: (List<Weekday> d) => setState(() => _days = d)),
        const SizedBox(height: AppSpacing.s16),
        for (final ChildRecord c in widget.children)
          AppCheckRow(
            key: Key('looking.form.child.${c.id}'),
            label: l10n.childWithGrade(c.firstName, gradeLabel(l10n, c.grade)),
            value: _childIds.contains(c.id),
            onChanged: (bool on) => setState(() => on ? _childIds.add(c.id) : _childIds.remove(c.id)),
          ),
        if (_morning == null && _afternoon == null)
          AppInlineMessage(message: l10n.carpoolErrorNoTime, tone: AppStateTone.error),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('looking.form.save'),
          label: l10n.lookingPost,
          expand: true,
          onPressed: ready
              ? () => Navigator.of(context).pop(
                  WantedDraft(
                    schoolId: widget.schoolId,
                    areaId: _areaId,
                    morning: _morning,
                    afternoon: _afternoon,
                    days: _days,
                    childIds: _childIds.toList(),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}
