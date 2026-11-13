/// Versions of the documents the parent accepts at sign-up. They must match
/// CONSENT_VERSIONS in functions/src/auth/consents.ts: when the server has
/// a newer version, it refuses this build's acceptance and the app asks the
/// parent to update.
///
/// The texts (ARB keys termsTermsText, termsPrivacyText, termsConductText)
/// are drafts until the lawyer approves them.
abstract final class LegalDocuments {
  static const String terms = '2026-11-13';
  static const String privacy = '2026-11-13';
  static const String conduct = '2026-11-13';

  /// Sent to acceptConsents as `documents`.
  static const Map<String, String> required = <String, String>{
    'terms': terms,
    'privacy': privacy,
    'conduct': conduct,
  };
}
