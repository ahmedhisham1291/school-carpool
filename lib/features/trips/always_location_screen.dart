import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/trips/run_recovery.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Before a run, once per install, on iPhone, after "While Using the App"
/// was given: the OPTIONAL "Always" step (owner request 14 Nov 2026,
/// 13:44). The gate never requires it (App Store guideline 5.1.1); without
/// it the run works the same and the run screen keeps its "keep the app
/// open" hint. Returns when the driver answered; the run starts either way.
Future<void> offerAlwaysIfUseful(BuildContext context, WidgetRef ref) async {
  final RunRecoveryService recovery = ref.read(runRecoveryProvider);
  if (!await recovery.shouldOfferAlways() || !context.mounted) {
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(fullscreenDialog: true, builder: (BuildContext _) => const AlwaysLocationScreen()),
  );
}

/// One short screen: what "Always" adds, that it is optional, one primary
/// "Allow Always" (then iOS's own prompt) and "Not now".
///
/// States: loading (the button spins while iOS's prompt is open); empty,
/// error and offline do not apply (no data is loaded; a refused or failed
/// prompt just closes the screen).
class AlwaysLocationScreen extends ConsumerStatefulWidget {
  const AlwaysLocationScreen({super.key});

  @override
  ConsumerState<AlwaysLocationScreen> createState() => _AlwaysLocationScreenState();
}

class _AlwaysLocationScreenState extends ConsumerState<AlwaysLocationScreen> {
  bool _busy = false;

  Future<void> _allow() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    setState(() => _busy = true);
    final bool granted = await ref.read(runRecoveryProvider).requestAlways();
    trackAlwaysChoice(ref.read(analyticsProvider), granted: granted);
    if (granted) {
      showAppSnackBarOn(messenger, l10n.alwaysGranted);
    }
    if (mounted) {
      navigator.pop();
    }
  }

  Future<void> _notNow() async {
    final NavigatorState navigator = Navigator.of(context);
    await ref.read(runRecoveryProvider).declineAlways();
    trackAlwaysChoice(ref.read(analyticsProvider), granted: false);
    if (mounted) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Scaffold(
      key: const Key('always.screen'),
      appBar: AppBar(automaticallyImplyLeading: false, title: AppBarTitle(l10n.alwaysTitle)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.screenPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: AppSpacing.s32),
                    Icon(Icons.restart_alt_rounded, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
                    const SizedBox(height: AppSpacing.s24),
                    Semantics(header: true, child: Text(l10n.alwaysHeading, style: context.text.headlineSmall)),
                    const SizedBox(height: AppSpacing.s8),
                    Text(l10n.alwaysBody, style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant)),
                    const SizedBox(height: AppSpacing.s16),
                    Text(l10n.alwaysWithout, style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AppButton(
                    key: const Key('always.allow'),
                    label: l10n.alwaysAllow,
                    size: AppButtonSize.large,
                    expand: true,
                    loading: _busy,
                    onPressed: _busy ? null : () => unawaited(_allow()),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  AppButton(
                    key: const Key('always.notNow'),
                    label: l10n.alwaysNotNow,
                    variant: AppButtonVariant.tertiary,
                    size: AppButtonSize.large,
                    expand: true,
                    onPressed: _busy ? null : () => unawaited(_notNow()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
