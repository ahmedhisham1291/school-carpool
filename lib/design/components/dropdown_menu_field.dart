import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/one_line_text.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/schools/text_normalize.dart';

/// One choice of an [AppDropdownMenu].
@immutable
class AppDropdownItem<T> {
  const AppDropdownItem(this.value, this.label, {this.icon});

  final T value;

  /// One line; ends with an ellipsis when too long.
  final String label;
  final IconData? icon;
}

/// A filterable dropdown menu (Material 3 DropdownMenu): tap to open the
/// list, or type to narrow it (Arabic spelling differences ignored, the
/// same normalization as school search). For City, Area and District
/// (F4 browse, F46 address) and any longer list a parent picks one value
/// from.
///
/// Every item is one line (ellipsis), at least 48 dp high. [pinnedLast],
/// when given, always stays at the end of the list whatever is typed (for
/// example "My district isn't listed"). Disabled while [onSelected] is
/// null (a child list waiting for its parent). Give it a key that changes
/// with the parent's value, so a new parent clears the child.
class AppDropdownMenu<T> extends StatefulWidget {
  const AppDropdownMenu({
    required this.label,
    required this.items,
    required this.value,
    required this.onSelected,
    super.key,
    this.hintText,
    this.helperText,
    this.errorText,
    this.leadingIcon,
    this.pinnedLast,
  });

  final String label;
  final List<AppDropdownItem<T>> items;
  final T? value;
  final ValueChanged<T>? onSelected;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final IconData? leadingIcon;
  final AppDropdownItem<T>? pinnedLast;

  /// Items whose label matches [filter] (normalized; every word of the
  /// filter must start a word of the label), then [pinned].
  static List<AppDropdownItem<E>> filter<E>(List<AppDropdownItem<E>> items, String filter, {AppDropdownItem<E>? pinned}) {
    final List<String> words = normalizeText(filter).split(' ').where((String w) => w.isNotEmpty).toList();
    bool matches(AppDropdownItem<E> item) {
      if (words.isEmpty) {
        return true;
      }
      final List<String> label = normalizeText(item.label).split(' ');
      return words.every(
        (String w) => label.any((String l) => l.startsWith(w) || (l.startsWith('ال') && l.substring(2).startsWith(w))),
      );
    }

    return <AppDropdownItem<E>>[...items.where(matches), ?pinned];
  }

  @override
  State<AppDropdownMenu<T>> createState() => _AppDropdownMenuState<T>();
}

class _AppDropdownMenuState<T> extends State<AppDropdownMenu<T>> {
  late final TextEditingController _text = TextEditingController(text: _labelOf(widget.value));

  String _labelOf(T? value) {
    if (value == null) {
      return '';
    }
    for (final AppDropdownItem<T> item in <AppDropdownItem<T>>[...widget.items, ?widget.pinnedLast]) {
      if (item.value == value) {
        return item.label;
      }
    }
    return '';
  }

  @override
  void didUpdateWidget(AppDropdownMenu<T> old) {
    super.didUpdateWidget(old);
    // The items arrived (or changed) after the value was set: show its label.
    if (old.value != widget.value || old.items.length != widget.items.length) {
      final String label = _labelOf(widget.value);
      if (widget.value == null || label.isNotEmpty) {
        _text.text = label;
      }
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  DropdownMenuEntry<T> _entry(AppDropdownItem<T> item) {
    final IconData? icon = item.icon;
    return DropdownMenuEntry<T>(
      value: item.value,
      label: item.label,
      leadingIcon: icon == null ? null : Icon(icon),
      labelWidget: OneLineText(item.label),
      style: MenuItemButton.styleFrom(minimumSize: const Size.fromHeight(AppSpacing.minTouchTarget)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ValueChanged<T>? onSelected = widget.onSelected;
    final IconData? leading = widget.leadingIcon;
    final List<DropdownMenuEntry<T>> entries = <DropdownMenuEntry<T>>[
      for (final AppDropdownItem<T> item in widget.items) _entry(item),
      if (widget.pinnedLast case final AppDropdownItem<T> pinned) _entry(pinned),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => DropdownMenu<T>(
        controller: _text,
        enabled: onSelected != null,
        width: constraints.maxWidth,
        menuHeight: AppSpacing.minTouchTarget * 6,
        label: OneLineText(widget.label),
        hintText: widget.hintText,
        helperText: widget.helperText,
        errorText: widget.errorText,
        leadingIcon: leading == null ? null : Icon(leading),
        initialSelection: widget.value,
        enableFilter: true,
        requestFocusOnTap: true,
        textStyle: context.text.bodyLarge,
        filterCallback: (List<DropdownMenuEntry<T>> all, String filter) {
          final Set<T> keep = <T>{
            for (final AppDropdownItem<T> item in AppDropdownMenu.filter<T>(widget.items, filter, pinned: widget.pinnedLast)) item.value,
          };
          return <DropdownMenuEntry<T>>[for (final DropdownMenuEntry<T> e in all) if (keep.contains(e.value)) e];
        },
        onSelected: onSelected == null
            ? null
            : (T? value) {
                if (value != null) {
                  onSelected(value);
                }
              },
        dropdownMenuEntries: entries,
      ),
    );
  }
}
