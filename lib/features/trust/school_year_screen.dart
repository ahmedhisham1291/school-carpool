import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// The yearly check (spec section 3: before the first term each parent
/// confirms children, grades and schools). Layout: one sentence and the
/// deadline (a warning once it passed: no new driving days until done),
/// then a card per child: first name and school, "Stays" or "Left school",
/// and the new grade for a child who stays (next grade preselected). One
/// primary action, Confirm; it asks first when a child left (the child
/// leaves that school's carpools and chats, which cannot be undone here).
///
/// States: loading (skeleton), nothing to confirm (empty), error and
/// offline (retry); sending shows a spinner and the result a snack bar.
class SchoolYearScreen extends ConsumerWidget {
  const SchoolYearScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void reload() => ref.invalidate(trustOverviewProvider);
    final Widget body = switch (ref.watch(trustOverviewProvider)) {
      AsyncData<TrustOverview>(:final TrustOverview value) when value.yearCheck.open && value.yearCheck.year != null => _YearForm(check: value.yearCheck),
      AsyncData<TrustOverview>() => EmptyStateView(
        key: const Key('year.none'),
        icon: Icons.event_available_outlined,
        title: l10n.yearNothingTitle,
        body: l10n.yearNothingBody,
      ),
      AsyncError<TrustOverview>(:final Object error) => trustErrorView(context, TrustFailure.from(error), reload),
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonCard(), SkeletonCard()])),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.yearTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _YearForm extends ConsumerStatefulWidget {
  const _YearForm({required this.check});

  final YearCheck check;

  @override
  ConsumerState<_YearForm> createState() => _YearFormState();
}

class _YearFormState extends ConsumerState<_YearForm> {
  final Map<String, YearAnswer> _answers = <String, YearAnswer>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final YearChild c in widget.check.children) {
      final Grade? g = c.grade;
      _answers[c.id] = YearAnswer(childId: c.id, stays: true, grade: g == null ? null : nextGrade(g));
    }
  }

  Future<void> _confirm() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final List<YearChild> left = widget.check.children.where((YearChild c) => _answers[c.id]?.stays == false).toList();
    if (left.isNotEmpty) {
      final bool ok = await showConfirmDialog(
        context: context,
        title: l10n.yearLeftConfirmTitle,
        body: l10n.yearLeftConfirmBody(left.map((YearChild c) => c.firstName).join(l10n.listSeparator)),
        confirmLabel: l10n.yearConfirm,
        destructive: true,
      );
      if (!ok || !mounted) {
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(trustRepositoryProvider).confirmSchoolYear(
        year: widget.check.year ?? 0,
        answers: <YearAnswer>[for (final YearChild c in widget.check.children) _answers[c.id]!],
      );
      showAppSnackBarOn(messenger, l10n.yearDone);
      ref.invalidate(trustOverviewProvider);
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
    final YearCheck check = widget.check;
    final DateTime? deadline = check.deadline;
    final String? error = _error;
    final bool overdue = check.state == YearCheckState.overdue;
    return ListView(
      key: const Key('year.list'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Text(schoolYearLabel(l10n, check.year ?? 0), style: context.text.titleMedium),
        const SizedBox(height: AppSpacing.s8),
        Text(l10n.yearIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s16),
        if (overdue)
          AppInlineMessage(key: const Key('year.overdue'), message: l10n.yearOverdue, tone: AppStateTone.warning)
        else if (deadline != null)
          AppInlineMessage(message: l10n.yearDeadline(MaterialLocalizations.of(context).formatMediumDate(deadline))),
        for (final YearChild c in check.children) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          _ChildCard(
            child: c,
            answer: _answers[c.id]!,
            enabled: !_busy,
            onChanged: (YearAnswer a) => setState(() => _answers[c.id] = a),
          ),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(key: const Key('year.error'), message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('year.confirm'),
          label: l10n.yearConfirm,
          icon: Icons.check_rounded,
          expand: true,
          loading: _busy,
          onPressed: yearAnswersComplete(check.children, _answers) && !_busy ? () => unawaited(_confirm()) : null,
        ),
      ],
    );
  }
}

class _ChildCard extends StatelessWidget {
  const _ChildCard({required this.child, required this.answer, required this.enabled, required this.onChanged});

  final YearChild child;
  final YearAnswer answer;
  final bool enabled;
  final ValueChanged<YearAnswer> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AppCard(
      key: Key('year.child.${child.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OneLineText(child.firstName, style: context.text.titleSmall),
          Text(child.schoolName, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          const SizedBox(height: AppSpacing.s16),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              AppChip(
                key: Key('year.stays.${child.id}'),
                label: l10n.yearStays,
                selected: answer.stays,
                onSelected: enabled ? (_) => onChanged(YearAnswer(childId: child.id, stays: true, grade: answer.grade ?? child.grade)) : null,
              ),
              AppChip(
                key: Key('year.left.${child.id}'),
                label: l10n.yearLeft,
                selected: !answer.stays,
                onSelected: enabled ? (_) => onChanged(YearAnswer(childId: child.id, stays: false, grade: answer.grade)) : null,
              ),
            ],
          ),
          if (answer.stays) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            AppSelectField<Grade>(
              key: Key('year.grade.${child.id}'),
              label: l10n.yearGradeLabel,
              options: <(Grade, String)>[for (final Grade g in Grade.values) (g, gradeLabel(l10n, g))],
              value: answer.grade,
              onChanged: enabled ? (Grade g) => onChanged(YearAnswer(childId: child.id, stays: true, grade: g)) : null,
            ),
          ] else ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppInlineMessage(message: l10n.yearLeftNote),
          ],
        ],
      ),
    );
  }
}
