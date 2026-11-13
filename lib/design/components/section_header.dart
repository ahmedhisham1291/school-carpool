import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Title above a group of rows or cards. Marked as a header for screen
/// readers.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.s16,
        end: AppSpacing.s16,
        top: AppSpacing.s24,
        bottom: AppSpacing.s8,
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: context.text.titleSmall?.copyWith(color: context.colors.primary),
        ),
      ),
    );
  }
}
