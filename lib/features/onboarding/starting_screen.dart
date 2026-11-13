import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Shown while the session loads, while the server creates a new account
/// record, and when the session cannot load (error or offline, with a
/// retry). The router leaves this screen as soon as the session is known.
class StartingScreen extends ConsumerWidget {
  const StartingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SessionState session = ref.watch(sessionProvider);
    void retry() => ref.invalidate(sessionStreamProvider);

    final Widget body = switch (session) {
      SessionFailed(offline: true) => OfflineStateView(onRetry: retry),
      SessionFailed() => ErrorStateView(onRetry: retry),
      SessionSignedIn(account: null) => _Loading(label: context.l10n.startingSettingUp),
      _ => const _Loading(),
    };
    return Scaffold(body: SafeArea(child: body));
  }
}

class _Loading extends StatelessWidget {
  const _Loading({this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final String? text = label;
    return Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: AppSpacing.s48),
          const Skeleton(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SkeletonBox(width: AppSpacing.s64, height: AppSpacing.s64),
                SizedBox(height: AppSpacing.s24),
                FractionallySizedBox(widthFactor: 0.7, child: SkeletonBox(height: AppSpacing.s32)),
                SizedBox(height: AppSpacing.s16),
                SkeletonBox(),
                SizedBox(height: AppSpacing.s8),
                FractionallySizedBox(widthFactor: 0.8, child: SkeletonBox()),
              ],
            ),
          ),
          if (text != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s24),
            Text(
              text,
              style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
