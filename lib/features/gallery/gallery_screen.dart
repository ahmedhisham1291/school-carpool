import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/shell/home_shell.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// Dev-only catalogue of every design-system component, with switches for
/// Arabic/English, light/dark and design direction A/B.
///
/// Token names in the color list are code identifiers, not user-facing text.
class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  static const double _stateViewHeight = AppSpacing.s64 * 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final DesignDirection direction = ref.watch(designDirectionProvider);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.galleryTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('gallery.toggleLanguage'),
            tooltip: l10n.settingsLanguage,
            icon: const Icon(Icons.language_rounded),
            onPressed: () => unawaited(ref.read(localeProvider.notifier).toggle()),
          ),
          IconButton(
            key: const Key('gallery.toggleTheme'),
            tooltip: l10n.settingsTheme,
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => unawaited(
              ref
                  .read(themeModeProvider.notifier)
                  .setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
            ),
          ),
          IconButton(
            key: const Key('gallery.toggleDirection'),
            tooltip: l10n.devDesignDirection,
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => unawaited(
              ref
                  .read(designDirectionProvider.notifier)
                  .setDirection(direction == DesignDirection.a ? DesignDirection.b : DesignDirection.a),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s48),
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: AppSpacing.screenGutter,
              end: AppSpacing.screenGutter,
              top: AppSpacing.s16,
            ),
            child: OneLineText(
              direction == DesignDirection.a ? l10n.directionA : l10n.directionB,
              style: context.text.headlineSmall,
            ),
          ),
          AppSectionHeader(l10n.gallerySectionColors),
          const _Padded(child: _ColorSwatches()),
          AppSectionHeader(l10n.gallerySectionTypography),
          const _Padded(child: _TypeSamples()),
          AppSectionHeader(l10n.gallerySectionButtons),
          const _Padded(child: _ButtonSamples()),
          AppSectionHeader(l10n.gallerySectionChips),
          const _Padded(child: _ChipSamples()),
          AppSectionHeader(l10n.gallerySectionInputs),
          const _Padded(child: _InputSamples()),
          AppSectionHeader(l10n.gallerySectionSignup),
          const _Padded(child: _SignupSamples()),
          AppSectionHeader(l10n.gallerySectionVerification),
          const _Padded(child: _VerificationSamples()),
          AppSectionHeader(l10n.gallerySectionCards),
          _Padded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                AppCard(child: _CardContent(title: l10n.sampleCardTitle, body: l10n.sampleCardBody)),
                const SizedBox(height: AppSpacing.s16),
                AppCard(
                  elevation: AppElevation.medium,
                  onTap: () => _done(context),
                  child: _CardContent(title: l10n.sampleCardTitle, body: l10n.sampleCardBody),
                ),
              ],
            ),
          ),
          AppSectionHeader(l10n.gallerySectionNavigation),
          const _NavigationSample(),
          AppSectionHeader(l10n.gallerySectionListRows),
          AppListRow(
            title: l10n.sampleListTitle,
            subtitle: l10n.sampleListSubtitle,
            leadingIcon: Icons.school_outlined,
            onTap: () => _done(context),
          ),
          AppListRow(title: l10n.sampleListTitle, subtitle: l10n.sampleListSubtitle),
          AppSectionHeader(l10n.gallerySectionSheets),
          const _Padded(child: _SheetSamples()),
          AppSectionHeader(l10n.gallerySectionSkeleton),
          const Skeleton(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Padded(child: SkeletonCard()),
                SkeletonListRow(),
                SkeletonListRow(),
              ],
            ),
          ),
          AppSectionHeader(l10n.gallerySectionStates),
          SizedBox(
            height: _stateViewHeight,
            child: EmptyStateView(
              actionLabel: l10n.sampleButtonPrimary,
              onAction: () => _done(context),
            ),
          ),
          const Divider(),
          SizedBox(height: _stateViewHeight, child: ErrorStateView(onRetry: () => _done(context))),
          const Divider(),
          SizedBox(height: _stateViewHeight, child: OfflineStateView(onRetry: () => _done(context))),
        ],
      ),
    );
  }
}

