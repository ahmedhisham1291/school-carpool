import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:material_ui/material_ui.dart';

Future<void> _loadFont(String family, List<String> assets) async {
  final FontLoader loader = FontLoader(family);
  for (final String asset in assets) {
    loader.addFont(rootBundle.load(asset));
  }
  await loader.load();
}

/// Loads the bundled app fonts, so text in tests has its real width (the
/// default test font draws every letter as a square).
Future<void> loadAppFonts() async {
  await _loadFont('IBMPlexSansArabic', <String>[
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Regular.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Medium.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-SemiBold.ttf',
    'assets/fonts/ibm_plex_sans_arabic/IBMPlexSansArabic-Bold.ttf',
  ]);
  await _loadFont('Tajawal', <String>[
    'assets/fonts/tajawal/Tajawal-Regular.ttf',
    'assets/fonts/tajawal/Tajawal-Medium.ttf',
    'assets/fonts/tajawal/Tajawal-Bold.ttf',
  ]);
  try {
    // Bundled by `uses-material-design: true`; without it icons are boxes.
    await _loadFont('MaterialIcons', <String>['fonts/MaterialIcons-Regular.otf']);
  } on Object catch (error) {
    debugPrint('fonts: Material icons font not loaded ($error)');
  }
}
