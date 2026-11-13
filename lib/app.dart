import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Root widget. Language, theme mode and (dev only) design direction come
/// from persisted settings; Arabic and right-to-left are the default.
class CarpoolApp extends ConsumerWidget {
  const CarpoolApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FlavorConfig config = ref.watch(flavorConfigProvider);
    final Locale locale = ref.watch(localeProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    // Staging and prod always use the default direction until the owner picks.
    final DesignDirection direction = config.showDevTools
        ? ref.watch(designDirectionProvider)
        : DesignDirection.a;
    final GoRouter router = ref.watch(routerProvider);

    return MaterialApp.router(
      onGenerateTitle: (BuildContext context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      locale: locale,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.light(direction),
      darkTheme: AppTheme.dark(direction),
      themeMode: themeMode,
      themeAnimationDuration: AppMotion.normal,
      builder: (BuildContext context, Widget? child) =>
          FlavorBanner(flavor: config.flavor, child: child ?? const SizedBox.shrink()),
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
