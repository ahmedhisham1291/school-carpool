import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// A round avatar with the first letter of a first name, on the accent wash
/// (Prompt 11B). Parents have no profile photo yet, so the wallet shows
/// this where a photo would be; a photo can replace the letter later.
/// Decorative for screen readers: the name next to it is read instead.
class AppInitialAvatar extends StatelessWidget {
  const AppInitialAvatar({required this.name, super.key, this.size = AppSpacing.s48});

  final String name;

  /// Diameter: 48 in rows, 64 on confirmation cards.
  final double size;

  @override
  Widget build(BuildContext context) {
    final String trimmed = name.trim();
    final String letter = trimmed.isEmpty ? '?' : String.fromCharCode(trimmed.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(color: context.colors.primaryContainer, shape: BoxShape.circle),
          child: Center(
            child: Text(
              letter,
              textScaler: TextScaler.noScaling,
              style: (size > AppSpacing.s48 ? context.text.headlineSmall : context.text.titleMedium)?.copyWith(
                color: context.colors.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
