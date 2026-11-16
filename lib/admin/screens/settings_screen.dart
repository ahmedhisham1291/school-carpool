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

final _launchProvider = FutureProvider.autoDispose<AdminLaunch>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminFeaturesApiProvider).launch(),
);

String adminFeatureTitle(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWallet,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatings,
  AppFeature.yearlyChecks => l10n.adminFeatureYearly,
  AppFeature.settleUp => l10n.adminFeatureSettle,
  AppFeature.contributions => l10n.adminFeatureContributions,
  AppFeature.activityCarpools => l10n.adminFeatureActivity,
};

String adminFeatureHelper(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWalletHelper,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatingsHelper,
  AppFeature.yearlyChecks => l10n.adminFeatureYearlyHelper,
  AppFeature.settleUp => l10n.adminFeatureSettleHelper,
  AppFeature.contributions => l10n.adminFeatureContributionsHelper,
  AppFeature.activityCarpools => l10n.adminFeatureActivityHelper,
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
      ref
        ..invalidate(_featuresProvider)
        ..invalidate(adminSwitchesProvider);
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// R5: open prod to new parents (with the licence numbers) or close it.
  Future<void> _setLaunch(bool open) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String? refs = open
        ? await _askLicenceRefs(context)
        : (await showConfirmDialog(
                context: context,
                title: l10n.adminLaunchCloseTitle,
                body: l10n.adminLaunchCloseBody,
                confirmLabel: l10n.adminFeatureTurnOff,
                destructive: true,
              ))
            ? ''
            : null;
    if (refs == null || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminFeaturesApiProvider).setLaunch(pdpcLicensed: open, licenceRefs: refs);
      showAppSnackBarOn(messenger, l10n.adminLaunchSaved);
      ref.invalidate(_launchProvider);
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
    final AdminLaunch? launch = ref.watch(_launchProvider).value;
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
            // R5: prod closed to new real parents until the PDPC licences are granted.
            AppSectionHeader(l10n.adminLaunchTitle),
            if (launch == null)
              const SkeletonListRow()
            else
              AppSwitchRow(
                key: const Key('adminSettings.launch'),
                title: l10n.adminLaunchLicensed,
                subtitle: !launch.isProd
                    ? l10n.adminLaunchHelpTest
                    : launch.pdpcLicensed
                    ? l10n.adminLaunchHelpOpen
                    : l10n.adminLaunchHelpClosed,
                value: launch.pdpcLicensed,
                onChanged: superAdmin && !_busy ? (bool on) => unawaited(_setLaunch(on)) : null,
              ),
          ],
        ),
      ),
    );
  }
}

/// R5: the three PDPC licence numbers before opening prod (null: cancelled).
Future<String?> _askLicenceRefs(BuildContext context) => showDialog<String>(
  context: context,
  builder: (BuildContext dialogContext) => const _LicenceRefsDialog(),
);

class _LicenceRefsDialog extends StatefulWidget {
  const _LicenceRefsDialog();

  @override
  State<_LicenceRefsDialog> createState() => _LicenceRefsDialogState();
}

class _LicenceRefsDialogState extends State<_LicenceRefsDialog> {
  String _refs = '';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final bool ok = _refs.trim().length >= 3;
    return AlertDialog(
      title: Semantics(header: true, child: OneLineText(l10n.adminLaunchOpenTitle, scaleDown: true)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.adminLaunchOpenBody),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('adminSettings.launchRefs'),
            label: l10n.adminLaunchRefsLabel,
            onChanged: (String v) => setState(() => _refs = v),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(MaterialLocalizations.of(context).cancelButtonLabel)),
        FilledButton(
          key: const Key('adminSettings.launchConfirm'),
          onPressed: ok ? () => Navigator.of(context).pop(_refs.trim()) : null,
          child: OneLineText(l10n.adminFeatureTurnOn),
        ),
      ],
    );
  }
}
