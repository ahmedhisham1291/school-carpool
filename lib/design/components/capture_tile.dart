import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/app_button.dart';
import 'package:school_carpool/design/components/status_badge.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// One photo to take (an ID side, a selfie, a license): what it is, whether
/// it is done, a small preview once taken, and one button to take or
/// retake it. Photos come from the camera only.
class AppCaptureTile extends StatelessWidget {
  const AppCaptureTile({
    required this.title,
    required this.icon,
    required this.actionLabel,
    required this.onCapture,
    required this.doneLabel,
    required this.todoLabel,
    super.key,
    this.helperText,
    this.image,
  });

  final String title;
  final String? helperText;
  final IconData icon;

  /// "Take photo" or "Retake", chosen by the caller.
  final String actionLabel;
  final VoidCallback? onCapture;

  /// Status texts ("Taken", "Not taken yet").
  final String doneLabel;
  final String todoLabel;

  /// The captured photo, or null.
  final Uint8List? image;

  static const double _preview = AppSpacing.s64;

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = image;
    final String? helper = helperText;
    final ColorScheme colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppRadii.card,
        border: Border.all(color: bytes == null ? colors.outlineVariant : colors.primary),
      ),
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox.square(
                  dimension: _preview,
                  child: ClipRRect(
                    borderRadius: AppRadii.mdAll,
                    child: bytes == null
                        ? ColoredBox(
                            color: colors.secondaryContainer,
                            child: Icon(icon, color: colors.onSecondaryContainer, size: AppSpacing.s32),
                          )
                        : ExcludeSemantics(child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)),
                  ),
                ),
                const SizedBox(width: AppSpacing.s16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: context.text.titleSmall),
                      if (helper != null)
                        Text(helper, style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant)),
                      const SizedBox(height: AppSpacing.s8),
                      AppStatusBadge(
                        label: bytes == null ? todoLabel : doneLabel,
                        tone: bytes == null ? AppBadgeTone.neutral : AppBadgeTone.success,
                        icon: bytes == null ? Icons.photo_camera_outlined : Icons.check_circle_rounded,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s16),
            AppButton(
              label: actionLabel,
              icon: Icons.photo_camera_rounded,
              variant: bytes == null ? AppButtonVariant.secondary : AppButtonVariant.tertiary,
              expand: true,
              onPressed: onCapture,
            ),
          ],
        ),
      ),
    );
  }
}
