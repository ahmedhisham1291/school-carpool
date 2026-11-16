import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:school_carpool/config/app_version.dart';
import 'package:school_carpool/features/auth/install_id.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';

/// Written consent for sensitive data (R3, docs/legal/answers.md 1.4):
/// each sensitive consent is its own unticked box, signed with the typed
/// full name (it must match the ID name; at sign-up there is none yet) and
/// a fresh Face ID / fingerprint / passcode check. A phone without a lock
/// signs with a sign-in less than 10 minutes old (the server checks it).
/// The server keeps the version, a hash of the text, the time, the device
/// and the app version, and the parent opens a copy under Privacy.
///
/// The name rules are the same as functions/src/auth/signature.ts
/// (normaliseName, nameLooksFull, nameMatches); test/auth/consent_signature_test.dart
/// checks the same examples as the server test.

final RegExp _diacritics = RegExp('[\u064B-\u065F\u0670\u06D6-\u06ED]');
final RegExp _notLetters = RegExp(r'[^\p{L}]+', unicode: true);

/// "عبد الله" and "عبدالله" (and "Abd El", "Abdel") are the same name; the
/// server runs the same three steps in this order.
final List<RegExp> _joined = <RegExp>[
  RegExp(r'(^| )(عبد) (?=\p{L})', unicode: true),
  RegExp(r'(^| )(abd) (?=\p{L})', unicode: true),
  RegExp(r'(^| )(abdel) (?=\p{L})', unicode: true),
];

const Map<String, String> _latinAccents = <String, String>{
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ç': 'c', 'ñ': 'n',
};

/// Names compared as people type them (Arabic first).
String normaliseName(String value) {
  String s = value.toLowerCase();
  _latinAccents.forEach((String from, String to) => s = s.replaceAll(from, to));
  s = s
      .replaceAll(_diacritics, '')
      .replaceAll('\u0640', '')
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll(_notLetters, ' ');
  for (final RegExp joined in _joined) {
    s = s.replaceAllMapped(joined, (Match m) => '${m[1]}${m[2]}');
  }
  return s.trim();
}

List<String> _words(String value) => normaliseName(value).split(' ').where((String w) => w.isNotEmpty).toList();

/// Letters only, at least two words, at most 80 characters.
bool nameLooksFull(String value) => normaliseName(value).length >= 4 && value.trim().length <= 80 && _words(value).length >= 2;

/// The typed name starts with the first name and holds the family name's
/// words in order (fathers' and grandfathers' names in between are fine).
bool nameMatches(String typed, String firstName, String lastName) {
  final List<String> t = _words(typed);
  final List<String> first = _words(firstName);
  final List<String> last = _words(lastName);
  if (t.isEmpty || first.isEmpty || last.isEmpty || t.length < first.length) {
    return false;
  }
  for (int i = 0; i < first.length; i++) {
    if (t[i] != first[i]) {
      return false;
    }
  }
  int at = first.length;
  for (final String word in last) {
    final int found = t.indexOf(word, at);
    if (found < 0) {
      return false;
    }
    at = found + 1;
  }
  return true;
}

/// How the parent confirmed (server: SIGN_METHODS).
enum SignMethod { deviceAuth, recentSignIn }

/// What the app sends with a signed consent (server: parseSignature).
@immutable
class ConsentSignature {
  const ConsentSignature({required this.fullName, required this.method, required this.deviceId, required this.platform, required this.language, required this.appVersion});

  final String fullName;
  final SignMethod method;
  final String deviceId;
  final String platform;
  final String language;
  final String appVersion;

  Map<String, Object?> toPayload() => <String, Object?>{
    'fullName': fullName.trim().replaceAll(RegExp(r'\s+'), ' '),
    'method': method.name,
    'deviceId': deviceId,
    'platform': platform,
    'appVersion': appVersion,
    'language': language,
  };
}

/// The result of asking the phone for the signature's device check.
sealed class SignOutcome {
  const SignOutcome();
}

final class Signed extends SignOutcome {
  const Signed(this.signature);
  final ConsentSignature signature;
}

/// The parent cancelled Face ID / passcode: nothing is sent.
final class SignCancelled extends SignOutcome {
  const SignCancelled();
}

/// Asks for Face ID / fingerprint / passcode right now (never cached). A
/// phone with no lock falls back to "recentSignIn": the server accepts it
/// only within 10 minutes of a sign-in (reason "reauth-required" otherwise).
Future<SignOutcome> signConsent(
  WidgetRef ref, {
  required String fullName,
  required String reason,
  required String language,
}) async {
  final DeviceAuthResult result = await ref.read(deviceAuthProvider).confirm(reason);
  if (result == DeviceAuthResult.cancelled) {
    return const SignCancelled();
  }
  return Signed(
    ConsentSignature(
      fullName: fullName,
      method: result == DeviceAuthResult.ok ? SignMethod.deviceAuth : SignMethod.recentSignIn,
      deviceId: ref.read(installIdProvider),
      platform: platformName(),
      language: language,
      appVersion: appVersionLabel(),
    ),
  );
}
