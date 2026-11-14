import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Family links (spec section 6, "Who may drive": a spouse verifies
/// separately and is linked to the same children). Layout: one sentence,
/// the primary action "Link to a parent" (sheet: their parent ID and how
/// you are related), then sections that appear only when they have rows:
/// requests for you (tap to choose the children and accept, or decline),
/// your requests waiting (Cancel), your children shared with another
/// parent, and children shared with you (Remove asks first; the child then
/// leaves the other parent's carpools). A link for a guardian waits for an
/// admin ("In review").
///
/// States: loading (skeleton), empty (only the sentence and the action),
/// error and offline (retry).
class FamilyScreen extends ConsumerWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void reload() => ref
      ..invalidate(familyProvider)
      ..invalidate(trustOverviewProvider);
    final Widget body = switch (ref.watch(familyProvider)) {
      AsyncData<FamilyView>(:final FamilyView value) => _FamilyContent(family: value, onChanged: reload),
      AsyncError<FamilyView>(:final Object error) => trustErrorView(context, TrustFailure.from(error), reload),
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow()])),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.familyTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _FamilyContent extends ConsumerWidget {
  const _FamilyContent({required this.family, required this.onChanged});

  final FamilyView family;
  final VoidCallback onChanged;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function(TrustRepository repo) action, String done) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action(ref.read(trustRepositoryProvider));
      showAppSnackBarOn(messenger, done);
      onChanged();
    } on TrustFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  Future<void> _link(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = context.l10n;
    final String? name = await showAppSheet<String>(context: context, title: l10n.familyLinkTitle, body: const LinkRequestForm());
    if (name != null) {
      showAppSnackBarOn(messenger, l10n.familyRequestSent(name));
      onChanged();
    }
  }

  Future<void> _answer(BuildContext context, WidgetRef ref, GuardianRequest r) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = context.l10n;
    final bool? accepted = await showAppSheet<bool>(
      context: context,
      title: l10n.familyAnswerTitle(r.guardianFirstName),
      body: AnswerRequestForm(request: r),
    );
    if (accepted != null) {
      showAppSnackBarOn(messenger, accepted ? l10n.familyAccepted : l10n.familyDeclined);
      onChanged();
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, GuardianLink l) async {
    final AppLocalizations l10n = context.l10n;
    final bool ok = await showConfirmDialog(
      context: context,
      title: l10n.familyRemoveTitle,
      body: l10n.familyRemoveBody(l.childFirstName),
      confirmLabel: l10n.familyRemove,
      destructive: true,
    );
    if (ok && context.mounted) {
      await _run(context, ref, (TrustRepository repo) => repo.removeLink(l.id), l10n.familyRemoved);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    String linkSubtitle(GuardianLink l, String who) =>
        l.status == LinkStatus.review ? '$who · ${l10n.familyInReview}' : '$who · ${relationLabel(l10n, l.relation)}';
    return ListView(
      key: const Key('family.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.familyIntro, style: quiet),
              const SizedBox(height: AppSpacing.s16),
              AppButton(
                key: const Key('family.link'),
                label: l10n.familyLinkAction,
                icon: Icons.link_rounded,
                expand: true,
                onPressed: () => unawaited(_link(context, ref)),
              ),
            ],
          ),
        ),
        if (family.isEmpty)
          Padding(
            padding: AppSpacing.screenPadding,
            child: AppInlineMessage(key: const Key('family.empty'), message: l10n.familyEmpty),
          ),
        if (family.incoming.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.familyIncoming),
          for (final GuardianRequest r in family.incoming)
            AppListRow(
              key: Key('family.incoming.${r.id}'),
              title: r.guardianFirstName,
              subtitle: relationLabel(l10n, r.relation),
              leadingIcon: Icons.person_add_alt_outlined,
              onTap: () => unawaited(_answer(context, ref, r)),
            ),
        ],
        if (family.outgoing.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.familyOutgoing),
          for (final GuardianRequest r in family.outgoing)
            AppListRow(
              key: Key('family.outgoing.${r.id}'),
              title: l10n.familyWaiting,
              subtitle: relationLabel(l10n, r.relation),
              leadingIcon: Icons.hourglass_top_rounded,
              showChevron: false,
              trailing: AppButton(
                key: Key('family.cancel.${r.id}'),
                label: l10n.actionCancel,
                variant: AppButtonVariant.tertiary,
                onPressed: () => unawaited(_run(context, ref, (TrustRepository repo) => repo.cancelLinkRequest(r.id), l10n.familyCancelled)),
              ),
            ),
        ],
        if (family.shared.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.familyShared),
          for (final GuardianLink l in family.shared)
            AppListRow(
              key: Key('family.shared.${l.id}'),
              title: l.childFirstName,
              subtitle: linkSubtitle(l, l.guardianFirstName),
              leadingIcon: Icons.child_care_outlined,
              showChevron: false,
              trailing: _RemoveButton(id: l.id, onPressed: () => unawaited(_remove(context, ref, l))),
            ),
        ],
        if (family.linked.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.familyLinked),
          for (final GuardianLink l in family.linked)
            AppListRow(
              key: Key('family.linked.${l.id}'),
              title: l.childFirstName,
              subtitle: linkSubtitle(l, l.ownerFirstName),
              leadingIcon: Icons.child_care_outlined,
              showChevron: false,
              trailing: _RemoveButton(id: l.id, onPressed: () => unawaited(_remove(context, ref, l))),
            ),
        ],
      ],
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.id, required this.onPressed});

  final String id;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: Key('family.remove.$id'),
    tooltip: context.l10n.familyRemove,
    icon: const Icon(Icons.link_off_rounded),
    onPressed: onPressed,
  );
}

