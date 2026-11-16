import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native side of run recovery (ios/Classes/RunRecoveryPlugin.swift).
///
/// - [startRun]: while a run is on, iOS keeps the app's location going in
///   the background (iOS 17+: a background activity session; iOS 18+: a
///   "when in use" service session).
/// - [stopRun]: all of that ends with the run.
///
/// The plugin asks for no permission ("Always" is never requested) and no
/// coordinates cross the channel: the app's own tracker (geolocator) reads
/// and sends the location with "While Using the App".
class RunRecovery {
  RunRecovery({MethodChannel? channel, bool? isIos})
    : _channel = channel ?? const MethodChannel('org.schoolcarpool/run_recovery'),
      _isIos = isIos ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final MethodChannel _channel;
  final bool _isIos;

  bool get supported => _isIos;

  Future<T?> _call<T>(String method) async {
    if (!_isIos) {
      return null;
    }
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Returns whether a background activity session is on (iOS 17+).
  Future<bool> startRun() async => await _call<bool>('startRun') ?? false;

  Future<void> stopRun() async {
    await _call<bool>('stopRun');
  }
}
