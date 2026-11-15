import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// No automatic retry (Riverpod 3): the page shows its own Retry.
Duration? _noRetry(int retryCount, Object error) => null;

final _featuresProvider = FutureProvider.autoDispose<FeatureSwitches>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminFeaturesApiProvider).features(),
);

String adminFeatureTitle(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWallet,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatings,
  AppFeature.yearlyChecks => l10n.adminFeatureYearly,
  AppFeature.settleUp => l10n.adminFeatureSettle,
};

String adminFeatureHelper(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWalletHelper,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatingsHelper,
  AppFeature.yearlyChecks => l10n.adminFeatureYearlyHelper,
  AppFeature.settleUp => l10n.adminFeatureSettleHelper,
};

/// Settings (pilot feature switches): one switch per optional feature
/// (wallet, ratings and vouching, yearly checks, Settle up). A super admin
/// changes one after a confirmation; the server writes the audit log.
/// Other admins see the switches but cannot change them. A change reaches
/// the apps at once (no release) and the functions within half a minute.
///
/// Sign-in, verification, carpools, schedule, trips and alerts and chat
/// have no switch.
///
/// States: loading (skeleton), error and offline (retry).
class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  bool _busy = false;

  Future<void> _set(AppFeature feature, bool on) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String name = adminFeatureTitle(l10n, feature);
    final bool ok = await showConfirmDialog(
      context: context,
      title: on ? l10n.adminFeatureOnTitle : l10n.adminFeatureOffTitle,
      body: on ? l10n.adminFeatureOnBody(name) : l10n.adminFeatureOffBody(name),
      confirmLabel: on ? l10n.adminFeatureTurnOn : l10n.adminFeatureTurnOff,
      destructive: !on,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminFeaturesApiProvider).setFeature(feature, on: on);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      ref.invalidate(_featuresProvider);
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final bool superAdmin = adminUserOf(ref.watch(adminSessionProvider))?.isSuperAdmin ?? false;
    void refresh() => ref.invalidate(_featuresProvider);
    return AdminPage(
      title: l10n.adminSettingsTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: AdminAsyncView<FeatureSwitches>(
        value: ref.watch(_featuresProvider),
        onRetry: refresh,
        builder: (FeatureSwitches features) => ListView(
          key: const Key('adminSettings.list'),
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            AppInlineMessage(
              key: const Key('adminSettings.intro'),
              message: superAdmin ? l10n.adminSettingsIntro : l10n.adminSettingsReadOnly,
            ),
            AppSectionHeader(l10n.adminSettingsFeatures),
            for (final AppFeature f in AppFeature.values)
              AppSwitchRow(
                key: Key('adminSettings.${f.name}'),
                title: adminFeatureTitle(l10n, f),
                subtitle: adminFeatureHelper(l10n, f),
                value: features.isOn(f),
                // Only a super admin changes a switch (the server checks too).
                onChanged: superAdmin && !_busy ? (bool on) => unawaited(_set(f, on)) : null,
              ),
            const SizedBox(height: AppSpacing.s16),
            Text(l10n.adminSettingsCore, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
