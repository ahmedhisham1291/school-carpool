import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/router/admin_router.dart';
import 'package:school_carpool/app.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Root of the admin web panel (F14): same design system, languages and
/// settings as the app, its own router. Arabic and right-to-left by default.
class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FlavorConfig config = ref.watch(flavorConfigProvider);
    final bool reduceMotion = AppMotion.platformReducesMotion();
    return MaterialApp.router(
      onGenerateTitle: (BuildContext context) => context.l10n.adminPanelTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(adminRouterProvider),
      locale: ref.watch(localeProvider),
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.light(DesignDirection.a, reduceMotion: reduceMotion),
      darkTheme: AppTheme.dark(DesignDirection.a, reduceMotion: reduceMotion),
      themeMode: ref.watch(themeModeProvider),
      themeAnimationDuration: reduceMotion ? Duration.zero : AppMotion.normal,
      builder: (BuildContext context, Widget? child) =>
          FlavorBanner(flavor: config.flavor, child: child ?? const SizedBox.shrink()),
    );
  }
}
