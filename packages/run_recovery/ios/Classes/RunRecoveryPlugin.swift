import CoreLocation
import Flutter
import UIKit

/// School Carpool run recovery (Prompt 13, owner request 14 Nov 2026 13:44).
///
/// The app's tracker (geolocator) sends the location. This plugin only
/// helps iOS keep it going and bring the app back during a run:
/// - iOS 17+: a CLBackgroundActivitySession while a run is on (keeps the
///   app's background location session alive between app switches, calls
///   and the lock screen).
/// - iOS 18+: also a CLServiceSession for the run.
/// - With "Always": significant location change monitoring while a run is
///   on, so iOS relaunches the app in the background (about every 500 m)
///   after it was closed or swiped away; Dart then resumes the run
///   (lib/features/trips/run_recovery.dart).
/// Everything stops at the end of the run. Only a yes/no flag is stored
/// (UserDefaults); never a coordinate.
public class RunRecoveryPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private static let activeKey = "schoolcarpool.runRecovery.active"
  /// Fallback only: the answer normally comes from the authorization
  /// callback or when the app becomes active again after iOS's prompt.
  private static let alwaysTimeout: TimeInterval = 10

  private let manager = CLLocationManager()
  private var launchedForLocation = false
  private var monitoring = false
  private var pendingAlways: [FlutterResult] = []
  /// Each request's own timer: an old timer never answers a newer request.
  private var alwaysRequest = 0
  /// CLBackgroundActivitySession (iOS 17+), typed loosely for older SDK checks.
  private var activitySession: AnyObject?
  /// CLServiceSession (iOS 18+).
  private var serviceSession: AnyObject?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "org.schoolcarpool/run_recovery", binaryMessenger: registrar.messenger())
    let instance = RunRecoveryPlugin()
    instance.manager.delegate = instance
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
  }

  // MARK: Launch

  /// Gets the real launch options because the app uses the classic app
  /// delegate (no UIScene; tool/patch_native.py patch_ios_launch). With a
  /// scene-based app Flutter would pass empty options here.
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]) -> Bool {
    launchedForLocation = launchOptions[UIApplication.LaunchOptionsKey.location.rawValue] != nil
      || launchOptions[UIApplication.LaunchOptionsKey.location] != nil
    if launchedForLocation && UserDefaults.standard.bool(forKey: Self.activeKey) && status() == .authorizedAlways {
      // Relaunched by a significant change during a run: keep monitoring
      // (iOS needs it started again in this process) while Dart resumes.
      manager.startMonitoringSignificantLocationChanges()
      monitoring = true
      beginSessions()
    }
    return true
  }

  // MARK: Channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorization":
      result(name(of: status()))
    case "requestAlways":
      requestAlways(result)
    case "startRun":
      result(startRun())
    case "stopRun":
      stopRun()
      result(true)
    case "launchedForLocation":
      result(launchedForLocation)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func status() -> CLAuthorizationStatus {
    return manager.authorizationStatus
  }

  private func name(of status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .authorizedWhenInUse: return "whenInUse"
    case .authorizedAlways: return "always"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "denied"
    }
  }

  /// "Always" is optional (owner decision): asked only after "While Using
  /// the App". iOS shows its upgrade prompt once; if it does not show
  /// (already answered), the current status comes back after the timeout.
  private func requestAlways(_ result: @escaping FlutterResult) {
    let current = status()
    guard current == .authorizedWhenInUse else {
      result(name(of: current))
      return
    }
    pendingAlways.append(result)
    alwaysRequest += 1
    let request = alwaysRequest
    manager.requestAlwaysAuthorization()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.alwaysTimeout) { [weak self] in
      guard let self = self, self.alwaysRequest == request else { return }
      self.answerAlways()
    }
  }

  /// "Keep Only While Using" changes nothing, so no authorization callback
  /// comes; iOS's prompt closing makes the app active again: answer then
  /// (shortly after, so a real change is seen first).
  public func applicationDidBecomeActive(_ application: UIApplication) {
    guard !pendingAlways.isEmpty else { return }
    let request = alwaysRequest
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
      guard let self = self, self.alwaysRequest == request else { return }
      self.answerAlways()
    }
  }

  private func answerAlways() {
    let answer = name(of: status())
    let waiting = pendingAlways
    pendingAlways.removeAll()
    for result in waiting {
      result(answer)
    }
  }

  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if !pendingAlways.isEmpty && status() != .authorizedWhenInUse {
      answerAlways()
    }
    if monitoring && status() != .authorizedAlways {
      manager.stopMonitoringSignificantLocationChanges()
      monitoring = false
    }
  }

  public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Nothing to do: a significant change only wakes the app; the
    // geolocator tracker sends the points.
  }

  public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Ignored: the run screen and the server watch for missing points.
  }

  // MARK: Run

  private func startRun() -> Bool {
    UserDefaults.standard.set(true, forKey: Self.activeKey)
    beginSessions()
    if status() == .authorizedAlways && CLLocationManager.significantLocationChangeMonitoringAvailable() {
      manager.startMonitoringSignificantLocationChanges()
      monitoring = true
    }
    return monitoring
  }

  private func stopRun() {
    UserDefaults.standard.set(false, forKey: Self.activeKey)
    if monitoring {
      manager.stopMonitoringSignificantLocationChanges()
      monitoring = false
    }
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
        let requirement: CLServiceSession.AuthorizationRequirement = status() == .authorizedAlways ? .always : .whenInUse
        serviceSession = CLServiceSession(authorization: requirement)
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
