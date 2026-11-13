import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/session_redirect.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Sign-up screen 1 (spec section 10): what the app is, language choice,
/// and the way in. New and returning parents both continue with their
/// number. Nothing loads here, so there is no loading, empty or offline
/// state; the next step handles the connection.
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final Locale locale = ref.watch(localeProvider);
    final ColorScheme colors = context.colors;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.screenPadding,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const SizedBox(height: AppSpacing.s48),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: SizedBox.square(
                            dimension: AppSpacing.s64,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: AppRadii.card,
                              ),
                              child: Icon(
                                Icons.directions_car_rounded,
                                color: colors.onPrimaryContainer,
                                size: AppSpacing.s32,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.s24),
                        Text(
                          l10n.appTitle,
                          style: context.text.titleMedium?.copyWith(color: colors.primary),
                        ),
                        const SizedBox(height: AppSpacing.s8),
                        Semantics(
                          header: true,
                          child: Text(l10n.welcomeTitle, style: context.text.headlineLarge),
                        ),
                        const SizedBox(height: AppSpacing.s16),
                        Text(
                          l10n.welcomeBody,
                          style: context.text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpacing.s32),
                        Text(l10n.settingsLanguage, style: context.text.labelLarge),
                        const SizedBox(height: AppSpacing.s8),
                        SegmentedButton<Locale>(
                          key: const Key('welcome.language'),
                          showSelectedIcon: false,
                          segments: <ButtonSegment<Locale>>[
                            ButtonSegment<Locale>(
                              value: AppLocales.arabic,
                              label: Text(l10n.languageArabic),
                            ),
                            ButtonSegment<Locale>(
                              value: AppLocales.english,
                              label: Text(l10n.languageEnglish),
                            ),
                          ],
                          selected: <Locale>{locale},
                          onSelectionChanged: (Set<Locale> selection) => unawaited(
                            ref.read(localeProvider.notifier).setLocale(selection.first),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppSpacing.maxContentWidth),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    AppButton(
                      key: const Key('welcome.start'),
                      label: l10n.welcomeStart,
                      expand: true,
                      onPressed: () => unawaited(context.push<void>(AuthRoutes.phone)),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    Text(
                      l10n.welcomeSignInHint,
                      textAlign: TextAlign.center,
                      style: context.text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
