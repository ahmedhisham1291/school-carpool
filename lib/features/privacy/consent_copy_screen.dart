import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/privacy/privacy_labels.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/features/privacy/privacy_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _consentCopyProvider = FutureProvider.autoDispose.family<ConsentCopy?, ConsentKind>(
  (Ref ref, ConsentKind kind) => ref.watch(privacyRepositoryProvider).consentCopy(kind),
);

/// Privacy > a signed consent > View copy (R3, docs/legal/answers.md 1.4:
/// "a copy the parent can open"). Layout: the consent's one-line title in
/// the app bar; a card with the exact text of the version signed; then
/// Signed by (the typed name), Date and time, Confirmed with (Face ID or
/// passcode, or a fresh sign-in), Version, App version and the Text
/// fingerprint; one primary action "Download copy" (a text file, link
/// valid 1 hour).
///
/// States: loading (skeleton lines), empty (given before signed copies:
/// "No copy yet"), error and offline (retry).
class ConsentCopyScreen extends ConsumerWidget {
  const ConsentCopyScreen({required this.kind, super.key});

  final ConsentKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void reload() => ref.invalidate(_consentCopyProvider(kind));
    final Widget body = switch (ref.watch(_consentCopyProvider(kind))) {
      AsyncData<ConsentCopy?>(value: final ConsentCopy copy) => _CopyContent(copy: copy),
      AsyncData<ConsentCopy?>() => EmptyStateView(
        key: const Key('consentCopy.empty'),
        icon: Icons.description_outlined,
        title: l10n.consentCopyEmptyTitle,
        body: l10n.consentCopyEmptyBody,
      ),
      AsyncError<ConsentCopy?>(:final Object error) => privacyErrorView(context, PrivacyFailure.from(error), reload),
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonCard(), SkeletonListRow(), SkeletonListRow(), SkeletonListRow()])),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(consentTitle(l10n, kind))),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _CopyContent extends ConsumerStatefulWidget {
  const _CopyContent({required this.copy});

  final ConsentCopy copy;

  @override
  ConsumerState<_CopyContent> createState() => _CopyContentState();
}

class _CopyContentState extends ConsumerState<_CopyContent> {
  bool _busy = false;

  Future<void> _download() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final ExportLink link = await ref.read(privacyRepositoryProvider).downloadConsentCopy(widget.copy.kind);
      final bool opened = await ref.read(linkOpenerProvider)(Uri.parse(link.url));
      showAppSnackBarOn(messenger, opened ? l10n.consentCopyReady : l10n.consentCopyNotOpened);
    } on PrivacyFailure catch (f) {
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
    final ConsentCopy c = widget.copy;
    final TextStyle? label = context.text.labelLarge?.copyWith(color: context.colors.onSurfaceVariant);
    Widget fact(String key, String name, String value) => Padding(
      key: Key('consentCopy.$key'),
      padding: const EdgeInsets.only(bottom: AppSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OneLineText(name, style: label),
          const SizedBox(height: AppSpacing.s4),
          Text(value, style: context.text.bodyLarge),
        ],
      ),
    );
    // A short page: built at once (not lazily), so every fact and the
    // download button exist for screen readers and tests.
    return SingleChildScrollView(
      key: const Key('consentCopy.list'),
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppCard(child: SelectableText(c.text, key: const Key('consentCopy.text'), style: context.text.bodyLarge)),
          const SizedBox(height: AppSpacing.s24),
          fact('signedBy', l10n.consentCopySignedBy, c.signedName ?? '-'),
          fact('date', l10n.consentCopyDate, shortDateTime(context, c.acceptedAt)),
          fact('method', l10n.consentCopyMethod, c.method == SignedWith.deviceAuth ? l10n.consentCopyMethodDevice : l10n.consentCopyMethodSignIn),
          fact('version', l10n.consentCopyVersion, c.version),
          fact('app', l10n.consentCopyApp, '${c.appVersion} (${c.platform})'),
          fact('fingerprint', l10n.consentCopyFingerprint, c.fingerprint),
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('consentCopy.download'),
            label: l10n.consentCopyDownload,
            icon: Icons.download_rounded,
            expand: true,
            loading: _busy,
            onPressed: _busy ? null : () => unawaited(_download()),
          ),
        ],
      ),
    );
  }
}
