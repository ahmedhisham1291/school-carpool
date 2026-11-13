import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/config/flavor.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/account.dart';
import 'package:school_carpool/features/auth/auth_failure.dart';
import 'package:school_carpool/features/auth/auth_repository.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Dev config for tests: no emulators, no Sentry.
const FlavorConfig testDevConfig = FlavorConfig(
  flavor: Flavor.dev,
  useEmulators: false,
  emulatorHost: 'localhost',
  sentryDsn: '',
  sentrySampleRate: 1,
  recaptchaSiteKey: '',
  appCheckDebugToken: '',
);

/// Same as [testDevConfig] but for staging (no developer tools).
const FlavorConfig testStagingConfig = FlavorConfig(
  flavor: Flavor.staging,
  useEmulators: false,
  emulatorHost: 'localhost',
  sentryDsn: '',
  sentrySampleRate: 1,
  recaptchaSiteKey: '',
  appCheckDebugToken: '',
);

/// Wraps [home] in a MaterialApp with our localizations and theme.
Widget buildTestApp(
  Widget home, {
  Locale locale = AppLocales.arabic,
  Brightness brightness = Brightness.light,
  DesignDirection direction = DesignDirection.a,
  FlavorConfig config = testDevConfig,
  SettingsStore? store,
  List<Override> extraOverrides = const <Override>[],
}) {
  return ProviderScope(
    overrides: [
      flavorConfigProvider.overrideWithValue(config),
      settingsStoreProvider.overrideWithValue(store ?? InMemorySettingsStore()),
      ...extraOverrides,
    ],
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppLocales.supported,
      localizationsDelegates: AppLocales.delegates,
      theme: AppTheme.build(direction, brightness),
      home: home,
    ),
  );
}

/// A signed-in parent for tests. Fake data only.
const Account testAccount = Account(
  parentId: 'ABCD2345',
  status: AccountStatus.unverified,
  phone: '+201000000001',
  email: 'parent@example.com',
  emailVerified: true,
  termsAccepted: true,
  language: 'ar',
);

const SessionState testUnverifiedSession = SessionSignedIn(uid: 'uid-1', account: testAccount);

const SessionState testVerifiedSession = SessionSignedIn(
  uid: 'uid-1',
  account: Account(
    parentId: 'ABCD2345',
    status: AccountStatus.verified,
    phone: '+201000000001',
    email: 'parent@example.com',
    emailVerified: true,
    termsAccepted: true,
    language: 'ar',
  ),
);

/// Records calls and answers with what the test sets. Throws [failure]
/// from every call when it is set.
class FakeAuthRepository implements AuthRepository {
  final List<String> calls = <String>[];
  AuthFailure? failure;
  bool emailConfirmed = false;
  bool? acceptedWhatsApp;
  String? lastPhone;
  String? lastCode;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final AuthFailure? f = failure;
    if (f != null) {
      throw f;
    }
  }

  @override
  Future<CodeRequest> requestCode({required String phoneE164, required String language}) async {
    lastPhone = phoneE164;
    await _maybeFail('requestCode');
    return const CodeRequest(resendAfter: Duration(seconds: 60), expiresIn: Duration(minutes: 5));
  }

  @override
  Future<void> verifyCode({required String phoneE164, required String code, required String language}) async {
    lastPhone = phoneE164;
    lastCode = code;
    await _maybeFail('verifyCode');
  }

  @override
  Future<void> sendEmailLink(String email) => _maybeFail('sendEmailLink');

  @override
  Future<bool> confirmEmail() async {
    await _maybeFail('confirmEmail');
    return emailConfirmed;
  }

  @override
  Future<void> acceptConsents({required bool whatsapp}) async {
    acceptedWhatsApp = whatsapp;
    await _maybeFail('acceptConsents');
  }

  @override
  Future<void> updateLanguage(String languageCode) => _maybeFail('updateLanguage:$languageCode');

  @override
  Future<void> signOut() => _maybeFail('signOut');
}

/// Overrides that keep Firebase out of widget tests: a fixed session and a
/// fake repository.
List<Override> authOverrides({
  SessionState session = testVerifiedSession,
  AuthRepository? repository,
}) => <Override>[
  sessionProvider.overrideWithValue(session),
  authRepositoryProvider.overrideWithValue(repository ?? FakeAuthRepository()),
];
