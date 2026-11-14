import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';

/// Delivery mark under one of the parent's own messages.
enum AppChatStatus { none, sending, sent, read, failed }

/// One chat message (Prompt 9). The parent's own messages sit at the end
/// of the line on the soft teal wash; other parents' messages sit at the
/// start on the raised surface with a hairline border. Both follow the
/// reading direction, so they swap sides in Arabic.
///
/// [author] (groups only) is one line above the content; the time and the
/// delivery mark are one line below it. Width is at most 80 % of the line.
class AppChatBubble extends StatelessWidget {
  const AppChatBubble({
    required this.mine,
    required this.child,
    required this.time,
    super.key,
    this.author,
    this.status = AppChatStatus.none,
    this.statusLabel,
    this.onTap,
    this.onLongPress,
    this.semanticsLabel,
  });

  final bool mine;
  final Widget child;
  final String time;
  final String? author;
  final AppChatStatus status;

  /// Screen reader text for [status] ("Sending", "Read").
  final String? statusLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final Color background = mine ? colors.primaryContainer : context.appColors.surfaceRaised;
    final Color foreground = mine ? colors.onPrimaryContainer : colors.onSurface;
    final Color quiet = mine ? colors.onPrimaryContainer : colors.onSurfaceVariant;
    const Radius big = Radius.circular(AppRadii.lg);
    const Radius small = Radius.circular(AppRadii.sm);
    final BorderRadiusDirectional radius = BorderRadiusDirectional.only(
      topStart: mine ? big : small,
      topEnd: mine ? small : big,
      bottomStart: big,
      bottomEnd: big,
    );
    final String? who = author;
    final (IconData? icon, Color iconColor) = switch (status) {
      AppChatStatus.none => (null, quiet),
      AppChatStatus.sending => (Icons.schedule_rounded, quiet),
      AppChatStatus.sent => (Icons.done_rounded, quiet),
      AppChatStatus.read => (Icons.done_all_rounded, colors.primary),
      AppChatStatus.failed => (Icons.error_outline_rounded, colors.error),
    };
    final Widget bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: mine ? null : Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s16, AppSpacing.s8, AppSpacing.s16, AppSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (who != null) ...<Widget>[
              OneLineText(who, style: context.text.labelLarge?.copyWith(color: colors.primary)),
              const SizedBox(height: AppSpacing.s4),
            ],
            DefaultTextStyle.merge(style: context.text.bodyMedium?.copyWith(color: foreground), child: child),
            const SizedBox(height: AppSpacing.s4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(child: OneLineText(time, style: context.text.bodySmall?.copyWith(color: quiet))),
                if (icon != null) ...<Widget>[
                  const SizedBox(width: AppSpacing.s4),
                  Icon(icon, size: AppIconSize.sm, color: iconColor, semanticLabel: statusLabel),
                ],
              ],
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.s16, vertical: AppSpacing.s4),
      child: Align(
        alignment: mine ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) => ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth * 0.8),
            child: Semantics(
              label: semanticsLabel,
              container: true,
              child: GestureDetector(onTap: onTap, onLongPress: onLongPress, child: bubble),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line where a parent writes (Prompt 9): optional photo and location
/// buttons, the text field (grows to five lines) and the send button. Every
/// button is at least 48 by 48 and has a screen reader label.
class AppChatComposer extends StatelessWidget {
  const AppChatComposer({
    required this.controller,
    required this.hint,
    required this.sendLabel,
    required this.onSend,
    super.key,
    this.onPhoto,
    this.photoLabel,
    this.onLocation,
    this.locationLabel,
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final String sendLabel;
  final VoidCallback onSend;

  /// Null hides the photo button (school and area groups).
  final VoidCallback? onPhoto;
  final String? photoLabel;
  final VoidCallback? onLocation;
  final String? locationLabel;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final VoidCallback? photo = onPhoto;
    final VoidCallback? location = onLocation;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.appColors.surfaceRaised,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.s8, AppSpacing.s8, AppSpacing.s8, AppSpacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (photo != null)
                IconButton(
                  key: const Key('chat.composer.photo'),
                  tooltip: photoLabel,
                  onPressed: enabled ? photo : null,
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
              if (location != null)
                IconButton(
                  key: const Key('chat.composer.location'),
                  tooltip: locationLabel,
                  onPressed: enabled ? location : null,
                  icon: const Icon(Icons.location_on_outlined),
                ),
              Expanded(
                child: TextField(
                  key: const Key('chat.composer.field'),
                  controller: controller,
                  enabled: enabled,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 2000,
                  buildCounter: (BuildContext context, {required int currentLength, required bool isFocused, required int? maxLength}) => null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: onChanged,
                  style: context.text.bodyMedium,
                  decoration: InputDecoration(hintText: hint, hintMaxLines: 1, isDense: true),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (BuildContext context, TextEditingValue value, Widget? child) => IconButton.filled(
                  key: const Key('chat.composer.send'),
                  tooltip: sendLabel,
                  onPressed: enabled && value.text.trim().isNotEmpty ? onSend : null,
                  icon: const Icon(Icons.send_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small count pill (unread messages in a chat row).
class AppCountPill extends StatelessWidget {
  const AppCountPill({required this.count, super.key, this.semanticLabel});

  final int count;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: AppSpacing.s24, minHeight: AppSpacing.s24),
        child: DecoratedBox(
          decoration: BoxDecoration(color: colors.primary, borderRadius: AppRadii.chip),
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.s8),
            child: Center(
              widthFactor: 1,
              child: OneLineText(count > 99 ? '99+' : '$count', style: context.text.labelSmall?.copyWith(color: colors.onPrimary)),
            ),
          ),
        ),
      ),
    );
  }
}
