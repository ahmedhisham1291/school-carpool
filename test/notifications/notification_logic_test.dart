// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Locale;
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_labels.dart';
import 'package:school_carpool/features/notifications/notification_logic.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/push_messaging.dart';
import 'package:school_carpool/l10n/l10n.dart';

import '../helpers/notification_fakes.dart';

void main() {
  group('kinds', () {
    test('every server type is known, with the same critical ones', () {
      // functions/src/notifications/catalog.ts (critical-alarm is a push only, never a record).
      const List<String> server = <String>[
        'plan-ready', 'no-driver', 'swap-requested', 'swap-accepted', 'swap-cancelled', 'run-taken', //
        'child-absent', 'child-back', 'driver-unavailable', 'schedule-changed', 'time-changed', 'drive-evening', 'drive-hour',
        'confirm-reminder', 'join-requested', 'join-approved', 'join-declined', 'verification-approved',
        'verification-rejected', 'new-parent', 'child-not-confirmed', 'chat-message',
      ];
      expect(NotificationKind.values.map((NotificationKind k) => k.wire), server);
      expect(
        NotificationKind.values.where((NotificationKind k) => k.critical).map((NotificationKind k) => k.wire),
        <String>['no-driver', 'child-not-confirmed'],
      );
      expect(NotificationKind.fromWire('launch-rockets'), isNull);
      expect(NotificationKind.chatMessage.group, isNull);
    });

    test('a run moved with no time to confirm again is critical by event, not by kind', () {
      final AppNotification n = AppNotification.fromDoc('t1', NotificationKind.timeChanged, <String, dynamic>{
        'critical': true,
        'route': '/carpools/k1/schedule',
        'date': '2026-11-17',
        'direction': 'toSchool',
      });
      expect(NotificationKind.timeChanged.critical, isFalse);
      expect(n.critical, isTrue);
      expect(n.markedRead(notifNow).critical, isTrue);
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(notificationBody(en, n), 'The Tue 17/11, to school run has a new time. Check the plan.');
      expect(AppNotification.fromDoc('t2', NotificationKind.timeChanged, const <String, dynamic>{}).critical, isFalse);
    });

    test('COST MODE: WhatsApp on by default only for the urgent groups', () {
      expect(
        WhatsAppGroup.values.where((WhatsAppGroup g) => g.defaultOn),
        <WhatsAppGroup>[WhatsAppGroup.noDriver, WhatsAppGroup.childNotConfirmed],
      );
      const NotificationSettings s = NotificationSettings();
      expect(s.whatsappOn(WhatsAppGroup.noDriver), isTrue);
      expect(s.whatsappOn(WhatsAppGroup.swaps), isFalse);
      expect(s.withWhatsApp(WhatsAppGroup.swaps, true).whatsappOn(WhatsAppGroup.swaps), isTrue);
    });

    test('stored settings: odd values fall back to the defaults', () {
      final NotificationSettings s = NotificationSettings.fromDoc(<String, dynamic>{
        'whatsapp': <String, dynamic>{'swaps': true, 'noDriver': 'no', 'hack': true},
        'quiet': <String, dynamic>{'on': false, 'from': 21},
      });
      expect(s.whatsappOn(WhatsAppGroup.swaps), isTrue);
      expect(s.whatsappOn(WhatsAppGroup.noDriver), isTrue);
      expect(s.quietHours, isFalse);
      expect(s.quietFrom, '22:00');
      expect(NotificationSettings.fromDoc(null).quietHours, isTrue);
    });
  });

  group('routes from the server are checked', () {
    test('only our screens', () {
      expect(NotificationRoutes.safe('/carpools/k1/schedule'), '/carpools/k1/schedule');
      expect(NotificationRoutes.safe('/carpools/k1'), '/carpools/k1');
      expect(NotificationRoutes.safe('/profile'), '/profile');
      expect(NotificationRoutes.safe('/home/nearby'), '/home/nearby');
      for (final Object? bad in <Object?>[null, 5, '', 'https://evil.example', '/carpools/../admin', '/dev/gallery', '/carpools/k1/schedule?x=1']) {
        expect(NotificationRoutes.safe(bad), '/notifications', reason: '$bad');
      }
    });

    test('push data: flags and alarm time', () {
      final PushData d = PushData.fromMap(const <String, dynamic>{
        'notificationId': 'e1',
        'route': '/carpools/k1/schedule',
        'critical': '1',
        'alarm': '0',
        'alarmAt': '1794830400000',
      });
      expect(d.critical, isTrue);
      expect(d.alarm, isFalse);
      expect(d.alarmAt, DateTime.fromMillisecondsSinceEpoch(1794830400000, isUtc: true));
      final PushData odd = PushData.fromMap(const <String, dynamic>{'route': 'x', 'alarmAt': 'soon'});
      expect(odd.notificationId, '');
      expect(odd.route, '/notifications');
      expect(odd.alarmAt, isNull);
    });
  });

  group('alarms (spec section 11)', () {
    test('stable IDs and payloads', () {
      expect(alarmIdFor('abc'), alarmIdFor('abc'));
      expect(alarmIdFor('abc'), isNot(alarmIdFor('abd')));
      expect(alarmIdFor('x' * 500), inInclusiveRange(0, 0x7fffffff));
      expect(parseAlarmPayload(alarmPayload('n1', '/profile')), ('n1', '/profile'));
      expect(parseAlarmPayload('nobar'), isNull);
      expect(parseAlarmPayload(null), isNull);
    });

    test('schedule ahead, ring when due (once), cancel when opened or gone', () {
      final AppNotification ahead = testNotification('ahead', NotificationKind.noDriver, ago: const Duration(minutes: 1));
      final AppNotification due = testNotification('due', NotificationKind.noDriver, ago: const Duration(minutes: 20));
      final AppNotification opened = testNotification('opened', NotificationKind.childNotConfirmed, read: true);
      final AppNotification plain = testNotification('plain', NotificationKind.swapRequested);
      final int gone = alarmIdFor('gone');
      final AlarmPlan plan = planAlarms(
        <AppNotification>[ahead, due, opened, plain],
        now: notifNow,
        pending: <int>{gone, alarmIdFor('opened')},
        rung: <String>{},
      );
      expect(plan.schedule.map((AppNotification n) => n.id), <String>['ahead']);
      expect(plan.ringNow.map((AppNotification n) => n.id), <String>['due']);
      expect(plan.cancel, <int>{gone, alarmIdFor('opened')});
      // Already scheduled and already rung: nothing to do.
      final AlarmPlan again = planAlarms(
        <AppNotification>[ahead, due],
        now: notifNow,
        pending: <int>{alarmIdFor('ahead')},
        rung: <String>{'due'},
      );
      expect(again.isEmpty, isTrue);
    });
  });

  group('list and words', () {
    test('unread first, each newest first', () {
      final (List<AppNotification> fresh, List<AppNotification> earlier) = splitByRead(<AppNotification>[
        testNotification('old', NotificationKind.planReady, ago: const Duration(days: 2)),
        testNotification('readNew', NotificationKind.planReady, read: true),
        testNotification('new', NotificationKind.planReady, ago: const Duration(minutes: 1)),
      ]);
      expect(fresh.map((AppNotification n) => n.id), <String>['new', 'old']);
      expect(earlier.map((AppNotification n) => n.id), <String>['readNew']);
    });

    test('every kind has a title and a sentence in Arabic and English, with the run and no names', () {
      for (final Locale locale in AppLocales.supported) {
        final AppLocalizations l10n = lookupAppLocalizations(locale);
        for (final NotificationKind k in NotificationKind.values) {
          final AppNotification n = testNotification('x', k);
          expect(notificationTitle(l10n, k), isNotEmpty);
          final String body = notificationBody(l10n, n);
          expect(body, isNotEmpty);
          for (final String name in <String>['Adam', 'Laila', 'Mona', 'Hoda']) {
            expect(body.contains(name), isFalse);
          }
        }
      }
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      expect(notificationWhen(en, testNotification('x', NotificationKind.noDriver)), 'Tue 17/11, to school');
      expect(
        notificationBody(en, testNotification('x', NotificationKind.noDriver)),
        'No driver for Tue 17/11, to school. Please take your own child.',
      );
      expect(whatsAppGroupTitle(en, WhatsAppGroup.reminders), 'Drive reminders');
    });

    test('time: today as HH:MM, earlier days as weekday and date', () {
      final AppLocalizations en = lookupAppLocalizations(AppLocales.english);
      final DateTime local = notifNow.toLocal();
      expect(notificationTime(en, notifNow, local), matches(RegExp(r'^\d\d:\d\d$')));
      expect(notificationTime(en, notifNow.subtract(const Duration(days: 3)), local), contains('/'));
    });
  });
}
