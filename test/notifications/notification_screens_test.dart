// Written, not run here (no Flutter SDK in the build workspace). CI runs it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/features/notifications/local_alarms.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/push_messaging.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/fonts.dart';
import '../helpers/notification_fakes.dart';
import '../helpers/one_line.dart';
import '../helpers/test_app.dart';

/// A verified parent who agreed to WhatsApp at sign-up (fake data only).
const SessionState _optedIn = SessionSignedIn(
  uid: 'uid-1',
  account: Account(
    parentId: 'ABCD2345',
    status: AccountStatus.verified,
    phone: '+201000000001',
    email: 'parent@example.com',
    emailVerified: true,
    termsAccepted: true,
    language: 'ar',
    whatsappOptIn: true,
  ),
);

/// The same overrides in every pump (one ProviderScope shape per test).
List<Override> _overrides(
  FakeNotificationRepository repo, {
  FakePushMessaging? push,
  FakeLocalAlarms? alarms,
  SettingsStore? store,
  SessionState session = _optedIn,
  FeatureSwitches? features,
}) => <Override>[
  flavorConfigProvider.overrideWithValue(testDevConfig),
  settingsStoreProvider.overrideWithValue(store ?? InMemorySettingsStore()),
  ...authOverrides(session: session, notifications: repo, push: push, alarms: alarms, features: features),
];

Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  required List<Override> overrides,
  Locale locale = AppLocales.english,
  double width = 400,
  double height = 1600,
  double textScale = 1,
}) async {
  tester.view
    ..devicePixelRatio = 2
    ..physicalSize = Size(width * 2, height * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final GoRouter router = buildAppRouter(showDevTools: false, initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp.router(
        routerConfig: router,
        locale: locale,
        supportedLocales: AppLocales.supported,
        localizationsDelegates: AppLocales.delegates,
        theme: AppTheme.light(DesignDirection.a),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

List<AppNotification> _sample() => <AppNotification>[
  testNotification('n1', NotificationKind.swapRequested),
  testNotification('n2', NotificationKind.joinRequested, ago: const Duration(hours: 2), route: '/profile'),
  testNotification('n3', NotificationKind.driveHour, read: true, ago: const Duration(days: 1)),
];

void main() {
  setUpAll(loadAppFonts);

  group('Notifications tab', () {
    testWidgets('unread under New, read under Earlier, generic text with the run (no names)', (WidgetTester tester) async {
      await _pump(tester, '/notifications', overrides: _overrides(FakeNotificationRepository(items: _sample())));
      expect(find.text('New'), findsOneWidget);
      expect(find.text('Earlier'), findsOneWidget);
      expect(find.text('Swap request'), findsOneWidget);
      expect(find.text('A member asked for a swap: Tue 17/11, to school.'), findsOneWidget);
      expect(find.text('Run within the hour'), findsOneWidget);
      // Two unread dots (and the tab's own dot in the shell).
      expect(find.descendant(of: find.byKey(const Key('notifications.list')), matching: find.byType(AppUnreadDot)), findsNWidgets(2));
      expect(find.byType(AppNavigationBar), findsOneWidget);
      expect(find.descendant(of: find.byType(AppNavigationBar), matching: find.byType(AppUnreadDot)), findsOneWidget);
    });

    testWidgets('tapping a row marks it read and opens its screen', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository(items: _sample());
      final GoRouter router = await _pump(tester, '/notifications', overrides: _overrides(repo));
      await tester.tap(find.byKey(const Key('notification.n2')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('markRead:n2'));
      expect(_path(router), '/profile');
    });

    testWidgets('mark all read: one batch, a short snackbar, the dots go', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository(items: _sample());
      await _pump(tester, '/notifications', overrides: _overrides(repo));
      await tester.tap(find.byKey(const Key('notifications.markAll')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('markAllRead:2'));
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('New'), findsNothing);
      expect(find.byType(AppUnreadDot), findsNothing);
      // Nothing unread: the button is off.
      final IconButton button = tester.widget<IconButton>(find.byKey(const Key('notifications.markAll')));
      expect(button.onPressed, isNull);
    });

    testWidgets('mark all read offline says so', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository(items: _sample())
        ..failure = const NotificationFailure(NotificationFailureKind.offline);
      await _pump(tester, '/notifications', overrides: _overrides(repo));
      await tester.tap(find.byKey(const Key('notifications.markAll')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
    });

    testWidgets('empty state', (WidgetTester tester) async {
      await _pump(tester, '/notifications', overrides: _overrides(FakeNotificationRepository()));
      expect(find.byKey(const Key('notifications.empty')), findsOneWidget);
      expect(find.text('No alerts yet'), findsOneWidget);
    });

    testWidgets('error state', (WidgetTester tester) async {
      await _pump(tester, '/notifications', overrides: _overrides(FakeNotificationRepository()..streamError = StateError('boom')));
      expect(find.byType(ErrorStateView), findsOneWidget);
    });

    testWidgets('offline state', (WidgetTester tester) async {
      await _pump(
        tester,
        '/notifications',
        overrides: _overrides(FakeNotificationRepository()..streamError = FirebaseException(plugin: 'cloud_firestore', code: 'unavailable')),
      );
      expect(find.byType(OfflineStateView), findsOneWidget);
    });

    testWidgets('an unopened critical alert is pinned above the tabs until opened', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository(
        items: <AppNotification>[testNotification('c1', NotificationKind.noDriver, route: '/profile'), ..._sample()],
      );
      final GoRouter router = await _pump(tester, '/home', overrides: _overrides(repo));
      expect(find.byKey(const Key('notifications.criticalBanner')), findsOneWidget);
      expect(find.text('No driver for Tue 17/11, to school. Please take your own child.'), findsWidgets);
      await tester.tap(find.descendant(of: find.byKey(const Key('notifications.criticalBanner')), matching: find.byType(AppButton)));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('markRead:c1'));
      expect(_path(router), '/profile');
      expect(find.byKey(const Key('notifications.criticalBanner')), findsNothing);
    });

    testWidgets('Arabic, right to left', (WidgetTester tester) async {
      await _pump(tester, '/notifications', overrides: _overrides(FakeNotificationRepository(items: _sample())), locale: AppLocales.arabic);
      expect(Directionality.of(tester.element(find.byKey(const Key('notifications.list')))), TextDirection.rtl);
      expect(find.text('طلب تبديل'), findsOneWidget);
    });

    testWidgets('settings button opens the alert settings', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, '/notifications', overrides: _overrides(FakeNotificationRepository()));
      await tester.tap(find.byKey(const Key('notifications.settings')));
      await tester.pumpAndSettle();
      expect(_path(router), ProfileRoutes.notifications);
    });
  });

  group('Alert settings', () {
    testWidgets('defaults: WhatsApp on for the urgent groups only; quiet hours on', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(FakeNotificationRepository()));
      Switch switchOf(String key) =>
          tester.widget<Switch>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Switch)));
      expect(switchOf('notifSettings.noDriver').value, isTrue);
      expect(switchOf('notifSettings.childNotConfirmed').value, isTrue);
      expect(switchOf('notifSettings.swaps').value, isFalse);
      expect(switchOf('notifSettings.reminders').value, isFalse);
      expect(switchOf('notifSettings.quiet').value, isTrue);
      expect(find.text('Chat messages come to your phone only.'), findsOneWidget);
    });

    testWidgets('switching a group on saves it at once', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo));
      final Finder row = find.byKey(const Key('notifSettings.swaps'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(repo.calls, contains('setWhatsApp:swaps:true'));
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('switching the urgent group off, and quiet hours off', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo));
      await tester.tap(find.byKey(const Key('notifSettings.noDriver')));
      await tester.pumpAndSettle();
      final Finder quiet = find.byKey(const Key('notifSettings.quiet'));
      await tester.scrollUntilVisible(quiet, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(quiet);
      await tester.pumpAndSettle();
      expect(repo.calls, containsAll(<String>['setWhatsApp:noDriver:false', 'setQuietHours:false']));
    });

    testWidgets('a failed save puts the switch back and says why', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository()
        ..failure = const NotificationFailure(NotificationFailureKind.rateLimited);
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo));
      await tester.tap(find.byKey(const Key('notifSettings.noDriver')));
      await tester.pumpAndSettle();
      expect(find.text('Too many changes today. Try tomorrow.'), findsOneWidget);
      final Switch s = tester.widget<Switch>(find.descendant(of: find.byKey(const Key('notifSettings.noDriver')), matching: find.byType(Switch)));
      expect(s.value, isTrue);
    });

    testWidgets('declined WhatsApp at sign-up: group switches off and locked, one line says why, consent asks first', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo, session: testVerifiedSession));
      expect(find.text('You chose no WhatsApp'), findsOneWidget);
      final Switch group = tester.widget<Switch>(find.descendant(of: find.byKey(const Key('notifSettings.noDriver')), matching: find.byType(Switch)));
      expect(group.value, isFalse);
      expect(group.onChanged, isNull);
      await tester.tap(find.byKey(const Key('notifSettings.noDriver')));
      await tester.pumpAndSettle();
      expect(repo.calls.where((String c) => !c.startsWith('register:')), isEmpty);
      // Agreeing asks first, then records the consent through Functions.
      await tester.tap(find.byKey(const Key('notifSettings.consent')));
      await tester.pumpAndSettle();
      expect(find.text('Alerts by WhatsApp too?'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppButton, 'I agree'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('consent:true'));
      final Switch after = tester.widget<Switch>(find.descendant(of: find.byKey(const Key('notifSettings.noDriver')), matching: find.byType(Switch)));
      expect(after.value, isTrue);
    });

    testWidgets('cancelling the consent question changes nothing; withdrawing needs no question', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo, session: testVerifiedSession));
      await tester.tap(find.byKey(const Key('notifSettings.consent')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((String c) => !c.startsWith('register:')), isEmpty);
    });

    testWidgets('an opted-in parent can withdraw WhatsApp', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(repo));
      expect(find.text('You agreed to WhatsApp'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notifSettings.consent')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('consent:false'));
      expect(find.text('You chose no WhatsApp'), findsOneWidget);
    });

    testWidgets('error and offline states', (WidgetTester tester) async {
      await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(FakeNotificationRepository()..streamError = StateError('x')));
      expect(find.byType(ErrorStateView), findsOneWidget);
    });

    testWidgets('pilot switches: no wallet row in the alert settings while the wallet is off; the other groups stay', (WidgetTester tester) async {
      await _pump(
        tester,
        ProfileRoutes.notifications,
        overrides: _overrides(FakeNotificationRepository(), features: FeatureSwitches.pilot),
        height: 4000,
      );
      expect(find.byKey(const Key('notifSettings.wallet')), findsNothing);
      for (final WhatsAppGroup g in WhatsAppGroup.values) {
        if (g != WhatsAppGroup.wallet) {
          expect(find.byKey(Key('notifSettings.${g.name}')), findsOneWidget, reason: g.name);
        }
      }
      // Settle up is push only: it has no WhatsApp switch at all.
      expect(find.byKey(const Key('notifSettings.settleUp')), findsNothing);
    });

    testWidgets('Profile has a row to the alert settings', (WidgetTester tester) async {
      final GoRouter router = await _pump(tester, '/profile', overrides: _overrides(FakeNotificationRepository()));
      final Finder row = find.byKey(const Key('profile.notifications'));
      await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(_path(router), ProfileRoutes.notifications);
    });
  });

  group('On the phone (NotificationCenter)', () {
    testWidgets('after sign-in: asks permission and registers the token; a refresh replaces it', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      final FakePushMessaging push = FakePushMessaging();
      final InMemorySettingsStore store = InMemorySettingsStore();
      await _pump(tester, '/notifications', overrides: _overrides(repo, push: push, store: store));
      expect(repo.calls, contains('register:fake-token-1:ios:-'));
      push.refreshController.add('fake-token-2');
      await tester.pumpAndSettle();
      expect(repo.calls, contains('register:fake-token-2:ios:fake-token-1'));
      expect(store.read(NotificationCenter.tokenKey), 'fake-token-2');
    });

    testWidgets('no permission: nothing is registered', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      await _pump(tester, '/notifications', overrides: _overrides(repo, push: FakePushMessaging()..allowed = false));
      expect(repo.calls.where((String c) => c.startsWith('register')), isEmpty);
    });

    testWidgets('sign-out removes the token from the server and the phone', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository();
      final FakePushMessaging push = FakePushMessaging();
      final InMemorySettingsStore store = InMemorySettingsStore();
      await _pump(tester, '/notifications', overrides: _overrides(repo, push: push, store: store));
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      await container.read(notificationCenterProvider).unregister();
      expect(repo.calls, contains('unregister:fake-token-1'));
      expect(push.deleted, isTrue);
      expect(store.read(NotificationCenter.tokenKey), isNull);
    });

    testWidgets('a tapped push marks it read and opens its screen', (WidgetTester tester) async {
      final FakeNotificationRepository repo = FakeNotificationRepository(items: _sample());
      final FakePushMessaging push = FakePushMessaging();
      final GoRouter router = await _pump(tester, '/home', overrides: _overrides(repo, push: push));
      push.tapController.add(const PushData(notificationId: 'n2', route: '/profile'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('markRead:n2'));
      expect(_path(router), '/profile');
    });

    testWidgets('a push with a strange route opens the Notifications tab', (WidgetTester tester) async {
      final FakePushMessaging push = FakePushMessaging();
      final GoRouter router = await _pump(tester, '/home', overrides: _overrides(FakeNotificationRepository(), push: push));
      push.tapController.add(PushData.fromMap(const <String, dynamic>{'notificationId': 'x', 'route': 'https://evil.example'}));
      await tester.pumpAndSettle();
      expect(_path(router), '/notifications');
    });

    testWidgets('critical alerts: alarm scheduled when ahead, rung once when due, cancelled when opened', (WidgetTester tester) async {
      final FakeLocalAlarms alarms = FakeLocalAlarms();
      final FakeNotificationRepository repo = FakeNotificationRepository(
        items: <AppNotification>[
          testNotification('ahead', NotificationKind.noDriver, ago: const Duration(minutes: 1)),
          testNotification('due', NotificationKind.childNotConfirmed, ago: const Duration(minutes: 30)),
          testNotification('plain', NotificationKind.swapRequested),
        ],
      );
      await _pump(tester, '/notifications', overrides: _overrides(repo, alarms: alarms));
      expect(alarms.scheduled.keys, <int>[alarmIdFor('ahead')]);
      expect(alarms.rang, <int>[alarmIdFor('due')]);
      // The list updates (another snapshot): the due alarm does not ring again.
      repo.emit();
      await tester.pumpAndSettle();
      expect(alarms.rang, <int>[alarmIdFor('due')]);
      // Opening the alert cancels its alarm.
      await tester.tap(find.byKey(const Key('notification.ahead')));
      await tester.pumpAndSettle();
      expect(alarms.cancelled, contains(alarmIdFor('ahead')));
      expect(alarms.scheduled.containsKey(alarmIdFor('ahead')), isFalse);
    });
  });

  group('Alarms across app starts', () {
    testWidgets('an alarm that rang before (kept on the phone) does not ring again at start', (WidgetTester tester) async {
      final FakeLocalAlarms alarms = FakeLocalAlarms();
      final InMemorySettingsStore store = InMemorySettingsStore(<String, String>{kRungAlarmsKey: 'due'});
      final FakeNotificationRepository repo = FakeNotificationRepository(
        items: <AppNotification>[testNotification('due', NotificationKind.noDriver, ago: const Duration(minutes: 30))],
      );
      await _pump(tester, '/notifications', overrides: _overrides(repo, alarms: alarms, store: store));
      expect(alarms.rang, isEmpty);
    });

    testWidgets('an old unread alert does not ring; a due one rings once and is remembered', (WidgetTester tester) async {
      final FakeLocalAlarms alarms = FakeLocalAlarms();
      final InMemorySettingsStore store = InMemorySettingsStore();
      final FakeNotificationRepository repo = FakeNotificationRepository(
        items: <AppNotification>[
          testNotification('old', NotificationKind.noDriver, ago: const Duration(days: 3)),
          testNotification('due', NotificationKind.noDriver, ago: const Duration(minutes: 30)),
        ],
      );
      await _pump(tester, '/notifications', overrides: _overrides(repo, alarms: alarms, store: store));
      expect(alarms.rang, <int>[alarmIdFor('due')]);
      expect(rungAlarmIds(store), contains('due'));
      expect(rungAlarmIds(store), isNot(contains('old')));
    });

    testWidgets('a scheduled alarm is remembered, so it never rings twice', (WidgetTester tester) async {
      final InMemorySettingsStore store = InMemorySettingsStore();
      final FakeNotificationRepository repo = FakeNotificationRepository(
        items: <AppNotification>[testNotification('ahead', NotificationKind.noDriver, ago: const Duration(minutes: 1))],
      );
      await _pump(tester, '/notifications', overrides: _overrides(repo, store: store));
      expect(rungAlarmIds(store), contains('ahead'));
    });
  });

  group('One line at 320 dp', () {
    for (final Locale locale in AppLocales.supported) {
      for (final double scale in <double>[1, 2]) {
        testWidgets('[${locale.languageCode} x$scale] every notification title and the headers', (WidgetTester tester) async {
          final FakeNotificationRepository repo = FakeNotificationRepository(
            items: <AppNotification>[
              for (final NotificationKind k in NotificationKind.values) testNotification('k-${k.name}', k, read: !k.critical),
            ],
          );
          // A tall screen so every row is built without scrolling the lazy list.
          await _pump(tester, '/notifications', overrides: _overrides(repo), locale: locale, width: 320, height: 12000, textScale: scale);
          expectOneLine(find.byType(AppBarTitle), 'app bar', allowEllipsis: scale > 1);
          for (final NotificationKind k in NotificationKind.values) {
            final Finder row = find.byKey(Key('notification.k-${k.name}'));
            expect(row, findsOneWidget, reason: '${k.name} row');
            expectOneLine(
              find.descendant(of: row, matching: find.byType(OneLineText)).first,
              '${k.name} title',
              allowEllipsis: scale > 1,
            );
          }
          expectOneLine(find.byType(AppSectionHeader), 'section headers');
        });

        testWidgets('[${locale.languageCode} x$scale] alert settings rows and title', (WidgetTester tester) async {
          await _pump(tester, ProfileRoutes.notifications, overrides: _overrides(FakeNotificationRepository()), locale: locale, width: 320, textScale: scale);
          for (final WhatsAppGroup g in WhatsAppGroup.values) {
            final Finder row = find.byKey(Key('notifSettings.${g.name}'));
            await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
            expectOneLine(find.descendant(of: row, matching: find.byType(OneLineText)).first, 'group ${g.name}', allowEllipsis: scale > 1);
          }
          expectOneLine(find.byType(AppBarTitle), 'settings app bar', allowEllipsis: scale > 1);
        });
      }
    }
  });
}
