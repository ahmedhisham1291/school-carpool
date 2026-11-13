import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// A verification document image with the reviewer's name, email and the
/// time repeated across it (spec section 7: the reviewer's name
/// watermarked on every ID image), so a photo of the screen shows who
/// looked at it and when.
///
/// No download: the image comes from a 5-minute signed link and is drawn on
/// the canvas (never as an <img> element), the browser's context menu is
/// off in the panel, and there is no save or open button. A screenshot
/// cannot be stopped in a browser; the watermark is why.
class WatermarkedImage extends StatelessWidget {
  const WatermarkedImage({
    required this.url,
    required this.watermark,
    required this.semanticLabel,
    super.key,
    this.image,
  });

  final String? url;

  /// For example "Mona Admin · mona@example.com · 13 Nov 2026 10:42".
  final String watermark;
  final String semanticLabel;

  /// Tests and the gallery pass an image provider instead of a link.
  final ImageProvider<Object>? image;

  @override
  Widget build(BuildContext context) {
    final String? link = url;
    // NetworkImage's default web strategy (never) draws the image on the
    // canvas and never as an <img> element the browser could save.
    final ImageProvider<Object>? provider = image ?? (link == null ? null : NetworkImage(link));
    return Semantics(
      image: true,
      label: semanticLabel,
      child: ClipRRect(
        borderRadius: AppRadii.card,
        child: AspectRatio(
          aspectRatio: 3 / 2,
          child: ColoredBox(
            color: context.colors.surfaceContainerHighest,
            child: provider == null
                ? _Missing(text: context.l10n.adminImageGone)
                : Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Image(
                        image: provider,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? progress) =>
                            progress == null ? child : const Skeleton(child: SkeletonBox(height: double.infinity)),
                        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                            _Missing(text: context.l10n.adminImageError),
                      ),
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _WatermarkPainter(
                            text: watermark,
                            style: (context.text.labelMedium ?? const TextStyle()).copyWith(
                              color: context.colors.onSurface.withValues(alpha: _WatermarkPainter.opacity),
                            ),
                            direction: Directionality.of(context),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.hide_image_outlined, color: context.colors.onSurfaceVariant),
          const SizedBox(height: AppSpacing.s8),
          OneLine(text, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        ],
      ),
    ),
  );
}

class _WatermarkPainter extends CustomPainter {
  _WatermarkPainter({required this.text, required this.style, required this.direction});

  final String text;
  final TextStyle style;
  final TextDirection direction;

  /// Strong enough to read in a photo, light enough to check the document.
  static const double opacity = 0.32;

  /// Diagonal, like a stamp.
  static const double _angle = -math.pi / 6;

  @override
  void paint(Canvas canvas, Size size) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      maxLines: 1,
    )..layout();
    final double stepX = painter.width + AppSpacing.s48;
    final double stepY = painter.height + AppSpacing.s48;
    final double diagonal = math.sqrt(size.width * size.width + size.height * size.height);

    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..translate(size.width / 2, size.height / 2)
      ..rotate(_angle);
    int row = 0;
    for (double y = -diagonal / 2; y < diagonal / 2; y += stepY) {
      // Every other row shifts by half a step so the marks interlock.
      final double shift = row.isEven ? 0 : stepX / 2;
      for (double x = -diagonal / 2 - shift; x < diagonal / 2; x += stepX) {
        painter.paint(canvas, Offset(x, y));
      }
      row += 1;
    }
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_WatermarkPainter oldDelegate) =>
      oldDelegate.text != text || oldDelegate.style != style || oldDelegate.direction != direction;
}
