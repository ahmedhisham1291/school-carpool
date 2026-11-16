// Architecture rules for the Flutter code (docs/architecture/overview.md).
// Static checks over lib/: no widgets pumped, no Firebase. `flutter test`
// runs from the package root, so paths are relative to it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every Dart file under [dir], path with forward slashes, sorted.
List<String> _dartFiles(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .map((File f) => f.path.replaceAll(r'\', '/'))
        .where((String p) => p.endsWith('.dart') && !p.contains('/l10n/gen/'))
        .toList()
      ..sort();

/// Packages that talk to Firebase data services.
final RegExp _firebaseData = RegExp(
  r"import 'package:(cloud_firestore|cloud_functions|firebase_storage|firebase_auth)/",
);

/// Files allowed to talk to Firebase: the data layer of each feature.
final RegExp _dataFile = RegExp(
  r'(_repository|_models|_failure|_search|_api|/session|/account|/feature_switches|/demo_refusal)\.dart$',
);

void main() {
  final List<String> features = _dartFiles('lib/features');

  test('only the data layer of a feature imports Firebase data packages', () {
    // Known exceptions, each with its reason. Do not add to this list:
    // put the call in the feature's repository and read it through a provider.
    const Set<String> allowed = <String>{
      // sessionRenewerProvider (signInWithCustomToken after "sign out other
      // phones"); belongs in privacy_repository.dart, kept to avoid moving a
      // provider tests import from here.
      'lib/features/privacy/devices_screen.dart',
      // Dev-only Sentry check button (debugTestError), dev flavor only.
      'lib/features/settings/settings_section.dart',
    };
    final List<String> bad = <String>[
      for (final String path in features)
        if (!_dataFile.hasMatch(path) && !allowed.contains(path) && _firebaseData.hasMatch(File(path).readAsStringSync()))
          path,
    ];
    expect(bad, isEmpty, reason: 'Screens and widgets read data through repositories and providers.');
  });

  test('collection names come from lib/firebase/collections.dart', () {
    // The chat is rewritten on the chat-review-safe branch (Firestore chat);
    // it moves to Collections there.
    const Set<String> allowed = <String>{'lib/features/chat/chat_repository.dart'};
    final RegExp literal = RegExp(r"\.(collection|collectionGroup)\('");
    final List<String> bad = <String>[
      for (final String path in _dartFiles('lib'))
        if (!allowed.contains(path) && literal.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(bad, isEmpty, reason: 'Use Collections.<name> so a typo is a compile error.');
  });

  test('the design system does not depend on features, admin or the router', () {
    // dropdown_menu_field.dart uses the Arabic text normalizer of schools;
    // it belongs in the design system (move when schools is quiet).
    const Set<String> allowed = <String>{'lib/design/components/dropdown_menu_field.dart'};
    final RegExp upward = RegExp(r"import 'package:school_carpool/(features|admin|router)/");
    final List<String> bad = <String>[
      for (final String path in _dartFiles('lib/design'))
        if (!allowed.contains(path) && upward.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(bad, isEmpty);
  });

  test('the parent app does not grow new imports of the admin panel', () {
    // Shared Egypt geography (kGovernorates, GeoPin, governorateLabel,
    // parsePin) still lives under lib/admin. Ratchet: these files only.
    const Set<String> allowed = <String>{
      'lib/features/maps/geo.dart',
      'lib/features/places/address_screen.dart',
      'lib/features/schools/browse_schools_screen.dart',
      'lib/features/schools/other_school_screen.dart',
      'lib/features/schools/school_picker_screen.dart',
      'lib/features/schools/school_repository.dart',
    };
    final RegExp admin = RegExp(r"import 'package:school_carpool/admin/");
    final List<String> bad = <String>[
      for (final String path in features)
        if (!allowed.contains(path) && admin.hasMatch(File(path).readAsStringSync())) path,
    ];
    expect(bad, isEmpty);
  });

  test('failure types implement AppFailure', () {
    // Types without a message of their own (PlaceFailure, LocationFailure,
    // SchoolSearchFailure) and the chat (chat-review-safe) are exempt.
    const Set<String> exempt = <String>{'AppFailure', 'PlaceFailure', 'LocationFailure', 'SchoolSearchFailure', 'ChatFailure'};
    final RegExp plain = RegExp(r'class (\w+Failure) implements Exception');
    final List<String> bad = <String>[
      for (final String path in _dartFiles('lib'))
        for (final RegExpMatch m in plain.allMatches(File(path).readAsStringSync()))
          if (!exempt.contains(m.group(1))) '$path: ${m.group(1)}',
    ];
    expect(bad, isEmpty, reason: 'class XFailure implements AppFailure (lib/core/app_failure.dart).');
  });
}
