import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Small building blocks of the admin panel, made only from the shared
/// design system (tokens and components), so a design refresh flows into
/// every panel screen. Shown in the admin gallery (dev).

/// Owner rule: labels, buttons, tabs, chips, list titles and app bar titles
/// fit on one line in Arabic and English. Long values are cut with "…".
class OneLine extends StatelessWidget {
  const OneLine(this.text, {super.key, this.style, this.semanticsLabel});

  final String text;
  final TextStyle? style;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: style,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    semanticsLabel: semanticsLabel,
  );
}

/// The widest the panel's content gets on a large screen.
const double kAdminContentWidth = AppSpacing.maxContentWidth * 2;

/// A panel page: app bar with a one-line title, actions, and the content
/// centered at a readable width.
class AdminPage extends StatelessWidget {
  const AdminPage({required this.title, required this.body, super.key, this.actions = const <Widget>[]});

  final String title;
  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Semantics(header: true, child: OneLine(title)),
      actions: <Widget>[...actions, const SizedBox(width: AppSpacing.s8)],
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: AlignmentDirectional.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kAdminContentWidth),
          child: body,
        ),
      ),
    ),
  );
}

/// Loading (skeleton), empty, error and offline states for a list or
/// detail loaded from the admin functions.
class AdminAsyncView<T> extends StatelessWidget {
  const AdminAsyncView({
    required this.value,
    required this.builder,
    required this.onRetry,
    super.key,
    this.isEmpty,
    this.empty,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  final bool Function(T data)? isEmpty;
  final Widget? empty;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncData<T>(:final T value) when isEmpty?.call(value) ?? false => empty ?? const EmptyStateView(),
    AsyncData<T>(:final T value) => builder(value),
    AsyncError<T>(:final Object error) => _error(context, AdminFailure.from(error)),
    _ => const AdminSkeletonList(),
  };

  Widget _error(BuildContext context, AdminFailure failure) {
    if (failure.isOffline) {
      return OfflineStateView(onRetry: onRetry);
    }
    return ErrorStateView(body: failure.message(context.l10n), onRetry: onRetry);
  }
}

/// Skeleton placeholders for a list.
class AdminSkeletonList extends StatelessWidget {
  const AdminSkeletonList({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) => Skeleton(
    child: Column(children: <Widget>[for (int i = 0; i < rows; i++) const SkeletonListRow()]),
  );
}

/// A label and a value on one line each, for detail cards.
class AdminFact extends StatelessWidget {
  const AdminFact({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        OneLine(label, style: context.text.labelMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        SelectionContainer.disabled(child: Text(value, style: context.text.bodyMedium)),
      ],
    ),
  );
}

/// Date and time in the panel's language, or a dash.
String adminDateTime(BuildContext context, DateTime? time) {
  if (time == null) {
    return '-';
  }
  final String locale = Localizations.localeOf(context).languageCode;
  return DateFormat.yMMMd(locale).add_Hm().format(time);
}

/// Shows a short confirmation at the bottom of the screen.
void adminToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: OneLine(message)));
}
