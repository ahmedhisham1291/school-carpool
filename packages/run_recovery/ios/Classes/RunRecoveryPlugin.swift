import CoreLocation
import Flutter
import UIKit

/// School Carpool run recovery (Prompt 13; "Always" removed 16 Nov 2026).
///
/// The app's tracker (geolocator) sends the location with the "While Using
/// the App" permission. This plugin only helps iOS keep that going while a
/// run is on, when the driver switches apps, takes a call or locks the
/// phone:
/// - iOS 17+: a CLBackgroundActivitySession while a run is on.
/// - iOS 18+: also a CLServiceSession (when in use) for the run.
/// Everything stops at the end of the run. The plugin never asks for a
/// permission, never asks for "Always", never reads a coordinate and does
/// not use significant location changes (owner decision 16 Nov 2026: App
/// Review guideline 5.1.1, ask only for what the feature needs). If iOS
/// closes the app, the driver opens it again and Dart resumes the run from
/// its local marker (lib/features/trips/run_recovery.dart).
/// Only a yes/no flag is stored (UserDefaults).
public class RunRecoveryPlugin: NSObject, FlutterPlugin {
  private static let activeKey = "schoolcarpool.runRecovery.active"

  /// CLBackgroundActivitySession (iOS 17+), typed loosely for older SDK checks.
  private var activitySession: AnyObject?
  /// CLServiceSession (iOS 18+).
  private var serviceSession: AnyObject?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.schoolcarpool/run_recovery", binaryMessenger: registrar.messenger())
    let instance = RunRecoveryPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  // MARK: Channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startRun":
      result(startRun())
    case "stopRun":
      stopRun()
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Run

  /// True when a background activity session is on (iOS 17 and later).
  private func startRun() -> Bool {
    UserDefaults.standard.set(true, forKey: Self.activeKey)
    beginSessions()
    return activitySession != nil
  }

  private func stopRun() {
    UserDefaults.standard.set(false, forKey: Self.activeKey)
    endSessions()
  }

  private func beginSessions() {
    if #available(iOS 17.0, *) {
      if activitySession == nil {
        activitySession = CLBackgroundActivitySession()
      }
    }
    if #available(iOS 18.0, *) {
      if serviceSession == nil {
        serviceSession = CLServiceSession(authorization: .whenInUse)
      }
    }
  }

  private func endSessions() {
    if #available(iOS 17.0, *) {
      (activitySession as? CLBackgroundActivitySession)?.invalidate()
    }
    activitySession = nil
    if #available(iOS 18.0, *) {
      (serviceSession as? CLServiceSession)?.invalidate()
    }
    serviceSession = nil
  }
}
