import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// The parent's answer about usage statistics, saved on this phone and
/// (best effort) as a consent record on the server. Shared by the Home
/// card, Settings and the privacy screen.
Future<void> applyAnalyticsChoice(WidgetRef ref, {required bool enabled}) async {
  await saveAnalyticsChoice(ref.read(settingsStoreProvider), ref.read(analyticsProvider), enabled: enabled);
  if (ref.read(sessionProvider) is SessionSignedIn) {
    try {
      await ref.read(privacyRepositoryProvider).setConsent(ConsentKind.analytics, granted: enabled);
    } on Object {
      // Offline: recorded the next time the parent changes it.
    }
  }
}

/// Home: asks ONCE whether the parent wants to share usage statistics
/// (App Review guideline 5.1.1(ii): consent before collecting usage data,
/// and an easy way to withdraw it; owner decision 16 Nov 2026). Statistics
/// are OFF until the parent says yes. The card never blocks anything: both
/// answers close it for good, and the switch stays in Profile > Settings
/// and on the privacy screen.
///
/// States: nothing loads (the answer is on the phone), so no loading,
/// empty, error or offline state; hidden once answered.
class AnalyticsAskCard extends ConsumerStatefulWidget {
  const AnalyticsAskCard({super.key});

  @override
  ConsumerState<AnalyticsAskCard> createState() => _AnalyticsAskCardState();
}

class _AnalyticsAskCardState extends ConsumerState<AnalyticsAskCard> {
  bool _answered = false;

  Future<void> _answer(bool enabled) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _answered = true);
    await applyAnalyticsChoice(ref, enabled: enabled);
    showAppSnackBarOn(messenger, enabled ? l10n.analyticsOn : l10n.analyticsOff);
  }

  @override
  Widget build(BuildContext context) {
    if (_answered || AnalyticsConsent.answered(ref.watch(settingsStoreProvider))) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s16, AppSpacing.s16, 0),
      child: AppCard(
        key: const Key('analyticsAsk.card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ExcludeSemantics(child: Icon(Icons.insights_outlined, color: context.colors.primary, size: AppIconSize.md)),
                const SizedBox(width: AppSpacing.s16),
                Expanded(
                  child: Semantics(header: true, child: OneLineText(l10n.analyticsAskTitle, style: context.text.titleMedium)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s8),
            Text(l10n.analyticsAskBody, style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant)),
            const SizedBox(height: AppSpacing.s16),
            Row(
              children: <Widget>[
                Expanded(
                  child: AppButton(
                    key: const Key('analyticsAsk.no'),
                    label: l10n.analyticsAskNo,
                    variant: AppButtonVariant.tertiary,
                    expand: true,
                    onPressed: () => unawaited(_answer(false)),
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: AppButton(
                    key: const Key('analyticsAsk.yes'),
                    label: l10n.analyticsAskYes,
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    onPressed: () => unawaited(_answer(true)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
