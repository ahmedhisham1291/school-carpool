import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_features.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/feature_switches/feature_switches.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// No automatic retry (Riverpod 3): the page shows its own Retry.
Duration? _noRetry(int retryCount, Object error) => null;

final _featuresProvider = FutureProvider.autoDispose<FeatureSwitches>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminFeaturesApiProvider).features(),
);

final _wordFilterProvider = FutureProvider.autoDispose<ChatWordFilter>(
  retry: _noRetry,
  (Ref ref) => ref.watch(adminFeaturesApiProvider).chatWordFilter(),
);

String adminFeatureTitle(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWallet,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatings,
  AppFeature.yearlyChecks => l10n.adminFeatureYearly,
  AppFeature.settleUp => l10n.adminFeatureSettle,
};

String adminFeatureHelper(AppLocalizations l10n, AppFeature f) => switch (f) {
  AppFeature.wallet => l10n.adminFeatureWalletHelper,
  AppFeature.ratingsAndVouching => l10n.adminFeatureRatingsHelper,
  AppFeature.yearlyChecks => l10n.adminFeatureYearlyHelper,
  AppFeature.settleUp => l10n.adminFeatureSettleHelper,
};

/// Settings (pilot feature switches): one switch per optional feature
/// (wallet, ratings and vouching, yearly checks, Settle up). A super admin
/// changes one after a confirmation; the server writes the audit log.
/// Other admins see the switches but cannot change them. A change reaches
/// the apps at once (no release) and the functions within half a minute.
///
/// Sign-in, verification, carpools, schedule, trips and alerts and chat
/// have no switch.
///
/// Below the switches: the chat word filter (App Review guideline 1.2),
/// Arabic and English lists a super admin edits; the server removes a
/// chat message with one of them when it is sent.
///
/// States: loading (skeleton), error and offline (retry); the word filter
/// row has its own loading row and inline error with Retry.
class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  bool _busy = false;

  Future<void> _set(AppFeature feature, bool on) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String name = adminFeatureTitle(l10n, feature);
    final bool ok = await showConfirmDialog(
      context: context,
      title: on ? l10n.adminFeatureOnTitle : l10n.adminFeatureOffTitle,
      body: on ? l10n.adminFeatureOnBody(name) : l10n.adminFeatureOffBody(name),
      confirmLabel: on ? l10n.adminFeatureTurnOn : l10n.adminFeatureTurnOff,
      destructive: !on,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(adminFeaturesApiProvider).setFeature(feature, on: on);
      showAppSnackBarOn(messenger, l10n.adminSaved);
      ref.invalidate(_featuresProvider);
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final bool superAdmin = adminUserOf(ref.watch(adminSessionProvider))?.isSuperAdmin ?? false;
    void refresh() {
      ref
        ..invalidate(_featuresProvider)
        ..invalidate(_wordFilterProvider);
    }
    return AdminPage(
      title: l10n.adminSettingsTitle,
      actions: <Widget>[IconButton(tooltip: l10n.adminRefresh, icon: const Icon(Icons.refresh), onPressed: refresh)],
      body: AdminAsyncView<FeatureSwitches>(
        value: ref.watch(_featuresProvider),
        onRetry: refresh,
        builder: (FeatureSwitches features) => ListView(
          key: const Key('adminSettings.list'),
          padding: AppSpacing.screenPadding,
          children: <Widget>[
            AppInlineMessage(
              key: const Key('adminSettings.intro'),
              message: superAdmin ? l10n.adminSettingsIntro : l10n.adminSettingsReadOnly,
            ),
            AppSectionHeader(l10n.adminSettingsFeatures),
            for (final AppFeature f in AppFeature.values)
              AppSwitchRow(
                key: Key('adminSettings.${f.name}'),
                title: adminFeatureTitle(l10n, f),
                subtitle: adminFeatureHelper(l10n, f),
                value: features.isOn(f),
                // Only a super admin changes a switch (the server checks too).
                onChanged: superAdmin && !_busy ? (bool on) => unawaited(_set(f, on)) : null,
              ),
            const SizedBox(height: AppSpacing.s16),
            Text(l10n.adminSettingsCore, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
            AppSectionHeader(l10n.adminWordFilterTitle),
            _WordFilterRow(superAdmin: superAdmin),
          ],
        ),
      ),
    );
  }
}

/// The chat word filter: counts per language, Edit for a super admin.
class _WordFilterRow extends ConsumerWidget {
  const _WordFilterRow({required this.superAdmin});