void _done(BuildContext context) => showAppSnackBar(context, context.l10n.sampleDone);

class _Padded extends StatelessWidget {
  const _Padded({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
    child: child,
  );
}

class _CardContent extends StatelessWidget {
  const _CardContent({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      OneLineText(title, style: context.text.titleMedium),
      const SizedBox(height: AppSpacing.s8),
      Text(body, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
    ],
  );
}

class _ColorSwatches extends StatelessWidget {
  const _ColorSwatches();

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    final ColorScheme c = context.colors;
    final AppColors s = context.appColors;
    final List<(String, Color, Color)> swatches = <(String, Color, Color)>[
      ('primary', c.primary, c.onPrimary),
      ('primaryContainer', c.primaryContainer, c.onPrimaryContainer),
      ('surface', c.surface, c.onSurface),
      ('surfaceRaised', s.surfaceRaised, c.onSurface),
      ('onSurfaceVariant', c.surfaceContainerHigh, c.onSurfaceVariant),
      ('outlineVariant', c.outlineVariant, c.onSurface),
      ('outline', c.outline, c.surface),
      ('error', c.error, c.onError),
      ('success', s.success, s.onSuccess),
      ('warning', s.warning, s.onWarning),
    ];
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: <Widget>[
        for (final (String name, Color background, Color foreground) in swatches)
          DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadii.control,
              border: Border.all(color: c.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    textDirection: TextDirection.ltr,
                    style: context.text.labelMedium?.copyWith(color: foreground),
                  ),
                  Text(
                    _hex(name == 'onSurfaceVariant' ? foreground : background),
                    textDirection: TextDirection.ltr,
                    style: context.text.labelSmall?.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ChipSamples extends StatefulWidget {
  const _ChipSamples();

  @override
  State<_ChipSamples> createState() => _ChipSamplesState();
}

class _ChipSamplesState extends State<_ChipSamples> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<String> labels = <String>[
      l10n.sampleChipMorning,
      l10n.sampleChipAfternoon,
      l10n.sampleChipBoth,
    ];
    return Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: <Widget>[
        for (int i = 0; i < labels.length; i++)
          AppChip(
            label: labels[i],
            selected: i == _selected,
            onSelected: (bool _) => setState(() => _selected = i),
          ),
        AppChip(label: l10n.sampleChipBoth, icon: Icons.block_rounded),
      ],
    );
  }
}

/// The real bottom bar with the five tabs, for checking the one-line labels
/// and the selected pill in every language and theme.
class _NavigationSample extends StatefulWidget {
  const _NavigationSample();

  @override
  State<_NavigationSample> createState() => _NavigationSampleState();
}

class _NavigationSampleState extends State<_NavigationSample> {
  int _index = 3;

  @override
  Widget build(BuildContext context) => AppNavigationBar(
    destinations: HomeShell.destinations(context.l10n),
    selectedIndex: _index,
    onDestinationSelected: (int index) => setState(() => _index = index),
  );
}

class _TypeSamples extends StatelessWidget {
  const _TypeSamples();

  @override
  Widget build(BuildContext context) {
    final TextTheme t = context.text;
    final String sample = context.l10n.sampleCardBody;
    final List<(String, TextStyle?)> styles = <(String, TextStyle?)>[
      ('headlineMedium', t.headlineMedium),
      ('titleLarge', t.titleLarge),
      ('titleMedium', t.titleMedium),
      ('bodyLarge', t.bodyLarge),
      ('bodyMedium (16)', t.bodyMedium),
      ('titleSmall', t.titleSmall),
      ('labelLarge', t.labelLarge),
      ('bodySmall (captions)', t.bodySmall),
      ('labelSmall (tabs)', t.labelSmall),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String name, TextStyle? style) in styles) ...<Widget>[
          Text(
            name,
            textDirection: TextDirection.ltr,
            style: t.labelSmall?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          Text(sample, style: style),
          const SizedBox(height: AppSpacing.s8),
        ],
      ],
    );
  }
}

