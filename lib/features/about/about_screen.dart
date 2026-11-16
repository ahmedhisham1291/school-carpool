import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/about/legal_links.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Where the OpenStreetMap licence and attribution are explained.
const String kOsmCopyrightUrl = 'https://www.openstreetmap.org/copyright';

/// About the app (Profile > About): what it is, and the credit the
/// OpenStreetMap licence (ODbL) requires for the schools list (F4, spec
/// section 7), plus the open-source licences of the app's packages.
///
/// App Review (docs/apple-review/audit.md): the privacy policy, the terms
/// of use and the code of conduct are always readable here (guideline
/// 5.1.1(i)), with a link to the public page when the build has one, and
/// the support address (guideline 1.2, published contact information).
///
/// Nothing is loaded here, so there is no loading, empty, error or offline
/// state; copying a link confirms with a snackbar, and a link that cannot
/// open (no browser or Mail app) is copied instead.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  /// The document inside the app, with "Open the web page" when there is one.
  void _readDocument(BuildContext context, WidgetRef ref, String title, String text, Uri? page) {
    final AppLocalizations l10n = context.l10n;
    unawaited(
      showAppSheet<void>(
        context: context,
        title: title,
        body: Text(text),
        primaryAction: page == null
            ? null
            : AppButton(
                key: const Key('about.documentPage'),
                label: l10n.aboutOpenWebPage,
                icon: Icons.open_in_new_rounded,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => unawaited(_open(context, ref, page, page.toString())),
              ),
      ),
    );
  }

  /// Opens [uri] outside the app; when nothing can open it, copies [copyText].
  Future<void> _open(BuildContext context, WidgetRef ref, Uri uri, String copyText) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String copied = context.l10n.aboutLinkCopied;
    final bool opened = await ref.read(linkOpenerProvider)(uri);
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: copyText));
      showAppSnackBarOn(messenger, copied);
    }
  }

  Future<void> _copyLink(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String done = context.l10n.aboutLinkCopied;
    await Clipboard.setData(const ClipboardData(text: kOsmCopyrightUrl));
    showAppSnackBarOn(messenger, done);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final LegalLinks links = ref.watch(legalLinksProvider);
    final String? supportEmail = links.email;
    final Uri? supportMail = links.mail;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          Padding(
            padding: AppSpacing.screenPadding,
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  OneLineText(l10n.appTitle, style: context.text.titleMedium),
                  const SizedBox(height: AppSpacing.s8),
                  Text(l10n.aboutBody, style: context.text.bodyMedium),
                ],
              ),
            ),
          ),
          AppSectionHeader(l10n.aboutLegalSection),
          AppListRow(
            key: const Key('about.privacy'),
            title: l10n.termsDocPrivacy,
            leadingIcon: Icons.privacy_tip_outlined,
            onTap: () => _readDocument(context, ref, l10n.termsDocPrivacy, l10n.termsPrivacyText, links.privacy),
          ),
          AppListRow(
            key: const Key('about.terms'),
            title: l10n.termsDocTerms,
            leadingIcon: Icons.gavel_rounded,
            onTap: () => _readDocument(context, ref, l10n.termsDocTerms, l10n.termsTermsText, links.terms),
          ),
          AppListRow(
            key: const Key('about.conduct'),
            title: l10n.termsDocConduct,
            leadingIcon: Icons.handshake_outlined,
            onTap: () => _readDocument(context, ref, l10n.termsDocConduct, l10n.termsConductText, links.terms),
          ),
          if (supportEmail != null && supportMail != null)
            AppListRow(
              key: const Key('about.support'),
              title: l10n.aboutSupport,
              subtitle: ltrIsolate(supportEmail),
              leadingIcon: Icons.mail_outline_rounded,
              showChevron: false,
              onTap: () => unawaited(_open(context, ref, supportMail, supportEmail)),
            ),
          AppSectionHeader(l10n.aboutDataSection),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Text(
              l10n.aboutOsmCredit,
              key: const Key('about.osmCredit'),
              style: context.text.bodyMedium,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          AppListRow(
            key: const Key('about.osmLink'),
            title: l10n.aboutOsmLinkTitle,
            subtitle: ltrIsolate('openstreetmap.org/copyright'),
            leadingIcon: Icons.link_rounded,
            trailing: const Icon(Icons.copy_rounded),
            showChevron: false,
            onTap: () => unawaited(_copyLink(context)),
          ),
          AppSectionHeader(l10n.aboutSoftwareSection),
          AppListRow(
            key: const Key('about.licenses'),
            title: l10n.aboutLicenses,
            leadingIcon: Icons.description_outlined,
            onTap: () => showLicensePage(context: context, applicationName: l10n.appTitle),
          ),
        ],
      ),
    );
  }
}