  final bool superAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<ChatWordFilter> value = ref.watch(_wordFilterProvider);
    return switch (value) {
      AsyncData<ChatWordFilter>(:final ChatWordFilter value) => AppListRow(
        key: const Key('adminSettings.wordFilter'),
        title: value.usingDefaults ? l10n.adminWordFilterDefaults : l10n.adminWordFilterCounts(value.arabic.length, value.english.length),
        subtitle: superAdmin ? l10n.adminWordFilterHelper : l10n.adminWordFilterReadOnly,
        leadingIcon: Icons.filter_alt_outlined,
        showChevron: false,
        trailing: superAdmin
            ? TextButton(
                key: const Key('adminSettings.wordFilter.edit'),
                onPressed: () => unawaited(_edit(context, ref, value)),
                child: OneLineText(l10n.adminWordFilterEdit),
              )
            : null,
      ),
      AsyncError<ChatWordFilter>(:final Object error) => Column(
        key: const Key('adminSettings.wordFilter.error'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppInlineMessage(message: AdminFailure.from(error).message(l10n), tone: AppStateTone.warning),
          TextButton(onPressed: () => ref.invalidate(_wordFilterProvider), child: OneLineText(l10n.actionRetry)),
        ],
      ),
      _ => const Skeleton(child: SkeletonListRow()),
    };
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, ChatWordFilter current) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final _WordFilterChoice? choice = await showDialog<_WordFilterChoice>(
      context: context,
      builder: (BuildContext context) => _WordFilterDialog(current: current),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    if (choice.reset) {
      final bool ok = await showConfirmDialog(
        context: context,
        title: l10n.adminWordFilterResetTitle,
        body: l10n.adminWordFilterResetBody,
        confirmLabel: l10n.adminWordFilterReset,
      );
      if (!ok) {
        return;
      }
    }
    try {
      final AdminFeaturesApi api = ref.read(adminFeaturesApiProvider);
      await (choice.reset ? api.setChatWordFilter(reset: true) : api.setChatWordFilter(arabic: choice.arabic, english: choice.english));
      showAppSnackBarOn(messenger, l10n.adminSaved);
      ref.invalidate(_wordFilterProvider);
    } on AdminFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }
}

class _WordFilterChoice {
  const _WordFilterChoice({this.arabic = const <String>[], this.english = const <String>[], this.reset = false});

  final List<String> arabic;
  final List<String> english;
  final bool reset;
}

/// Two lists, one word or phrase per line; checked as the admin types.
class _WordFilterDialog extends StatefulWidget {
  const _WordFilterDialog({required this.current});

  final ChatWordFilter current;

  @override
  State<_WordFilterDialog> createState() => _WordFilterDialogState();
}

class _WordFilterDialogState extends State<_WordFilterDialog> {
  late final TextEditingController _arabic = TextEditingController(text: widget.current.arabic.join('\n'));
  late final TextEditingController _english = TextEditingController(text: widget.current.english.join('\n'));

  @override
  void dispose() {
    _arabic.dispose();
    _english.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<String> arabic = ChatWordFilter.parseLines(_arabic.text);
    final List<String> english = ChatWordFilter.parseLines(_english.text);
    final bool fits = widget.current.fits(arabic, english);
    return AlertDialog(
      key: const Key('adminSettings.wordFilter.dialog'),
      title: OneLineText(l10n.adminWordFilterTitle),
      content: SizedBox(
        width: AppSpacing.maxContentWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.adminWordFilterHelper, style: context.text.bodyMedium),
              const SizedBox(height: AppSpacing.s16),
              TextField(
                key: const Key('adminSettings.wordFilter.arabic'),
                controller: _arabic,
                textDirection: TextDirection.rtl,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(labelText: l10n.adminWordFilterArabic),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.s16),
              TextField(
                key: const Key('adminSettings.wordFilter.english'),
                controller: _english,
                textDirection: TextDirection.ltr,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: l10n.adminWordFilterEnglish,
                  errorText: fits ? null : l10n.adminWordFilterInvalid(widget.current.maxTerms, widget.current.maxLength),
                  errorMaxLines: 3,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('adminSettings.wordFilter.reset'),
          onPressed: () => Navigator.of(context).pop(const _WordFilterChoice(reset: true)),
          child: OneLineText(l10n.adminWordFilterReset),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: OneLineText(l10n.actionCancel)),
        FilledButton(
          key: const Key('adminSettings.wordFilter.save'),
          onPressed: fits ? () => Navigator.of(context).pop(_WordFilterChoice(arabic: arabic, english: english)) : null,
          child: OneLineText(l10n.actionSave),
        ),
      ],
    );
  }
}
