// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI on Codemagic: `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:school_carpool/observability/pii_scrubber.dart';
import 'package:school_carpool/observability/sentry_scrubber.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  const String r = PiiScrubber.redacted;

  group('scrubString removes', () {
    final Map<String, String> cases = <String, String>{
      'international phone': 'call +20 100 123 4567 now',
      'local phone': 'phone 01012345678',
      'phone with 0020': 'dial 00201012345678',
      'national ID (14 digits)': 'id 29001011234567 failed',
      'Arabic-Indic digits': 'رقم ٠١٠١٢٣٤٥٦٧٨',
      'coordinate pair': 'at 30.0444, 31.2357',
      'single precise coordinate': 'lat=30.044420',
      'email': 'mail parent@example.com',
    };
    cases.forEach((String name, String input) {
      test(name, () {
        final String out = PiiScrubber.scrubString(input);
        expect(out, contains(r));
        expect(RegExp(r'[0-9٠-٩]{7,}').hasMatch(out), isFalse, reason: out);
        expect(out, isNot(contains('@example.com')));
        expect(out, isNot(contains('31.2357')));
      });
    });
  });

  group('scrubString keeps harmless text', () {
    test('error codes and short numbers stay readable', () {
      const String input = 'permission-denied on step 3 (HTTP 404)';
      expect(PiiScrubber.scrubString(input), input);
    });
  });

  group('scrubMap', () {
    test('drops sensitive keys at any depth and cleans other values', () {
      final Map<String, dynamic> out = PiiScrubber.scrubMap(<String, dynamic>{
        'phoneNumber': '+201001234567',
        'national_id': '29001011234567',
        'lat': 30.0444,
        'Longitude': 31.2357,
        'text': 'see you at the gate',
        'screen': 'home',
        'nested': <String, dynamic>{
          'message': 'hello',
          'note_for_admin': 'call 01012345678',
          'list': <Object>['ok', '+201001234567'],
        },
      });
      expect(out['phoneNumber'], r);
      expect(out['national_id'], r);
      expect(out['lat'], r);
      expect(out['Longitude'], r);
      expect(out['text'], r);
      expect(out['screen'], 'home');
      final Map<String, dynamic> nested = out['nested'] as Map<String, dynamic>;
      expect(nested['message'], r);
      expect(nested['note_for_admin'], contains(r));
      expect(nested['list'], <Object?>['ok', r]);
    });
  });

  group('scrubSentryEvent', () {
    test('no phone, ID, coordinate, email or message text reaches Sentry', () {
      final SentryEvent event = SentryEvent(
        message: SentryMessage('could not send code to +201001234567'),
        user: SentryUser(id: 'uid-123', email: 'parent@example.com', ipAddress: '10.1.2.3'),
        tags: <String, String>{'phone': '01012345678', 'screen': 'home'},
        exceptions: <SentryException>[
          SentryException(type: 'StateError', value: 'bad id 29001011234567 at 30.0444,31.2357'),
        ],
        breadcrumbs: <Breadcrumb>[
          Breadcrumb(
            message: 'opened map at 30.0444, 31.2357',
            data: <String, dynamic>{'text': 'my secret message', 'route': '/home'},
          ),
        ],
      );

      final SentryEvent out = scrubSentryEvent(event, Hint());

      expect(out.message!.formatted, isNot(contains('1001234567')));
      expect(out.user!.id, 'uid-123');
      expect(out.user!.email, isNull);
      expect(out.user!.ipAddress, isNull);
      expect(out.tags!['phone'], PiiScrubber.redacted);
      expect(out.tags!['screen'], 'home');
      expect(out.exceptions!.single.value, isNot(contains('29001011234567')));
      expect(out.exceptions!.single.value, isNot(contains('31.2357')));
      final Breadcrumb crumb = out.breadcrumbs!.single;
      expect(crumb.message, isNot(contains('30.0444')));
      expect(crumb.data!['text'], PiiScrubber.redacted);
      expect(crumb.data!['route'], '/home');
      expect(out.request, isNull);
    });

    test('Prompt 12: exception mechanism data and app contexts are cleaned too', () {
      final SentryEvent event = SentryEvent(
        exceptions: <SentryException>[
          SentryException(
            type: 'StateError',
            value: 'failed',
            mechanism: Mechanism(
              type: 'generic',
              handled: true,
              description: 'sending to 01012345678',
              data: <String, dynamic>{'phoneNumber': '+201001234567', 'step': 3},
            ),
          ),
          SentryException(type: 'StateError', value: 'plain', mechanism: Mechanism(type: 'generic', handled: false)),
        ],
      );
      event.contexts['trip'] = <String, dynamic>{'lat': 30.0444, 'note': 'pick up Omar', 'stage': 'arrived'};

      final SentryEvent out = scrubSentryEvent(event, Hint());

      final Mechanism first = out.exceptions!.first.mechanism!;
      expect(first.data['phoneNumber'], PiiScrubber.redacted);
      expect(first.data['step'], 3);
      expect(first.description, isNot(contains('1012345678')));
      expect(first.handled, isTrue);
      expect(out.exceptions!.last.mechanism!.handled, isFalse);
      final Map<String, dynamic> trip = out.contexts['trip'] as Map<String, dynamic>;
      expect(trip['lat'], PiiScrubber.redacted);
      expect(trip['note'], PiiScrubber.redacted);
      expect(trip['stage'], 'arrived');
    });
  });
}
