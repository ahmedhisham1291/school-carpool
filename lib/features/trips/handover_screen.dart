import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trips/trip_widgets.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// The most adults per child (same as the server).
const int kMaxHandoverAdults = 6;

/// F29: the parent's children; each opens the list of adults allowed to
/// receive that child at drop-off. Data entry, not driving: typing is fine.
///
/// States: loading (skeleton rows), no children (empty), error and offline.
class HandoverChildrenScreen extends ConsumerWidget {
  const HandoverChildrenScreen({super.key});

  static const String path = '/profile/handover';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<ChildRecord>> children = ref.watch(childrenProvider);
    final Widget body = children.when(
      loading: () => const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()])),
      error: (Object error, StackTrace _) => TripFailure.from(error).isOffline
          ? OfflineStateView(onRetry: () => ref.invalidate(childrenProvider))
          : ErrorStateView(onRetry: () => ref.invalidate(childrenProvider)),
      data: (List<ChildRecord> list) => list.isEmpty
          ? EmptyStateView(key: const Key('handover.noChildren'), icon: Icons.child_care_outlined, title: l10n.handoverNoChildrenTitle, body: l10n.handoverNoChildrenBody)
          : ListView(
              children: <Widget>[
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: Text(l10n.handoverIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                ),
                for (final ChildRecord c in list)
                  AppListRow(
                    key: Key('handover.child.${c.id}'),
                    title: c.firstName,
                    subtitle: l10n.handoverChildHelper,
                    leadingIcon: Icons.child_care_outlined,
                    onTap: () => context.go('$path/${c.id}'),
                  ),
              ],
            ),
    );
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.handoverTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

final _adultsProvider = FutureProvider.autoDispose.family<List<HandoverAdult>, String>(
  (Ref ref, String childId) => ref.watch(tripRepositoryProvider).handoverAdults(childId),
);

/// The adults allowed to receive one child (names, relation, an optional
/// phone the parent keeps for themselves). Drivers see the names and the
/// relation on the run; never the phone.
///
/// States: loading, nobody yet ("Only you and the other parent"), error,
/// offline; removing asks first; every save gives feedback.
class HandoverEditScreen extends ConsumerStatefulWidget {
  const HandoverEditScreen({required this.childId, super.key});

  final String childId;

  @override
  ConsumerState<HandoverEditScreen> createState() => _HandoverEditScreenState();
}

class _HandoverEditScreenState extends ConsumerState<HandoverEditScreen> {
  bool _saving = false;

  Future<void> _save(List<HandoverAdult> adults, String done) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(tripRepositoryProvider).saveHandoverAdults(widget.childId, adults);
      ref.invalidate(_adultsProvider(widget.childId));
      showAppSnackBarOn(messenger, done);
    } on TripFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _remove(List<HandoverAdult> adults, HandoverAdult adult) async {
    final AppLocalizations l10n = context.l10n;
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.handoverRemoveTitle(adult.name),
      body: l10n.handoverRemoveBody,
      confirmLabel: l10n.handoverRemove,
      destructive: true,
    );
    if (sure && mounted) {
      await _save(<HandoverAdult>[for (final HandoverAdult a in adults) if (!identical(a, adult)) a], l10n.handoverRemoved);
    }
  }

  Future<void> _add(List<HandoverAdult> adults) async {
    final HandoverAdult? adult = await showAppSheet<HandoverAdult>(
      context: context,
      title: context.l10n.handoverAdd,
      body: const _AdultForm(),
    );
    if (adult != null && mounted) {
      await _save(<HandoverAdult>[...adults, adult], context.l10n.handoverSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<HandoverAdult>> adults = ref.watch(_adultsProvider(widget.childId));
    final Widget body = adults.when(
      loading: () => const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()])),
      error: (Object error, StackTrace _) => TripFailure.from(error).isOffline
          ? OfflineStateView(onRetry: () => ref.invalidate(_adultsProvider(widget.childId)))
          : ErrorStateView(onRetry: () => ref.invalidate(_adultsProvider(widget.childId))),
      data: (List<HandoverAdult> list) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: list.isEmpty
                ? EmptyStateView(key: const Key('handover.empty'), icon: Icons.family_restroom_outlined, title: l10n.handoverEmptyTitle, body: l10n.handoverEmptyBody)
                : ListView(
                    children: <Widget>[
                      for (final HandoverAdult a in list)
                        AppListRow(
                          key: Key('handover.adult.${a.name}'),
                          title: a.name,
                          subtitle: relationLabel(l10n, a.relation),
                          leadingIcon: Icons.person_outline_rounded,
                          showChevron: false,
                          trailing: IconButton(
                            key: Key('handover.remove.${a.name}'),
                            tooltip: l10n.handoverRemove,
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: _saving ? null : () => unawaited(_remove(list, a)),
                          ),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: AppSpacing.screenPadding,
            child: AppButton(
              key: const Key('handover.add'),
              label: l10n.handoverAdd,
              icon: Icons.person_add_alt_outlined,
              expand: true,
              loading: _saving,
              onPressed: _saving || list.length >= kMaxHandoverAdults ? null : () => unawaited(_add(list)),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.handoverEditTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

/// Name, relation and an optional phone. Each field is checked as the
/// parent types and says how to fix it.
class _AdultForm extends StatefulWidget {
  const _AdultForm();

  @override
  State<_AdultForm> createState() => _AdultFormState();
}

class _AdultFormState extends State<_AdultForm> {
  String _name = '';
  String _phone = '';
  Relation? _relation;

  bool get _nameOk => validPersonName(_name);
  bool get _phoneOk => _phone.trim().isEmpty || EgyptPhone.isValid(_phone);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Relation? relation = _relation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppTextField(
          key: const Key('adult.name'),
          label: l10n.handoverNameLabel,
          helperText: l10n.handoverNameHelper,
          errorText: _name.isEmpty || _nameOk ? null : l10n.handoverNameError,
          onChanged: (String v) => setState(() => _name = v),
        ),
        const SizedBox(height: AppSpacing.s16),
        Semantics(header: true, child: OneLineText(l10n.handoverRelationLabel, style: context.text.labelLarge)),
        const SizedBox(height: AppSpacing.s8),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final Relation r in Relation.values)
              AppChip(
                key: Key('adult.relation.${r.name}'),
                label: relationLabel(l10n, r),
                selected: _relation == r,
                onSelected: (bool _) => setState(() => _relation = r),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('adult.phone'),
          label: l10n.handoverPhoneLabel,
          helperText: l10n.handoverPhoneHelper,
          errorText: _phoneOk ? null : l10n.handoverPhoneError,
          keyboardType: TextInputType.phone,
          onChanged: (String v) => setState(() => _phone = v),
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('adult.save'),
          label: l10n.actionSave,
          expand: true,
          onPressed: _nameOk && _phoneOk && relation != null
              ? () => Navigator.of(context).pop(
                  HandoverAdult(name: _name.trim(), relation: relation, phone: _phone.trim().isEmpty ? null : EgyptPhone.toE164(_phone)),
                )
              : null,
        ),
      ],
    );
  }
}
