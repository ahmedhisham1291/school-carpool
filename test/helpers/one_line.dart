import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The paragraphs that [finder] renders (the finder itself included).
List<RenderParagraph> paragraphsIn(Finder finder) => find
    .descendant(of: finder, matching: find.byType(RichText), matchRoot: true)
    .evaluate()
    .map((Element element) => element.renderObject! as RenderParagraph)
    .toList();

/// Why [paragraph] does not fit, with numbers: the text, the width it needs
/// on one line, the width it has, and by how much it is too long. Used in
/// failure messages so a failing one-line test says what to shorten.
String oneLineReport(RenderParagraph paragraph, String where) {
  final String text = paragraph.text.toPlainText();
  final double needed = paragraph.getMaxIntrinsicWidth(double.infinity);
  final double available = paragraph.constraints.maxWidth;
  final double over = needed - available;
  return '"$text" ($where): needs ${needed.toStringAsFixed(1)} px on one line, '
      'has ${available.toStringAsFixed(1)} px'
      '${over > 0 ? ', ${over.toStringAsFixed(1)} px too long: shorten the wording' : ''}';
}

/// Fails if any text under [finder] wraps onto a second line, or is cut off
/// with an ellipsis unless [allowEllipsis]. With [requireText] the finder
/// must render some text. The failure message names the text and its
/// widths ([oneLineReport]).
void expectOneLine(Finder finder, String where, {bool allowEllipsis = false, bool requireText = false}) {
  final List<RenderParagraph> paragraphs = paragraphsIn(finder);
  if (requireText) {
    expect(paragraphs, isNotEmpty, reason: 'no text found: $where');
  }
  for (final RenderParagraph paragraph in paragraphs) {
    final String text = paragraph.text.toPlainText();
    if (text.isEmpty) {
      continue;
    }
    // A box that starts in the lower half of the paragraph is a second line.
    final double half = paragraph.size.height / 2;
    final bool wraps = paragraph
        .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: text.length))
        .any((TextBox box) => box.top >= half);
    expect(wraps, isFalse, reason: 'wraps onto two lines: ${oneLineReport(paragraph, where)}');
    if (!allowEllipsis) {
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'cut off: ${oneLineReport(paragraph, where)}');
    }
  }
}
