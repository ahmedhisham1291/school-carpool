import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/privacy/device_guard.dart';
import 'package:school_carpool/features/schedule/offline_confirmations.dart';
import 'package:school_carpool/features/security/app_lock.dart';
import 'package:school_carpool/features/security/local_cache.dart';
import 'package:school_carpool/features/trips/tracker_guard.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Root widget. Language, theme mode and (dev only) design direction come
/// from persisted settings; Arabic and right-to-left are the default.
///
/// Also follows the phone's reduce-motion setting: theme changes, button
/// animations and page transitions become instant.
class CarpoolApp extends ConsumerStatefulWidget {
  const CarpoolApp({super.key});

  @override
  ConsumerState<CarpoolApp> createState() => _CarpoolAppState();
}

class _CarpoolAppState extends ConsumerState<CarpoolApp> with WidgetsBindingObserver {
  bool _reduceMotion = AppMotion.platformReducesMotion();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAccessibilityFeatures() {
    final bool reduce = AppMotion.platformReducesMotion();
    if (reduce != _reduceMotion) {
      setState(() => _reduceMotion = reduce);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FlavorConfig config = ref.watch(flavorConfigProvider);
    final Locale locale = ref.watch(localeProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    // Staging and prod always use direction A (owner decision, Prompt 1).
    final DesignDirection direction = config.showDevTools
        ? ref.watch(designDirectionProvider)
        : DesignDirection.a;
    final GoRouter router = ref.watch(routerProvider);
    // Prompt 8: push registration, taps and the critical-alert alarms.
    ref.watch(notificationCenterProvider);
    // Prompt 10: live location stops on sign-out or when the account is no
    // longer verified.
    ref.watch(trackerGuardProvider);
    // Prompt 12: a phone signed out from another phone signs out here too;
    // run confirmations made offline are sent once the connection is back.
    ref.watch(deviceGuardProvider);
    // Improvement B review (N1): nothing of a signed-out parent's chats or
    // pickup points stays in Firestore's cache on the phone.
    ref.watch(localCacheGuardProvider);
    ref.listen<List<PendingConfirm>>(confirmationQueueProvider, (List<PendingConfirm>? previous, List<PendingConfirm> next) {});

    return MaterialApp.router(
      onGenerateTitle: (BuildContext context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      locale: locale,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.light(direction, reduceMotion: _reduceMotion),
      darkTheme: AppTheme.dark(direction, reduceMotion: _reduceMotion),
      themeMode: themeMode,
      themeAnimationDuration: _reduceMotion ? Duration.zero : AppMotion.normal,
      // Prompt 12: the app lock (Face ID, fingerprint or passcode) covers everything.
      builder: (BuildContext context, Widget? child) =>
          FlavorBanner(flavor: config.flavor, child: AppLockGate(child: child ?? const SizedBox.shrink())),
    );
  }
}

/// Corner ribbon that shows DEV or STAGING so test builds are never mistaken
/// for the real app. Nothing is shown in prod.
class FlavorBanner extends StatelessWidget {
  const FlavorBanner({required this.flavor, required this.child, super.key});

  final Flavor flavor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (flavor == Flavor.prod) {
      return child;
    }
    return Banner(
      // A build label, not user-facing copy, so it is not translated.
      message: flavor.name.toUpperCase(),
      location: BannerLocation.topEnd,
      textDirection: TextDirection.ltr,
      layoutDirection: TextDirection.ltr,
      color: flavor == Flavor.dev ? context.colors.primary : context.colors.error,
      child: child,
    );
  }
}
