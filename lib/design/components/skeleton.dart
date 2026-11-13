import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Loading placeholder. Wrap a group of [SkeletonBox]es in one [Skeleton]:
/// they pulse together, and screen readers hear "loading" once.
///
/// The pulse stops when the phone asks to reduce motion.
class Skeleton extends StatefulWidget {
  const Skeleton({required this.child, super.key});

  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.shimmer,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduceMotion(context)) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      unawaited(_controller.repeat(reverse: true));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors tokens = context.appColors;
    return Semantics(
      label: context.l10n.stateLoadingLabel,
      liveRegion: true,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) => _SkeletonColor(
            color: Color.lerp(
                  tokens.skeletonBase,
                  tokens.skeletonHighlight,
                  AppMotion.standard.transform(_controller.value),
                ) ??
                tokens.skeletonBase,
            child: child!,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _SkeletonColor extends InheritedWidget {
  const _SkeletonColor({required this.color, required super.child});

  final Color color;

  static Color? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonColor>()?.color;

  @override
  bool updateShouldNotify(_SkeletonColor oldWidget) => oldWidget.color != color;
}

/// A grey block standing in for text, an avatar or an image.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = AppSpacing.s16,
    this.borderRadius = AppRadii.smAll,
  });

  /// A round placeholder, for avatars.
  const SkeletonBox.circle({super.key, double size = AppSpacing.s40})
    : width = size,
      height = size,
      borderRadius = AppRadii.pillAll;

  final double? width;
  final double height;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Without a width the box fills the available width (do not put a
      // width-less box directly in a Row; wrap it in Expanded).
      width: width ?? double.infinity,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _SkeletonColor.maybeOf(context) ?? context.appColors.skeletonBase,
          borderRadius: borderRadius,
        ),
      ),
    );
  }
}

/// Placeholder shaped like an [AppListRow] with a leading icon.
class SkeletonListRow extends StatelessWidget {
  const SkeletonListRow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s16,
      ),
      child: Row(
        children: <Widget>[
          SkeletonBox.circle(),
          SizedBox(width: AppSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FractionallySizedBox(widthFactor: 0.6, child: SkeletonBox()),
                SizedBox(height: AppSpacing.s8),
                FractionallySizedBox(widthFactor: 0.4, child: SkeletonBox()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder shaped like an [AppCard] with a title and two lines.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: AppSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FractionallySizedBox(widthFactor: 0.5, child: SkeletonBox(height: AppSpacing.s24)),
            SizedBox(height: AppSpacing.s16),
            SkeletonBox(),
            SizedBox(height: AppSpacing.s8),
            FractionallySizedBox(widthFactor: 0.7, child: SkeletonBox()),
          ],
        ),
      ),
    );
  }
}
