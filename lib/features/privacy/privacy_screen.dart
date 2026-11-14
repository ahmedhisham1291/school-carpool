import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/privacy/privacy_labels.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';
import 'package:school_carpool/settings/settings_store.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a link outside the app (the export file). Tests replace it.
typedef LinkOpener = Future<bool> Function(Uri uri);

final Provider<LinkOpener> linkOpenerProvider = Provider<LinkOpener>(
  (Ref ref) => (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Privacy (spec section 7, Prompt 12). Layout, top to bottom:
/// - one sentence and the primary action "Download my data" (a JSON file
///   with every data type, including chat and the wallet history; the link
///   works 1 hour);
/// - "Your data": every data type with how long it is kept; tap for what it
///   holds and who sees it;
/// - "Your choices": every consent; usage statistics, the map and WhatsApp
///   are switches, the others can be withdrawn (some only by deleting the
///   account, which the answer says);
/// - "Correct your data": the screens where the parent edits it, and a
///   request for ID details (an admin checks them) or a copy of the photos;
/// - "Phones and sign-ins", "Your requests" (every request is logged), and
///   "Delete account".
///
/// States: loading (skeleton), error and offline (retry). Never empty (the
/// data types are always listed).
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void reload() => ref.invalidate(privacyOverviewProvider);
    final Widget body = switch (ref.watch(privacyOverviewProvider)) {
      AsyncData<PrivacyOverview>(:final PrivacyOverview value) => _PrivacyContent(overview: value, onChanged: reload),
      AsyncError<PrivacyOverview>(:final Object error) => privacyErrorView(context, PrivacyFailure.from(error), reload),
      _ => const Skeleton(
        child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow(), SkeletonListRow()]),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.privacyTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _PrivacyContent extends ConsumerStatefulWidget {
  const _PrivacyContent({required this.overview, required this.onChanged});

  final PrivacyOverview overview;
  final VoidCallback onChanged;

  @override
  ConsumerState<_PrivacyContent> createState() => _PrivacyContentState();
}

class _PrivacyContentState extends ConsumerState<_PrivacyContent> {
  bool _exporting = false;

  Future<void> _export() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final ExportLink link = await ref.read(privacyRepositoryProvider).exportData();
      ref.read(analyticsProvider).track(AnalyticsEvent.privacyExport, <String, Object?>{'result': 'done'});
      final bool opened = await ref.read(linkOpenerProvider)(Uri.parse(link.url));
      showAppSnackBarOn(messenger, opened ? l10n.privacyExportReady : l10n.privacyExportNotOpened);
      widget.onChanged();
    } on PrivacyFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> _showType(DataType t) async {
    final AppLocalizations l10n = context.l10n;
    await showAppSheet<void>(
      context: context,
      title: dataTypeTitle(l10n, t),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(dataTypeBody(l10n, t), style: context.text.bodyLarge),
          const SizedBox(height: AppSpacing.s16),
          AppListRow(
            inset: false,
            showChevron: false,
            leadingIcon: Icons.schedule_rounded,
            title: l10n.privacyKeptTitle,
            subtitle: keepLabel(l10n, keepOf(t)),
          ),
        ],
      ),
    );
  }

  Future<void> _setConsent(ConsentView c, bool granted) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (!granted && !c.kind.switchable) {
      final bool ok = await showConfirmDialog(
        context: context,
        title: l10n.privacyWithdrawTitle(consentTitle(l10n, c.kind)),
        body: l10n.privacyWithdrawBody,
        confirmLabel: l10n.privacyWithdraw,
        destructive: true,
      );
      if (!ok || !mounted) {
        return;
      }
    }
    try {
      final WithdrawEffect effect = await ref.read(privacyRepositoryProvider).setConsent(c.kind, granted: granted);
      if (c.kind == ConsentKind.analytics) {
        await saveAnalyticsChoice(ref.read(settingsStoreProvider), ref.read(analyticsProvider), enabled: granted);
      }
      ref.read(analyticsProvider).track(AnalyticsEvent.consentChanged, <String, Object?>{'kind': _wire(c.kind), 'granted': granted});
      showAppSnackBarOn(messenger, switch (effect) {
        WithdrawEffect.needsDeletion => l10n.privacyNeedsDeletion,
        WithdrawEffect.needsChildRemoval => l10n.privacyNeedsChildRemoval,
        WithdrawEffect.granted => l10n.privacyConsentGiven,
        _ => l10n.privacyConsentWithdrawn,
      });
      widget.onChanged();
    } on PrivacyFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  /// Analytics carries fixed lowercase words only.
  static String _wire(ConsentKind k) => switch (k) {
    ConsentKind.childData => 'child-data',
    ConsentKind.walletTerms => 'wallet-terms',
    ConsentKind.showOnMap => 'show-on-map',
    _ => k.name,
  };

  Future<void> _request(Future<void> Function(PrivacyRepository repo) action, String done) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action(ref.read(privacyRepositoryProvider));
      showAppSnackBarOn(messenger, done);
      widget.onChanged();
    } on PrivacyFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final PrivacyOverview o = widget.overview;
    return ListView(
      key: const Key('privacy.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.privacyIntro, style: quiet),
              const SizedBox(height: AppSpacing.s16),
              AppButton(
                key: const Key('privacy.export'),
                label: l10n.privacyExport,
                icon: Icons.download_rounded,
                expand: true,
                loading: _exporting,
                onPressed: _exporting ? null : () => unawaited(_export()),
              ),
              const SizedBox(height: AppSpacing.s8),
              Text(l10n.privacyExportHelper, style: quiet),
            ],
          ),
        ),
        AppSectionHeader(l10n.privacyDataSection),
        for (final DataType t in DataType.values)
          AppListRow(
            key: Key('privacy.data.${t.name}'),
            title: dataTypeTitle(l10n, t),
            subtitle: keepLabel(l10n, keepOf(t)),
            onTap: () => unawaited(_showType(t)),
          ),
        AppSectionHeader(l10n.privacyChoicesSection),
        for (final ConsentView c in o.consents)
          if (c.kind.switchable)
            AppSwitchRow(
              key: Key('privacy.consent.${c.kind.name}'),
              title: consentTitle(l10n, c.kind),
              value: c.active,
              onChanged: (bool v) => unawaited(_setConsent(c, v)),
            )
          else
            AppListRow(
              key: Key('privacy.consent.${c.kind.name}'),
              title: consentTitle(l10n, c.kind),
              subtitle: c.active
                  ? l10n.privacyConsentGivenOn(c.acceptedAt == null ? '' : shortDate(context, c.acceptedAt!))
                  : l10n.privacyConsentNotGiven,
              showChevron: c.active,
              onTap: c.active ? () => unawaited(_setConsent(c, false)) : null,
            ),
        AppSectionHeader(l10n.privacyCorrectSection),
        AppListRow(
          key: const Key('privacy.correct.children'),
          title: l10n.childrenTitle,
          leadingIcon: Icons.child_care_outlined,
          onTap: () => context.go(ProfileRoutes.children),
        ),
        AppListRow(
          key: const Key('privacy.correct.home'),
          title: l10n.homeLocationTitle,
          leadingIcon: Icons.home_work_outlined,
          onTap: () => context.go(ProfileRoutes.homeLocation),
        ),
        AppListRow(
          key: const Key('privacy.correct.driving'),
          title: l10n.drivingTitle,
          leadingIcon: Icons.directions_car_outlined,
          onTap: () => context.go(ProfileRoutes.driving),
        ),
        AppListRow(
          key: const Key('privacy.correct.id'),
          title: l10n.privacyCorrectId,
          subtitle: l10n.privacyCorrectIdHelper,
          leadingIcon: Icons.badge_outlined,
          onTap: () => unawaited(_request((PrivacyRepository r) => r.requestCorrection(CorrectionField.name), l10n.privacyRequestSent)),
        ),
        AppListRow(
          key: const Key('privacy.photoCopy'),
          title: l10n.privacyPhotoCopy,
          subtitle: l10n.privacyPhotoCopyHelper,
          leadingIcon: Icons.photo_library_outlined,
          onTap: () => unawaited(_request((PrivacyRepository r) => r.requestPhotoCopy(), l10n.privacyRequestSent)),
        ),
        AppSectionHeader(l10n.privacySecuritySection),
        AppListRow(
          key: const Key('privacy.devices'),
          title: l10n.devicesTitle,
          subtitle: l10n.devicesHelper,
          leadingIcon: Icons.devices_other_outlined,
          onTap: () => context.go(PrivacyRoutes.devices),
        ),
        if (o.requests.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.privacyRequestsSection),
          for (final PrivacyRequest r in o.requests.take(10)) _RequestRow(request: r),
        ],
        AppSectionHeader(l10n.privacyDeleteSection),
        AppListRow(
          key: const Key('privacy.delete'),
          title: l10n.deleteAccountTitle,
          subtitle: l10n.deleteAccountHelper,
          leadingIcon: Icons.delete_forever_outlined,
          onTap: () => context.go(PrivacyRoutes.delete),
        ),
      ],
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({required this.request});

  final PrivacyRequest request;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String label, AppBadgeTone tone) = requestStatus(l10n, request.status);
    return AppListRow(
      title: requestTitle(l10n, request),
      subtitle: '${shortDate(context, request.createdAt)} · $label',
      leadingIcon: switch (request.status) {
        RequestStatus.done => Icons.check_circle_outline_rounded,
        RequestStatus.open => Icons.hourglass_empty_rounded,
        RequestStatus.refused || RequestStatus.failed => Icons.info_outline_rounded,
      },
      showChevron: false,
      trailing: tone == AppBadgeTone.error ? Icon(Icons.error_outline_rounded, color: context.colors.error, size: AppIconSize.sm) : null,
    );
  }
}
