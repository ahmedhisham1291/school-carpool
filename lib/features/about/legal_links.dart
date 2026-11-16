import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// The public pages and the support address (App Review: a privacy policy
/// link in the app, guideline 5.1.1(i); published contact information,
/// guideline 1.2). The pages are built by tool/links_site.py and served by
/// the links site of the flavor's project.
///
/// Values come from `--dart-define` (never from the repository):
///   LEGAL_SITE_URL  for example `https://PROJECT-links.web.app`
///   SUPPORT_EMAIL   the address the owner reads
/// Empty or malformed values read as "not set": the About screen then shows
/// the documents inside the app and no contact row, never a broken link.
@immutable
class LegalLinks {
  const LegalLinks({required this.siteUrl, required this.supportEmail});

  factory LegalLinks.fromEnvironment() => const LegalLinks(
    siteUrl: String.fromEnvironment('LEGAL_SITE_URL'),
    supportEmail: String.fromEnvironment('SUPPORT_EMAIL'),
  );

  /// Nothing configured (tests, dev).
  static const LegalLinks none = LegalLinks(siteUrl: '', supportEmail: '');

  final String siteUrl;
  final String supportEmail;

  static final RegExp _email = RegExp(r'^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$');

  Uri? get _base {
    final Uri? uri = Uri.tryParse(siteUrl.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.hasQuery || uri.hasFragment) {
      return null;
    }
    return uri;
  }

  Uri? _page(String path) {
    final Uri? base = _base;
    return base == null ? null : Uri(scheme: 'https', host: base.host, path: '/$path');
  }

  Uri? get privacy => _page('privacy');
  Uri? get terms => _page('terms');
  Uri? get support => _page('support');
  Uri? get deleteAccount => _page('delete-account');

  /// R6: the emergency contact's confirm / stop page for [token].
  Uri? contactLink(String token) => RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ? _page('ec/$token') : null;

  /// The support address, or null when it is not set or not an address.
  String? get email => _email.hasMatch(supportEmail.trim()) ? supportEmail.trim() : null;

  Uri? get mail {
    final String? address = email;
    return address == null ? null : Uri(scheme: 'mailto', path: address);
  }
}

final Provider<LegalLinks> legalLinksProvider = Provider<LegalLinks>((Ref ref) => LegalLinks.fromEnvironment());

/// Opens a link outside the app (browser or Mail). Tests replace it.
typedef LinkOpener = Future<bool> Function(Uri uri);

final Provider<LinkOpener> linkOpenerProvider = Provider<LinkOpener>(
  (Ref ref) => (Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  },
);
