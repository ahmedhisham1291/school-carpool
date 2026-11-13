import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/firebase/firebase_setup.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/observability/sentry_setup.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Language and appearance settings, plus developer tools in the dev build.
class SettingsSection extends ConsumerWidget {
  const SettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final Locale locale = ref.watch(localeProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);
    final FlavorConfig config = ref.watch(flavorConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.settingsTitle),
        _LabeledControl(
          label: l10n.settingsLanguage,
          child: SegmentedButton<Locale>(
            key: const Key('settings.language'),
            showSelectedIcon: false,
            segments: <ButtonSegment<Locale>>[
              ButtonSegment<Locale>(value: AppLocales.arabic, label: Text(l10n.languageArabic)),
              ButtonSegment<Locale>(value: AppLocales.english, label: Text(l10n.languageEnglish)),
            ],
            selected: <Locale>{locale},
            onSelectionChanged: (Set<Locale> selection) =>
                unawaited(_setLanguage(ref, selection.first)),
          ),
        ),
        _LabeledControl(
          label: l10n.settingsTheme,
          child: SegmentedButton<ThemeMode>(
            key: const Key('settings.theme'),
            showSelectedIcon: false,
            segments: <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text(l10n.themeSystem)),
              ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text(l10n.themeLight)),
              ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text(l10n.themeDark)),
            ],
            selected: <ThemeMode>{themeMode},
            onSelectionChanged: (Set<ThemeMode> selection) =>
                unawaited(ref.read(themeModeProvider.notifier).setThemeMode(selection.first)),
          ),
        ),
        if (config.showDevTools) const _DevTools(),
      ],
    );
  }
}

/// Saves the language on the phone and, when signed in, on the account so
/// WhatsApp messages and emails use it. The server copy is best effort.
Future<void> _setLanguage(WidgetRef ref, Locale locale) async {
  final LocaleController controller = ref.read(localeProvider.notifier);
  final bool signedIn = ref.read(sessionProvider) is SessionSignedIn;
  final AuthRepository? repository = signedIn ? ref.read(authRepositoryProvider) : null;
  await controller.setLocale(locale);
  try {
    await repository?.updateLanguage(AppLocales.fromCode(locale.languageCode).languageCode);
  } on Object {
    // Offline or not allowed: the phone keeps the choice; the account keeps
    // the previous language until the next change.
  }
}

class _LabeledControl extends StatelessWidget {
  const _LabeledControl({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(label, style: context.text.labelLarge),
          const SizedBox(height: AppSpacing.s8),
          child,
        ],
      ),
    );
  }
}

/// Dev flavor only: design direction switch, gallery and test errors.
class _DevTools extends ConsumerWidget {
  const _DevTools();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final DesignDirection direction = ref.watch(designDirectionProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.devToolsTitle),
        _LabeledControl(
          label: l10n.devDesignDirection,
          child: SegmentedButton<DesignDirection>(
            key: const Key('settings.direction'),
            showSelectedIcon: false,
            segments: <ButtonSegment<DesignDirection>>[
              ButtonSegment<DesignDirection>(
                value: DesignDirection.a,
                label: Text(l10n.directionA),
              ),
              ButtonSegment<DesignDirection>(
                value: DesignDirection.b,
                label: Text(l10n.directionB),
              ),
            ],
            selected: <DesignDirection>{direction},
            onSelectionChanged: (Set<DesignDirection> selection) =>
                unawaited(ref.read(designDirectionProvider.notifier).setDirection(selection.first)),
          ),
        ),
        AppListRow(
          key: const Key('dev.gallery'),
          title: l10n.devOpenGallery,
          leadingIcon: Icons.widgets_outlined,
          onTap: () => unawaited(context.push<void>(AppRoutes.gallery)),
        ),
        AppListRow(
          key: const Key('dev.testError'),
          title: l10n.devSendTestError,
          leadingIcon: Icons.bug_report_outlined,
          onTap: () => unawaited(_sendAppTestError(context, ref)),
        ),
        AppListRow(
          key: const Key('dev.functionTestError'),
          title: l10n.devSendFunctionTestError,
          leadingIcon: Icons.cloud_off_outlined,
          onTap: () => unawaited(_sendFunctionTestError(context)),
        ),
      ],
    );
  }

  Future<void> _sendAppTestError(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sent = await sendTestError(ref.read(flavorConfigProvider));
    messenger.showSnackBar(
      SnackBar(content: Text(sent ? l10n.devTestErrorSent : l10n.devSentryOff)),
    );
  }

  Future<void> _sendFunctionTestError(BuildContext context) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String feedback = await _callFunctionTestError(l10n);
    messenger.showSnackBar(SnackBar(content: Text(feedback)));
  }

  /// Returns the message to show. The function throws on purpose, so a
  /// [FirebaseFunctionsException] is the expected outcome.
  Future<String> _callFunctionTestError(AppLocalizations l10n) async {
    try {
      await functionsClient().httpsCallable('debugTestError').call<void>();
      return l10n.devFunctionTestErrorDone;
    } on FirebaseFunctionsException {
      return l10n.devFunctionTestErrorDone;
    } on Exception {
      return l10n.stateErrorBody;
    }
  }
}
