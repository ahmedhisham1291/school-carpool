import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Pieces shared by the carpool screens, built only from design-system
/// components (shown in the gallery under "Carpools").

/// A carpool in a list (search results, my carpools): title, area, times
/// and days, free seats, the rules (F36) and the contribution (F25).
class CarpoolCard extends StatelessWidget {
  const CarpoolCard({required this.carpool, super.key, this.onTap, this.badge});

  final Carpool carpool;
  final VoidCallback? onTap;

  /// Shown at the top end, for example "Requested" or "Admin".
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final int? km = carpool.distanceKm;
    final String area = carpool.kind == CarpoolKind.activity
        ? (km == null ? carpool.activityLabel : l10n.carpoolDistanceKm(km))
        : carpool.areaName(language);
    final Contribution? contribution = carpool.contribution;
    final Widget? trailing = badge;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    return AppCard(
      onTap: onTap,
      semanticLabel: carpool.title(language),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: OneLineText(carpool.title(language), style: context.text.titleSmall)),
              if (trailing != null) ...<Widget>[const SizedBox(width: AppSpacing.s8), trailing],
            ],
          ),
          if (area.isNotEmpty) OneLineText(area, style: quiet),
          const SizedBox(height: AppSpacing.s8),
          Text(timesText(l10n, carpool.morning, carpool.afternoon), style: context.text.bodyMedium),
          Text(daysText(l10n, carpool.days), style: quiet),
          const SizedBox(height: AppSpacing.s8),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: <Widget>[
              AppStatusBadge(
                label: carpool.seatsLeft == 0 ? l10n.carpoolFull : l10n.carpoolSeatsLeft(carpool.seatsLeft),
                tone: carpool.seatsLeft == 0 ? AppBadgeTone.warning : AppBadgeTone.success,
                icon: Icons.event_seat_outlined,
              ),
              AppStatusBadge(
                label: contribution == null ? l10n.contributionNone : contributionText(l10n, contribution),
                icon: Icons.payments_outlined,
              ),
            ],
          ),
          if (carpool.rules.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            RulesWrap(rules: carpool.rules),
          ],
        ],
      ),
    );
  }
}

/// The rules of a carpool as quiet badges (F36: shown before joining).
class RulesWrap extends StatelessWidget {
  const RulesWrap({required this.rules, super.key});

  final List<CarpoolRule> rules;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: <Widget>[
        for (final CarpoolRule r in rules)
          AppStatusBadge(key: Key('rule.${r.code}'), label: ruleLabel(l10n, r), icon: Icons.rule_rounded),
      ],
    );
  }
}

/// Picks days of the week as chips (Saturday first, as in Egypt).
class DaysPicker extends StatelessWidget {
  const DaysPicker({required this.selected, required this.onChanged, super.key, this.only, this.keyPrefix = 'day'});

  final List<Weekday> selected;
  final ValueChanged<List<Weekday>> onChanged;

  /// Limits the choices (driving days must be carpool days).
  final List<Weekday>? only;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<Weekday> choices = only ?? Weekday.values;
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: <Widget>[
        for (final Weekday d in choices)
          AppChip(
            key: Key('$keyPrefix.${d.name}'),
            label: dayShort(l10n, d),
            selected: selected.contains(d),
            onSelected: (bool on) => onChanged(<Weekday>[
              for (final Weekday x in Weekday.values)
                if (x == d ? on : selected.contains(x)) x,
            ]),
          ),
      ],
    );
  }
}

/// A run time (morning or afternoon) with an on/off switch and a time.
class RunTimeField extends StatelessWidget {
  const RunTimeField({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.defaultTime,
    super.key,
  });

  final String title;
  final String subtitle;

  /// null when this direction is off.
  final String? value;
  final ValueChanged<String?> onChanged;
  final String defaultTime;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String? time = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSwitchRow(
          title: title,
          subtitle: subtitle,
          value: time != null,
          onChanged: (bool on) => onChanged(on ? defaultTime : null),
        ),
        if (time != null)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: AppSelectField<String>(
              label: l10n.carpoolTimeLabel,
              options: <(String, String)>[for (final String t in RunTime.choices()) (t, t)],
              value: time,
              onChanged: onChanged,
            ),
          ),
      ],
    );
  }
}

/// Skeleton of a list of carpool cards.
class CarpoolListSkeleton extends StatelessWidget {
  const CarpoolListSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonCard(),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
        ],
      ),
    ),
  );
}

/// The error or offline view for a carpool failure.
Widget carpoolErrorView(Object error, VoidCallback onRetry) =>
    CarpoolFailure.from(error).isOffline ? OfflineStateView(onRetry: onRetry) : ErrorStateView(onRetry: onRetry);
