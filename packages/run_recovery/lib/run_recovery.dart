import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the iPhone's location permission stands (CLAuthorizationStatus).
enum RecoveryAuthorization {
  notDetermined,
  whenInUse,
  always,
  denied,
  restricted,

  /// Not an iPhone (Android, the web, tests): no recovery.
  unsupported;

  static RecoveryAuthorization fromWire(Object? value) {
    for (final RecoveryAuthorization a in values) {
      if (a.name == value) {
        return a;
      }
    }
    return unsupported;
  }
}

/// The native side of run recovery (ios/Classes/RunRecoveryPlugin.swift).
///
/// - [startRun]: while a run is on, iOS keeps the app's location going in
///   the background (iOS 17+: a background activity session; iOS 18+: a
///   service session) and, with "Always", watches significant location
///   changes, so iOS relaunches the app in the background (about every
///   500 m) if it was closed or swiped away during the run.
/// - [stopRun]: all of that ends with the run.
/// - [launchedForLocation]: this start is such a relaunch.
/// - [requestAlways]: the optional "Always" upgrade (only after "While
///   Using the App" was given).
///
/// No coordinates cross the channel: the app's own tracker (geolocator)
/// reads and sends the location.
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

  Future<RecoveryAuthorization> authorization() async => RecoveryAuthorization.fromWire(await _call<String>('authorization'));

  /// Shows iOS's "Change to Always Allow" prompt (once per install; later
  /// only Settings can change it). Returns the status afterwards.
  Future<RecoveryAuthorization> requestAlways() async => RecoveryAuthorization.fromWire(await _call<String>('requestAlways'));

  /// Returns whether significant-change monitoring (relaunch) is on.
  Future<bool> startRun() async => await _call<bool>('startRun') ?? false;

  Future<void> stopRun() async {
    await _call<bool>('stopRun');
  }

  Future<bool> launchedForLocation() async => await _call<bool>('launchedForLocation') ?? false;
}
