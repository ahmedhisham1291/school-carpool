import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trust/trust_labels.dart';
import 'package:school_carpool/features/trust/trust_models.dart';
import 'package:school_carpool/features/trust/trust_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Rate parents (F17, Profile > Rate parents). Layout: the parent's own
/// rating card (ratings, average from 3, vouches), then one row per parent
/// the parent shared a finished trip with in the last 30 days and has not
/// rated this month: first name, "Drove your child" or "Rode with you",
/// and the date. A row opens the rating sheet: stars, fixed tags, an
/// optional vouch, Send (one primary action). No free text.
///
/// States: loading (skeleton rows), empty (nobody to rate yet), error and
/// offline (retry). Sending shows a spinner; the result is a snack bar.
class RateParentsScreen extends ConsumerWidget {
  const RateParentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void retry() => ref
      ..invalidate(rateableProvider)
      ..invalidate(trustOverviewProvider);
    final Widget body = switch (ref.watch(rateableProvider)) {
      AsyncData<List<RateableParent>>(:final List<RateableParent> value) => ListView(
        key: const Key('rate.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          const _MySummary(),
          if (value.isEmpty)
            SizedBox(
              height: AppSpacing.s64 * 5,
              child: EmptyStateView(
                key: const Key('rate.empty'),
                icon: Icons.star_outline_rounded,
                title: l10n.rateEmptyTitle,
                body: l10n.rateEmptyBody,
              ),
            )
          else ...<Widget>[
            AppSectionHeader(l10n.rateListHeader),
            for (final RateableParent p in value)
              AppListRow(
                key: Key('rate.parent.${p.uid}'),
                title: p.firstName,
                subtitle: rateableSubtitle(context, p),
                leadingIcon: p.drove ? Icons.directions_car_outlined : Icons.family_restroom_outlined,
                onTap: () => unawaited(_rate(context, ref, p)),
              ),
          ],
        ],
      ),
      AsyncError<List<RateableParent>>(:final Object error) => trustErrorView(context, TrustFailure.from(error), retry),
      _ => const Skeleton(
        child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow()]),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.rateTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  static Future<void> _rate(BuildContext context, WidgetRef ref, RateableParent parent) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? flagged = await showAppSheet<bool>(
      context: context,
      title: l10n.rateSheetTitle(parent.firstName),
      body: RateForm(parent: parent),
    );
    if (flagged == null) {
      return;
    }
    showAppSnackBarOn(messenger, flagged ? l10n.rateSentReview : l10n.rateSent);
    ref
      ..invalidate(rateableProvider)
      ..invalidate(trustOverviewProvider);
  }
}

/// The parent's own ratings and vouches (from the overview; hidden while loading).
class _MySummary extends ConsumerWidget {
  const _MySummary();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TrustOverview? overview = ref.watch(trustOverviewProvider).value;
    if (overview == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: AppSpacing.screenPadding,
      child: AppCard(
        key: const Key('rate.summary'),
        child: Row(
          children: <Widget>[
            ExcludeSemantics(child: Icon(Icons.verified_outlined, size: AppIconSize.md, color: context.colors.onSurfaceVariant)),
            const SizedBox(width: AppSpacing.s16),
            Expanded(child: Text(summaryLine(context.l10n, overview.summary), style: context.text.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// Stars, tags and the vouch; pops with true when the rating went to the admins.
class RateForm extends ConsumerStatefulWidget {
  const RateForm({required this.parent, super.key});

  final RateableParent parent;

  @override
  ConsumerState<RateForm> createState() => _RateFormState();
}

class _RateFormState extends ConsumerState<RateForm> {
  int _stars = 0;
  final Set<RatingTag> _tags = <RatingTag>{};
  bool _vouch = false;
  bool _busy = false;
  String? _error;

  void _setStars(int v) => setState(() {
    _stars = v;
    if (!RatingRules.canVouch(_stars, _tags)) {
      _vouch = false;
    }
  });

  void _toggle(RatingTag t, bool on) => setState(() {
    if (on) {
      _tags.add(t);
    } else {
      _tags.remove(t);
    }
    if (!RatingRules.canVouch(_stars, _tags)) {
      _vouch = false;
    }
  });

  Future<void> _send() async {
    final AppLocalizations l10n = context.l10n;
    final NavigatorState navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bool flagged = await ref
          .read(trustRepositoryProvider)
          .rate(RatingDraft(uid: widget.parent.uid, stars: _stars, tags: Set<RatingTag>.of(_tags), vouch: _vouch));
      navigator.pop(flagged);
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
    final String? error = _error;
    final bool canVouch = RatingRules.canVouch(_stars, _tags);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.rateSheetBody),
        const SizedBox(height: AppSpacing.s16),
        Center(child: AppStarRating(value: _stars, onChanged: _busy ? null : _setStars)),
        const SizedBox(height: AppSpacing.s16),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final RatingTag t in RatingTag.values)
              AppChip(
                key: Key('rate.tag.${t.wire}'),
                label: ratingTagLabel(l10n, t),
                selected: _tags.contains(t),
                onSelected: _busy ? null : (bool on) => _toggle(t, on),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        AppSwitchRow(
          key: const Key('rate.vouch'),
          title: l10n.rateVouchTitle,
          subtitle: canVouch ? l10n.rateVouchHelper(widget.parent.firstName) : l10n.rateVouchOff,
          value: _vouch,
          onChanged: canVouch && !_busy ? (bool v) => setState(() => _vouch = v) : null,
        ),
        if (_stars > 0 && RatingRules.goesToAdmins(_stars, _tags)) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('rate.adminNote'), message: l10n.rateAdminNote, tone: AppStateTone.warning),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppInlineMessage(key: const Key('rate.error'), message: error, tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('rate.send'),
          label: l10n.rateSend,
          icon: Icons.send_rounded,
          expand: true,
          loading: _busy,
          onPressed: _stars > 0 && !_busy ? () => unawaited(_send()) : null,
        ),
      ],
    );
  }
}
