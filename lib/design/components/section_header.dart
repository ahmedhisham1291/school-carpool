import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Title above a group of rows or cards: quiet, one line, sentence case.
/// Generous space above it starts a new section. Marked as a header for
/// screen readers.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.screenGutter,
        end: AppSpacing.screenGutter,
        top: AppSpacing.s32,
        bottom: AppSpacing.s8,
      ),
      child: Semantics(
        header: true,
        child: OneLineText(
          title,
          style: context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ),
    );
  }
}
