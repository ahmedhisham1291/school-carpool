/// Versions of the documents the parent accepts at sign-up. They must match
/// CONSENT_VERSIONS in functions/src/auth/consents.ts: when the server has
/// a newer version, it refuses this build's acceptance and the app asks the
/// parent to update.
///
/// The texts (ARB keys termsTermsText, termsPrivacyText, termsConductText)
/// are drafts until the lawyer approves them.
abstract final class LegalDocuments {
  // Legal review (16 Nov 2026): free volunteer turns, Arabic text prevails.
  static const String terms = '2026-11-16';
  // Legal review (16 Nov 2026): 6 working days, contact, transfer abroad.
  // 16 Nov 2026: photos, messages, address and routes are deleted with the
  // account; usage statistics only with the parent's yes (DECISIONS.md).
  static const String privacy = '2026-11-16';
  // App Review audit (guideline 1.2): no tolerance for objectionable content.
  static const String conduct = '2026-11-16';

  /// Separate explicit consent to storage and processing outside Egypt
  /// (Law 151 of 2020, Arts. 14 to 16; docs/legal/egypt-legal-review.md).
  static const String transferAbroad = '2026-11-16';

  /// Sent to acceptConsents as `documents`.
  static const Map<String, String> required = <String, String>{
    'terms': terms,
    'privacy': privacy,
    'conduct': conduct,
    'transferAbroad': transferAbroad,
  };

  /// Consent to process ID, face and child data, given when documents are
  /// submitted (spec section 9, consent types ID, face, child data). Must
  /// match VERIFICATION_CONSENT_VERSIONS in
  /// functions/src/verification/submission.ts.
  // Legal review (16 Nov 2026): biometric wording, guardian declaration,
  // the child's whereabouts during runs.
  static const String verificationConsent = '2026-11-16';

  /// Sent to submitVerification as `consents`.
  static const Map<String, String> verification = <String, String>{
    'id': verificationConsent,
    'face': verificationConsent,
    'childData': verificationConsent,
  };
}