/// The other parent's ID (8 letters and digits, checked as typed) and the
/// relation; pops with their first name once the request is sent.
class LinkRequestForm extends ConsumerStatefulWidget {
  const LinkRequestForm({super.key});

  @override
  ConsumerState<LinkRequestForm> createState() => _LinkRequestFormState();
}

class _LinkRequestFormState extends ConsumerState<LinkRequestForm> {
  static final RegExp _parentId = RegExp(r'^[2-9A-HJ-NP-Z]{8}$');
  final TextEditingController _id = TextEditingController();
  Relation? _relation;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _id.addListener(_changed);
  }

  @override
  void dispose() {
    _id
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  String get _normalized => _id.text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  Future<void> _send() async {
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    final Relation? relation = _relation;
    if (relation == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final String name = await ref.read(trustRepositoryProvider).requestLink(parentId: _normalized, relation: relation);
      navigator.pop(name);
    } on TrustFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String id = _normalized;
    final bool idOk = _parentId.hasMatch(id);
    final String? error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.familyLinkBody),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('family.parentId'),
          label: l10n.walletParentIdLabel,
          controller: _id,
          helperText: l10n.walletParentIdHelper,
          errorText: id.length >= 8 && !idOk ? l10n.walletParentIdInvalid : null,
          maxLength: 9,
          enabled: !_busy,
          textDirection: TextDirection.ltr,
          inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9 -]'))],
        ),
        const SizedBox(height: AppSpacing.s16),
        OneLineText(l10n.familyRelationLabel, style: context.text.labelLarge?.copyWith(color: context.colors.onSurface)),
        const SizedBox(height: AppSpacing.s8),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final Relation r in Relation.values)
              AppChip(
                key: Key('family.relation.${r.name}'),
                label: relationLabel(l10n, r),
                selected: _relation == r,
                onSelected: _busy ? null : (bool on) => setState(() => _relation = on ? r : null),
              ),
          ],
        ),
        if (_relation == Relation.guardian) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(message: l10n.familyGuardianNote),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('family.error'), message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('family.send'),
          label: l10n.familySend,
          icon: Icons.send_rounded,
          expand: true,
          loading: _busy,
          onPressed: idOk && _relation != null && !_busy ? () => unawaited(_send()) : null,
        ),
      ],
    );
  }
}

/// Choose the children to share and accept, or decline. Pops with true
/// (accepted) or false (declined).
class AnswerRequestForm extends ConsumerStatefulWidget {
  const AnswerRequestForm({required this.request, super.key});

  final GuardianRequest request;

  @override
  ConsumerState<AnswerRequestForm> createState() => _AnswerRequestFormState();
}

class _AnswerRequestFormState extends ConsumerState<AnswerRequestForm> {
  final Set<String> _chosen = <String>{};
  bool _busy = false;
  String? _error;

  Future<void> _answer(bool accept) async {
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(trustRepositoryProvider).answerLinkRequest(requestId: widget.request.id, accept: accept, childIds: _chosen.toList()..sort());
      navigator.pop(accept);
    } on TrustFailure catch (f) {
      if (mounted) {
        setState(() => _error = f.message(l10n));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<ChildRecord> children = (ref.watch(childrenProvider).value ?? const <ChildRecord>[])
        .where((ChildRecord c) => c.status == ReviewStatus.approved)
        .toList();
    final String? error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.familyAnswerBody(widget.request.guardianFirstName, relationLabel(l10n, widget.request.relation))),
        const SizedBox(height: AppSpacing.s16),
        if (children.isEmpty)
          AppInlineMessage(message: l10n.familyNoChildren)
        else
          for (final ChildRecord c in children)
            AppCheckRow(
              key: Key('family.child.${c.id}'),
              label: c.firstName,
              value: _chosen.contains(c.id),
              onChanged: _busy
                  ? null
                  : (bool on) => setState(() {
                      if (on) {
                        _chosen.add(c.id);
                      } else {
                        _chosen.remove(c.id);
                      }
                    }),
            ),
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('family.answerError'), message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('family.accept'),
          label: l10n.familyAccept,
          icon: Icons.check_rounded,
          expand: true,
          loading: _busy,
          onPressed: _chosen.isNotEmpty && !_busy ? () => unawaited(_answer(true)) : null,
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          key: const Key('family.decline'),
          label: l10n.familyDecline,
          variant: AppButtonVariant.tertiary,
          expand: true,
          onPressed: _busy ? null : () => unawaited(_answer(false)),
        ),
      ],
    );
  }
}
