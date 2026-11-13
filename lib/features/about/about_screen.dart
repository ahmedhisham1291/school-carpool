import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Where the OpenStreetMap licence and attribution are explained.
const String kOsmCopyrightUrl = 'https://www.openstreetmap.org/copyright';

/// About the app (Profile > About): what it is, and the credit the
/// OpenStreetMap licence (ODbL) requires for the schools list (F4, spec
/// section 7), plus the open-source licences of the app's packages.
///
/// Nothing is loaded here, so there is no loading, empty, error or offline
/// state; copying the link confirms with a snackbar.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<void> _copyLink(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String done = context.l10n.aboutLinkCopied;
    await Clipboard.setData(const ClipboardData(text: kOsmCopyrightUrl));
    showAppSnackBarOn(messenger, done);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
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
