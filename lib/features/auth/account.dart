import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:school_carpool/features/verification/verification_models.dart';

/// Verification states from spec section 3. Only Cloud Functions change
/// them; firestore.rules stops the app from writing the field.
enum AccountStatus {
  unverified,
  pending,
  verified,
  rejected,
  suspended;

  /// Unknown values count as unverified (Profile-only access).
  static AccountStatus fromName(Object? name) =>
      values.firstWhere((AccountStatus s) => s.name == name, orElse: () => AccountStatus.unverified);
}

/// Where a signed-in parent is in sign-up (spec section 3, steps 1 and 2,
/// then the terms).
enum RegistrationStage { email, terms, complete }

/// The parent's own record, users/{uid}, written by Cloud Functions.
@immutable
class Account {
  const Account({
    required this.parentId,
    required this.status,
    required this.phone,
    required this.email,
    required this.emailVerified,
    required this.termsAccepted,
    required this.language,
    this.firstName,
    this.verification,
    this.claimsUpdatedAtMs,
    this.whatsappOptIn = false,
  });

  factory Account.fromMap(Map<String, dynamic> data) => Account(
    parentId: data['parentId'] as String? ?? '',
    status: AccountStatus.fromName(data['status']),
    phone: data['phone'] as String? ?? '',
    email: data['email'] as String?,
    emailVerified: data['emailVerified'] as bool? ?? false,
    termsAccepted: data['termsAcceptedAt'] != null,
    language: data['language'] as String? ?? 'ar',
    firstName: data['firstName'] as String?,
    verification: VerificationSummary.fromMap(data['verification']),
    claimsUpdatedAtMs: switch (data['claimsUpdatedAt']) {
      final Timestamp t => t.toDate().millisecondsSinceEpoch,
      _ => null,
    },
    whatsappOptIn: data['whatsappOptIn'] == true,
  );

  /// Public 8-character parent ID (F44).
  final String parentId;
  final AccountStatus status;

  /// E.164 phone number. Shown to the owner only; never logged.
  final String phone;
  final String? email;
  final bool emailVerified;
  final bool termsAccepted;
  final String language;

  /// Set from the ID details once documents are submitted (Prompt 3).
  final String? firstName;

  /// The latest submission for review, or null before the first one.
  final VerificationSummary? verification;

  /// Set by Cloud Functions right after they change this account's custom
  /// claims ("verified"). The app refreshes its ID token when it changes.
  final int? claimsUpdatedAtMs;

  /// The parent agreed to WhatsApp messages (at sign-up or later in Alert
  /// settings). Without it no notification goes to WhatsApp (Prompt 8).
  final bool whatsappOptIn;

  /// True while a submission waits for review: nothing new can be sent.
  bool get reviewPending => verification?.status == ReviewStatus.pending || status == AccountStatus.pending;

  RegistrationStage get stage {
    if (!emailVerified) {
      return RegistrationStage.email;
    }
    if (!termsAccepted) {
      return RegistrationStage.terms;
    }
    return RegistrationStage.complete;
  }

  @override
  bool operator ==(Object other) =>
      other is Account &&
      other.parentId == parentId &&
      other.status == status &&
      other.phone == phone &&
      other.email == email &&
      other.emailVerified == emailVerified &&
      other.termsAccepted == termsAccepted &&
      other.language == language &&
      other.firstName == firstName &&
      other.verification == verification &&
      other.claimsUpdatedAtMs == claimsUpdatedAtMs;

  @override
  int get hashCode =>
      Object.hash(parentId, status, phone, email, emailVerified, termsAccepted, language, firstName, verification, claimsUpdatedAtMs);
}