class _ButtonSamples extends StatefulWidget {
  const _ButtonSamples();

  @override
  State<_ButtonSamples> createState() => _ButtonSamplesState();
}

class _ButtonSamplesState extends State<_ButtonSamples> {
  bool _loading = false;

  Future<void> _simulateSave() async {
    setState(() => _loading = true);
    await Future<void>.delayed(AppMotion.slow * 6);
    if (!mounted) {
      return;
    }
    setState(() => _loading = false);
    _done(context);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    const SizedBox gap = SizedBox(height: AppSpacing.s16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppButton(
          label: _loading ? l10n.sampleButtonLoading : l10n.sampleButtonPrimary,
          icon: Icons.add_rounded,
          loading: _loading,
          expand: true,
          onPressed: () => unawaited(_simulateSave()),
        ),
        gap,
        AppButton(
          label: l10n.sampleButtonSecondary,
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: () => _done(context),
        ),
        gap,
        AppButton(
          label: l10n.sampleButtonTertiary,
          variant: AppButtonVariant.tertiary,
          onPressed: () => _done(context),
        ),
        gap,
        AppButton(
          label: l10n.sampleButtonDanger,
          variant: AppButtonVariant.danger,
          expand: true,
          onPressed: () => unawaited(_confirmLeave(context)),
        ),
        gap,
        AppButton(
          label: l10n.sampleButtonPrimary,
          size: AppButtonSize.large,
          expand: true,
          onPressed: () => _done(context),
        ),
        gap,
        AppButton(label: l10n.sampleButtonPrimary, expand: true, onPressed: null),
      ],
    );
  }
}

Future<void> _confirmLeave(BuildContext context) async {
  final AppLocalizations l10n = context.l10n;
  final bool confirmed = await showConfirmDialog(
    context: context,
    title: l10n.sampleConfirmTitle,
    body: l10n.sampleConfirmBody,
    confirmLabel: l10n.sampleButtonDanger,
    destructive: true,
  );
  if (confirmed && context.mounted) {
    _done(context);
  }
}

class _InputSamples extends StatelessWidget {
  const _InputSamples();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          label: l10n.sampleFieldLabel,
          helperText: l10n.sampleFieldHelper,
          textInputAction: TextInputAction.next,
          validator: (String? value) =>
              (value ?? '').trim().length < 2 ? l10n.sampleFieldError : null,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          label: l10n.sampleFieldLabel,
          initialValue: l10n.sampleFieldShortValue,
          errorText: l10n.sampleFieldError,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(label: l10n.sampleFieldLabel, enabled: false),
      ],
    );
  }
}

class _SheetSamples extends StatelessWidget {
  const _SheetSamples();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppButton(
          label: l10n.sampleSheetOpen,
          variant: AppButtonVariant.secondary,
          onPressed: () => unawaited(
            showAppSheet<void>(
              context: context,
              title: l10n.sampleSheetTitle,
              body: Text(l10n.sampleSheetBody),
              primaryAction: Builder(
                builder: (BuildContext sheetContext) => AppButton(
                  label: l10n.actionConfirm,
                  expand: true,
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _done(context);
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          label: l10n.sampleConfirmOpen,
          variant: AppButtonVariant.secondary,
          onPressed: () => unawaited(_confirmLeave(context)),
        ),
      ],
    );
  }
}

/// Components added for sign-up (Prompt 2).
class _SignupSamples extends StatefulWidget {
  const _SignupSamples();

  /// Sample parent ID: a code, not translatable text.
  static const String sampleParentId = 'ABCD2345';

