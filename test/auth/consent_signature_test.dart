import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/features/auth/consent_signature.dart';

/// R3: the same name examples as functions/test/signature.test.ts, so the
/// app checks the typed name exactly like the server does.
void main() {
  group('normaliseName', () {
    test('Arabic as people type it', () {
      expect(normaliseName('  أحمـــد   إبراهيم  '), 'احمد ابراهيم');
      expect(normaliseName('فاطمة'), normaliseName('فاطمه'));
      expect(normaliseName('مُصطفى'), 'مصطفي');
      expect(normaliseName('عبد الله'), normaliseName('عبدالله'));
      expect(normaliseName("José  O'Neil"), 'jose o neil');
    });
  });

  group('nameLooksFull', () {
    test('two words of letters', () {
      expect(nameLooksFull('Omar Hassan'), isTrue);
      expect(nameLooksFull('عمر حسن'), isTrue);
      expect(nameLooksFull('Omar'), isFalse);
      expect(nameLooksFull('12 34'), isFalse);
      expect(nameLooksFull('${'x' * 90} y'), isFalse);
    });
  });

  group('nameMatches', () {
    test('the ID name, with fathers and grandfathers in between', () {
      expect(nameMatches('عمر حسن', 'عمر', 'حسن'), isTrue);
      expect(nameMatches('عُمر محمد أحمد حسن', 'عمر', 'حسن'), isTrue);
      expect(nameMatches('Omar Mohamed Hassan', 'omar', 'Hassan'), isTrue);
      expect(nameMatches('عبدالله محمد', 'عبد الله', 'محمد'), isTrue);
      expect(nameMatches('حسن عمر', 'عمر', 'حسن'), isFalse);
      expect(nameMatches('عمر علي', 'عمر', 'حسن'), isFalse);
      expect(nameMatches('', 'عمر', 'حسن'), isFalse);
    });
  });

  test('payload sent to the server', () {
    const ConsentSignature s = ConsentSignature(
      fullName: ' Omar   Hassan ',
      method: SignMethod.recentSignIn,
      deviceId: '0123456789abcdef0123456789abcdef',
      platform: 'ios',
      language: 'en',
      appVersion: '1.0.0+1',
    );
    expect(s.toPayload(), <String, Object?>{
      'fullName': 'Omar Hassan',
      'method': 'recentSignIn',
      'deviceId': '0123456789abcdef0123456789abcdef',
      'platform': 'ios',
      'appVersion': '1.0.0+1',
      'language': 'en',
    });
  });
}
