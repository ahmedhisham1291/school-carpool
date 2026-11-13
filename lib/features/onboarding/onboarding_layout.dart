import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Number of sign-up steps shown in the progress bar: phone, code, email,
/// terms.
const int kSignupSteps = 4;

/// Layout shared by the sign-up steps: progress, a title, one line that
/// says what to do, the step's content, and the actions pinned at the
/// bottom (above the keyboard). Scrolls when text is scaled to 200 percent.
/// Built only from design-system components.
class OnboardingLayout extends StatelessWidget {
  const OnboardingLayout({
    required this.title,
    required this.children,
    super.key,
    this.step,
    this.body,
    this.primary,
    this.secondary = const <Widget>[],
  });

  /// 1-based step for [AppStepProgress]; null hides the progress.
  final int? step;
  final String title;
  final String? body;
  final List<Widget> children;

  /// The one main action of the step.
  final Widget? primary;

  /// Smaller actions under the main one.
  final List<Widget> secondary;

  @override
  Widget build(BuildContext context) {
    final int? current = step;
    final String? text = body;
    final Widget? main = primary;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.screenPadding,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (current != null) ...<Widget>[
                          AppStepProgress(current: current, total: kSignupSteps),
                          const SizedBox(height: AppSpacing.s24),
                        ],
                        Semantics(
                          header: true,
                          child: Text(title, style: context.text.headlineMedium),
                        ),
                        if (text != null) ...<Widget>[
                          const SizedBox(height: AppSpacing.s8),
                          Text(
                            text,
                            style: context.text.bodyLarge?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.s24),
                        ...children,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (main != null || secondary.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.screenGutter,
                  AppSpacing.s8,
                  AppSpacing.screenGutter,
                  AppSpacing.s16,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[if (main != null) main, ...secondary],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An [AppInlineMessage] for an error: warning tone when offline.
class FailureMessage extends StatelessWidget {
  const FailureMessage({required this.message, required this.offline, super.key});

  final String message;
  final bool offline;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(top: AppSpacing.s16),
    child: AppInlineMessage(
      message: message,
      tone: offline ? AppStateTone.warning : AppStateTone.error,
    ),
  );
}
