import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Signed-out part of sign-up: the number the code was sent to and when a
/// new code may be asked for. Kept in memory only (never saved).
@immutable
class SignupFlowState {
  const SignupFlowState({this.phoneE164, this.resendAvailableAt});

  final String? phoneE164;
  final DateTime? resendAvailableAt;
}

class SignupFlowController extends Notifier<SignupFlowState> {
  @override
  SignupFlowState build() => const SignupFlowState();

  void codeSent(String phoneE164, Duration resendAfter, {DateTime? now}) {
    state = SignupFlowState(
      phoneE164: phoneE164,
      resendAvailableAt: (now ?? DateTime.now()).add(resendAfter),
    );
  }

  void reset() => state = const SignupFlowState();
}

final NotifierProvider<SignupFlowController, SignupFlowState> signupFlowProvider =
    NotifierProvider<SignupFlowController, SignupFlowState>(SignupFlowController.new);
