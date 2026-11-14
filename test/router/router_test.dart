// Written, not run here (no Flutter SDK in the build workspace).
// Runs in CI on Codemagic: `flutter test`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpools_screen.dart';
import 'package:school_carpool/features/gallery/gallery_screen.dart';
import 'package:school_carpool/features/home/home_screen.dart';
import 'package:school_carpool/features/placeholder/placeholder_tab_screen.dart';
import 'package:school_carpool/features/profile/profile_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';

import '../helpers/test_app.dart';

void main() {
  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    required FlavorConfig config,
  }) async {
    final GoRouter router = buildAppRouter(showDevTools: config.showDevTools);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          flavorConfigProvider.overrideWithValue(config),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
          ...authOverrides(),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: AppLocales.english,
          supportedLocales: AppLocales.supported,
          localizationsDelegates: AppLocales.delegates,
          theme: AppTheme.light(DesignDirection.a),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  String currentPath(GoRouter router) => router.routerDelegate.currentConfiguration.uri.path;

  testWidgets('shows the five tabs from spec section 10, Home first', (WidgetTester tester) async {
    final GoRouter router = await pumpRouter(tester, config: testDevConfig);
    expect(find.byType(AppNavigationBarItem), findsNWidgets(5));
    expect(currentPath(router), AppTab.home.path);
    for (final String label in <String>['Home', 'Carpools', 'Chats', 'Alerts', 'Profile']) {
      expect(find.text(label), findsWidgets);
    }
  });

  testWidgets('each tab opens its own screen', (WidgetTester tester) async {
    final GoRouter router = await pumpRouter(tester, config: testDevConfig);
    final Map<IconData, AppTab> icons = <IconData, AppTab>{
      Icons.chat_bubble_outline_rounded: AppTab.chats,
      Icons.notifications_none_rounded: AppTab.notifications,
    };
    for (final MapEntry<IconData, AppTab> entry in icons.entries) {
      await tester.tap(find.byIcon(entry.key).first);
      await tester.pumpAndSettle();
      expect(currentPath(router), entry.value.path);
      final PlaceholderTabScreen screen = tester.widget<PlaceholderTabScreen>(
        find.byType(PlaceholderTabScreen).hitTestable(),
      );
      expect(screen.tab, entry.value);
    }
    // Carpools has its own screen since Prompt 6.
    await tester.tap(find.byIcon(Icons.directions_car_outlined).first);
    await tester.pumpAndSettle();
    expect(currentPath(router), AppTab.carpools.path);
    expect(find.byType(CarpoolsScreen).hitTestable(), findsOneWidget);
    // Home has its own screen since Prompt 5 (parents nearby, home, driving schools).
    await tester.tap(find.byIcon(Icons.home_outlined).first);
    await tester.pumpAndSettle();
    expect(currentPath(router), AppTab.home.path);
    expect(find.byType(HomeScreen).hitTestable(), findsOneWidget);
    // Profile has its own screen since Prompt 2.
    await tester.tap(find.byIcon(Icons.person_outline_rounded).first);
    await tester.pumpAndSettle();
    expect(currentPath(router), AppTab.profile.path);
    expect(find.byType(ProfileScreen).hitTestable(), findsOneWidget);
  });

  testWidgets('dev build opens the component gallery', (WidgetTester tester) async {
    final GoRouter router = await pumpRouter(tester, config: testDevConfig);
    router.go(AppRoutes.gallery);
    // The gallery has a looping skeleton animation, so do not pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GalleryScreen), findsOneWidget);
  });

  testWidgets('staging build has no gallery route', (WidgetTester tester) async {
    final GoRouter router = await pumpRouter(tester, config: testStagingConfig);
    router.go(AppRoutes.gallery);
    await tester.pumpAndSettle();
    expect(find.byType(GalleryScreen), findsNothing);
  });

  testWidgets('staging build hides developer tools on Profile', (WidgetTester tester) async {
    await pumpRouter(tester, config: testStagingConfig);
    await tester.tap(find.byIcon(Icons.person_outline_rounded));
    await tester.pumpAndSettle();
    // Profile is long (children and car rows since Prompt 3): scroll to the settings.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings.language')),
      200,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    expect(find.byKey(const Key('settings.language')), findsOneWidget);
    expect(find.byKey(const Key('dev.gallery')), findsNothing);
  });
}
