import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Shows [child] while [feature] is switched on, and a calm "Not available
/// yet" screen otherwise (a deep link, an old notification or a bookmark
/// to a feature that is off for now). Turning the feature on in the admin
/// panel shows [child] at once: no app release.
class FeatureGate extends ConsumerWidget {
  const FeatureGate({required this.feature, required this.child, super.key});

  final AppFeature feature;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(featureSwitchesProvider).isOn(feature) ? child : const FeatureOffScreen();
}

/// "Not available yet": an icon, one title, one sentence and a way back to
/// Profile. Not an error (nothing went wrong) and nothing to load.
class FeatureOffScreen extends StatelessWidget {
  const FeatureOffScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.featureOffTitle)),
      body: SafeArea(
        top: false,
        child: EmptyStateView(
          key: const Key('feature.off'),
          icon: Icons.hourglass_empty_rounded,
          title: l10n.featureOffTitle,
          body: l10n.featureOffBody,
          actionLabel: l10n.featureOffAction,
          onAction: () => context.go('/profile'),
        ),
      ),
    );
  }
}
