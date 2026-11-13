import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:screen_protector/screen_protector.dart';

/// Blocks screenshots and screen recording while document screens are open
/// (spec section 7). Nested screens count: protection stays on until the
/// last one closes.
///
/// - Android: FLAG_SECURE. Screenshots and recordings come out black, and
///   the app switcher shows a blank card.
/// - iOS: there is no official API. The screen_protector plugin puts the
///   app's view inside a secure text field layer, so screenshots and
///   recordings show a blank screen; the app switcher snapshot is blurred.
///   Limits: this relies on iOS behaviour Apple may change, and nothing
///   stops a second phone filming the screen.
/// - Web: not possible; nothing happens.
abstract interface class ScreenSecurity {
  Future<void> enable();
  Future<void> disable();
}

class PluginScreenSecurity implements ScreenSecurity {
  int _depth = 0;

  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  @override
  Future<void> enable() async {
    _depth += 1;
    if (_depth > 1 || !_supported) {
      return;
    }
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await ScreenProtector.preventScreenshotOn();
        await ScreenProtector.protectDataLeakageWithBlur();
      } else {
        await ScreenProtector.protectDataLeakageOn();
      }
    } on Object catch (error) {
      debugPrint('screen security: could not turn on ($error)');
    }
  }

  @override
  Future<void> disable() async {
    if (_depth == 0) {
      return;
    }
    _depth -= 1;
    if (_depth > 0 || !_supported) {
      return;
    }
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await ScreenProtector.preventScreenshotOff();
        await ScreenProtector.protectDataLeakageWithBlurOff();
      } else {
        await ScreenProtector.protectDataLeakageOff();
      }
    } on Object catch (error) {
      debugPrint('screen security: could not turn off ($error)');
    }
  }
}

/// Does nothing. For tests and screenshots.
class NoScreenSecurity implements ScreenSecurity {
  const NoScreenSecurity();

  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

final Provider<ScreenSecurity> screenSecurityProvider = Provider<ScreenSecurity>(
  (Ref ref) => PluginScreenSecurity(),
);

/// Turns screen security on while [child] is shown.
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen> {
  late final ScreenSecurity _security;

  @override
  void initState() {
    super.initState();
    _security = ref.read(screenSecurityProvider);
    unawaited(_security.enable());
  }

  @override
  void dispose() {
    unawaited(_security.disable());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