  @override
  State<_SignupSamples> createState() => _SignupSamplesState();
}

class _SignupSamplesState extends State<_SignupSamples> {
  final TextEditingController _code = TextEditingController();
  bool _accepted = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    const SizedBox gap = SizedBox(height: AppSpacing.s16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const AppStepProgress(current: 2, total: 4),
        gap,
        AppCodeField(
          label: l10n.codeLabel,
          controller: _code,
          helperText: l10n.codeHelper,
          onCompleted: (_) => _done(context),
        ),
        gap,
        AppCheckRow(
          label: l10n.termsAcceptTerms,
          value: _accepted,
          onChanged: (bool value) => setState(() => _accepted = value),
          actionLabel: l10n.termsRead,
          onAction: () => _done(context),
        ),
        AppCheckRow(
          label: l10n.termsWhatsApp,
          helperText: l10n.termsWhatsAppHelper,
          value: false,
          onChanged: null,
        ),
        gap,
        AppInlineMessage(message: l10n.emailSpamHint),
        gap,
        AppInlineMessage(message: l10n.errorExpiredCode, tone: AppStateTone.error),
        gap,
        AppInlineMessage(message: l10n.errorOffline, tone: AppStateTone.warning),
        gap,
        AppCard(
          child: AppCopyValue(
            label: l10n.profileParentIdLabel,
            value: _SignupSamples.sampleParentId,
            helperText: l10n.profileParentIdHelper,
          ),
        ),
        gap,
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            AppStatusBadge(label: l10n.statusUnverified, icon: Icons.shield_outlined),
            AppStatusBadge(
              label: l10n.statusPending,
              tone: AppBadgeTone.warning,
              icon: Icons.hourglass_top_rounded,
            ),
            AppStatusBadge(
              label: l10n.statusVerified,
              tone: AppBadgeTone.success,
              icon: Icons.verified_rounded,
            ),
            AppStatusBadge(
              label: l10n.statusRejected,
              tone: AppBadgeTone.error,
              icon: Icons.error_outline_rounded,
            ),
          ],
        ),
      ],
    );
  }
}

class _VerificationSamples extends StatefulWidget {
  const _VerificationSamples();

  /// A 1 by 1 pixel PNG standing in for a captured photo (no real images in the app).
  static final Uint8List samplePhoto = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOYc+IAAAQoAiWGhDpEAAAAAElFTkSuQmCC',
  );

  @override
  State<_VerificationSamples> createState() => _VerificationSamplesState();
}

class _VerificationSamplesState extends State<_VerificationSamples> {
  DateTime? _date;
  int? _seats;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final DateTime now = DateTime.now();
    const SizedBox gap = SizedBox(height: AppSpacing.s16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppCaptureTile(
          title: l10n.verifyIdFront,
          helperText: l10n.captureDocumentHint,
          icon: Icons.badge_outlined,
          actionLabel: l10n.captureTake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => _done(context),
        ),
        gap,
        AppCaptureTile(
          title: l10n.verifySelfieTile,
          icon: Icons.face_outlined,
          image: _VerificationSamples.samplePhoto,
          actionLabel: l10n.captureRetake,
          doneLabel: l10n.captureDone,
          todoLabel: l10n.captureTodo,
          onCapture: () => _done(context),
        ),
        gap,
        AppDateField(
          label: l10n.idExpiryLabel,
          helperText: l10n.idExpiryHelper,
          placeholder: l10n.dateChoose,
          value: _date,
          firstDate: now,
          lastDate: DateTime(now.year + 10, now.month, now.day),
          onChanged: (DateTime d) => setState(() => _date = d),
        ),
        gap,
        AppSelectField<int>(
          label: l10n.driverSeatsLabel,
          helperText: l10n.driverSeatsHelper,
          value: _seats,
          options: <(int, String)>[for (int n = 1; n <= 8; n++) (n, l10n.driverSeatsCount(n))],
          onChanged: (int v) => setState(() => _seats = v),
        ),
      ],
    );
  }
}
