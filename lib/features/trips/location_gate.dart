import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart' as fcm;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/trips/geolocator_tracker.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// What a driver needs before a run (owner decision, docs/DECISIONS.md
/// "Location tracking on iPhone", option 1: block driving only, never the
/// whole app, App Store guideline 5.1.1).
enum GateItem {
  /// Location Services on the phone.
  service,

  /// This app's location permission: "While Using the App" (or Always).
  permission,

  /// Precise Location (iOS 14 and later; Android "precise").
  precise,

  /// Notifications allowed ("Run still on" and the run's alerts).
  notifications;

  bool get isLocation => this != GateItem.notifications;
}

/// One check of everything in [GateItem].
@immutable
class DrivingCheck {
  const DrivingCheck({this.missing = const <GateItem>{}, this.locationNotAsked = false, this.notificationsNotAsked = false});

  static const DrivingCheck ready = DrivingCheck();

  /// In [GateItem] order.
  final Set<GateItem> missing;

  /// The system prompt was never shown: ask in the app first.
  final bool locationNotAsked;
  final bool notificationsNotAsked;

  bool get isReady => missing.isEmpty;

  /// Location only (the home banner ignores notifications).
  bool get locationReady => !missing.any((GateItem i) => i.isLocation);

  bool get anyNotAsked => locationNotAsked || notificationsNotAsked;

  List<GateItem> items({required bool locationOnly}) =>
      GateItem.values.where((GateItem i) => missing.contains(i) && (!locationOnly || i.isLocation)).toList();
}

abstract interface class DrivingReadiness {
  Future<DrivingCheck> check();

  /// Shows the system prompts that were never shown: location "While Using
  /// the App" and notifications. Never asks for "Always".
  Future<DrivingCheck> requestNotAsked();

  /// Opens this app's page in Settings (Location, Notifications); when
  /// Location Services are off, the phone's location settings where the
  /// phone allows it (iPhone opens the app's page; the steps say where).
  Future<void> openSettings({required bool serviceOff});

  /// Location Services switched on (true) or off (false).
  Stream<bool> serviceChanges();
}

/// The phone: geolocator for location, Firebase Messaging for notifications.
class DeviceDrivingReadiness implements DrivingReadiness {
  const DeviceDrivingReadiness({this._source = const GeolocatorSource(), this._notifications = const FcmNotificationStatus()});

  final GeoSource _source;
  final NotificationStatus _notifications;

  @override
  Future<DrivingCheck> check() => checkWith(_source, _notifications);

  @override
  Future<DrivingCheck> requestNotAsked() async {
    final DrivingCheck before = await check();
    if (before.locationNotAsked && !before.missing.contains(GateItem.service)) {
      try {
        await _source.requestPermission();
      } on Object {
        // Refused or already asked: the next check says so.
      }
    }
    if (before.notificationsNotAsked) {
      try {
        await _notifications.request();
      } on Object {
        // As above.
      }
    }
    return check();
  }

  @override
  Future<void> openSettings({required bool serviceOff}) async {
    if (serviceOff && defaultTargetPlatform == TargetPlatform.android) {
      await _source.openLocationSettings();
    } else {
      await _source.openAppSettings();
    }
  }

  @override
  Stream<bool> serviceChanges() => _source.serviceStatus().map((ServiceStatus s) => s == ServiceStatus.enabled);
}

/// A check that throws counts as its [fallback] (shown as missing).
Future<T> _or<T>(Future<T> Function() read, T fallback) async {
  try {
    return await read();
  } on Object {
    return fallback;
  }
}

/// Shared by the phone implementation and the unit tests (fake source).
Future<DrivingCheck> checkWith(GeoSource source, NotificationStatus notifications) async {
  final Set<GateItem> missing = <GateItem>{};
  final bool serviceOn = await _or(source.serviceEnabled, false);
  if (!serviceOn) {
    missing.add(GateItem.service);
  }
  final LocationPermission permission = await _or(source.checkPermission, LocationPermission.unableToDetermine);
  final bool granted = permission == LocationPermission.whileInUse || permission == LocationPermission.always;
  if (!granted) {
    missing.add(GateItem.permission);
  } else if (serviceOn && await _or(source.accuracy, LocationAccuracyStatus.unknown) == LocationAccuracyStatus.reduced) {
    missing.add(GateItem.precise);
  }
  final NotificationAccess access = await _or(notifications.status, NotificationAccess.denied);
  if (access != NotificationAccess.allowed) {
    missing.add(GateItem.notifications);
  }
  return DrivingCheck(
    missing: missing,
    // iOS answers "denied" before the parent was ever asked.
    locationNotAsked: !granted && (permission == LocationPermission.denied || permission == LocationPermission.unableToDetermine),
    notificationsNotAsked: access == NotificationAccess.notAsked,
  );
}

enum NotificationAccess { allowed, denied, notAsked }

abstract interface class NotificationStatus {
  Future<NotificationAccess> status();
  Future<void> request();
}

class FcmNotificationStatus implements NotificationStatus {
  const FcmNotificationStatus();

  @override
  Future<NotificationAccess> status() async {
    final fcm.NotificationSettings s = await fcm.FirebaseMessaging.instance.getNotificationSettings();
    return switch (s.authorizationStatus) {
      fcm.AuthorizationStatus.authorized || fcm.AuthorizationStatus.provisional => NotificationAccess.allowed,
      fcm.AuthorizationStatus.notDetermined => NotificationAccess.notAsked,
      fcm.AuthorizationStatus.denied => NotificationAccess.denied,
    };
  }

  @override
  Future<void> request() async {
    await fcm.FirebaseMessaging.instance.requestPermission();
  }
}

/// Tests, CI, the website and the gallery: everything on unless a test
/// says otherwise.
class FakeDrivingReadiness implements DrivingReadiness {
  FakeDrivingReadiness({this.current = DrivingCheck.ready, this.afterRequest});

  DrivingCheck current;

  /// What the "system prompts" leave behind; null: unchanged.
  DrivingCheck? afterRequest;
  int checks = 0;
  int requests = 0;
  int settingsOpened = 0;
  final StreamController<bool> _service = StreamController<bool>.broadcast();

  @override
  Future<DrivingCheck> check() async {
    checks++;
    return current;
  }

  @override
  Future<DrivingCheck> requestNotAsked() async {
    requests++;
    current = afterRequest ?? current;
    return current;
  }

  @override
  Future<void> openSettings({required bool serviceOff}) async => settingsOpened++;

  @override
  Stream<bool> serviceChanges() => _service.stream;

  /// Tests: Location Services switched on or off.
  void service(bool on) => _service.add(on);

  Future<void> dispose() => _service.close();
}

/// Replaced in bootstrap.dart on the phone with [DeviceDrivingReadiness].
final Provider<DrivingReadiness> drivingReadinessProvider = Provider<DrivingReadiness>((Ref ref) {
  final FakeDrivingReadiness fake = FakeDrivingReadiness();
  ref.onDispose(() => unawaited(fake.dispose()));
  return fake;
});

/// Before a run: true when the driver may start. Asks the system prompts
/// that were never shown first, then shows the blocking steps for what is
/// still missing. The rest of the app stays open.
Future<bool> ensureReadyToDrive(BuildContext context, WidgetRef ref) async {
  final DrivingReadiness readiness = ref.read(drivingReadinessProvider);
  DrivingCheck check = await readiness.check();
  if (check.isReady) {
    return true;
  }
  if (check.anyNotAsked) {
    check = await readiness.requestNotAsked();
    if (check.isReady) {
      return true;
    }
  }
  if (!context.mounted) {
    return false;
  }
  return showLocationSteps(context, blocking: true);
}

/// Opens the steps full screen. [blocking]: the driving gate (every item,
/// closes with true once all pass). Otherwise the home banner's steps
/// (location items only, never blocks).
Future<bool> showLocationSteps(BuildContext context, {required bool blocking}) async {
  final bool? ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(fullscreenDialog: true, builder: (BuildContext _) => LocationStepsScreen(blocking: blocking)),
  );
  return ok ?? false;
}

/// The steps (Arabic first). One line per missing item with numbered
/// steps, one primary "Open Settings", a re-check whenever the app comes
/// back (and when Location Services change), and it closes by itself when
/// nothing is missing.
///
/// States: loading (skeleton rows during the first check); empty never
/// shows (it closes); an error in a check counts as missing (the steps
/// still help); offline does not apply (all checks are on the phone).
class LocationStepsScreen extends ConsumerStatefulWidget {
  const LocationStepsScreen({required this.blocking, super.key});

  final bool blocking;

  @override
  ConsumerState<LocationStepsScreen> createState() => _LocationStepsScreenState();
}

class _LocationStepsScreenState extends ConsumerState<LocationStepsScreen> {
  DrivingCheck? _check;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<bool>? _service;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_recheck()));
    _service = ref.read(drivingReadinessProvider).serviceChanges().listen((_) => unawaited(_recheck()));
    unawaited(_recheck());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_service?.cancel());
    super.dispose();
  }

  List<GateItem> get _items => _check?.items(locationOnly: !widget.blocking) ?? const <GateItem>[];

  Future<void> _recheck() async {
    final DrivingCheck check = await ref.read(drivingReadinessProvider).check();
    if (!mounted || _closed) {
      return;
    }
    final bool done = widget.blocking ? check.isReady : check.locationReady;
    if (done) {
      _closed = true;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _check = check);
  }

  Future<void> _open() async {
    final DrivingCheck? check = _check;
    final DrivingReadiness readiness = ref.read(drivingReadinessProvider);
    if (check != null && check.anyNotAsked) {
      final DrivingCheck after = await readiness.requestNotAsked();
      if (!mounted) {
        return;
      }
      if (widget.blocking ? after.isReady : after.locationReady) {
        await _recheck();
        return;
      }
    }
    await readiness.openSettings(serviceOff: check?.missing.contains(GateItem.service) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final DrivingCheck? check = _check;
    return Scaffold(
      key: const Key('gate.screen'),
      appBar: AppBar(
        leading: IconButton(
          key: const Key('gate.close'),
          icon: const Icon(Icons.close_rounded),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: AppBarTitle(widget.blocking ? l10n.gateTitle : l10n.gateLocationTitle),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: check == null
                  ? const _StepsSkeleton()
                  : ListView(
                      key: const Key('gate.list'),
                      padding: AppSpacing.screenPadding,
                      children: <Widget>[
                        Text(
                          widget.blocking ? l10n.gateIntro : l10n.gateLocationIntro,
                          style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant),
                        ),
                        for (final GateItem item in _items) ...<Widget>[
                          const SizedBox(height: AppSpacing.s16),
                          _ItemCard(key: Key('gate.item.${item.name}'), item: item),
                        ],
                        const SizedBox(height: AppSpacing.s16),
                        Text(l10n.gateRecheck, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                      ],
                    ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: AppButton(
                key: const Key('gate.openSettings'),
                label: l10n.locationOpenSettings,
                icon: Icons.settings_outlined,
                size: AppButtonSize.large,
                expand: true,
                onPressed: check == null ? null : () => unawaited(_open()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, super.key});

  final GateItem item;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String title, IconData icon, List<String> steps) = switch (item) {
      GateItem.service => (
        l10n.gateServiceTitle,
        Icons.location_off_outlined,
        <String>[l10n.gateServiceStep1, l10n.gateServiceStep2, l10n.gateServiceStep3, l10n.gateServiceStep4],
      ),
      GateItem.permission => (
        l10n.gatePermissionTitle,
        Icons.my_location_rounded,
        <String>[l10n.gateOpenStep, l10n.gateLocationStep, l10n.gatePermissionStep],
      ),
      GateItem.precise => (
        l10n.gatePreciseTitle,
        Icons.gps_fixed_rounded,
        <String>[l10n.gateOpenStep, l10n.gateLocationStep, l10n.gatePreciseStep],
      ),
      GateItem.notifications => (
        l10n.gateNotificationsTitle,
        Icons.notifications_off_outlined,
        <String>[l10n.gateOpenStep, l10n.gateNotificationsStep1, l10n.gateNotificationsStep2],
      ),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ExcludeSemantics(child: Icon(icon, color: context.colors.primary, size: AppIconSize.md)),
              const SizedBox(width: AppSpacing.s16),
              Expanded(
                child: Semantics(header: true, child: OneLineText(title, style: context.text.titleMedium)),
              ),
            ],
          ),
          for (int i = 0; i < steps.length; i++) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            _StepLine(number: i + 1, text: steps[i]),
          ],
        ],
      ),
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${context.l10n.gateStepNumber(number)}: $text',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: AppSpacing.s32,
            child: Text('$number.', style: context.text.bodyLarge?.copyWith(color: context.colors.primary)),
          ),
          Expanded(child: Text(text, style: context.text.bodyLarge)),
        ],
      ),
    );
  }
}

class _StepsSkeleton extends StatelessWidget {
  const _StepsSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s24),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
        ],
      ),
    ),
  );
}

/// The home banner's check: location only, re-read when the app comes back.
final FutureProvider<DrivingCheck> locationBannerCheckProvider = FutureProvider<DrivingCheck>((Ref ref) {
  final AppLifecycleListener lifecycle = AppLifecycleListener(onResume: ref.invalidateSelf);
  ref.onDispose(lifecycle.dispose);
  return ref.watch(drivingReadinessProvider).check();
});

/// Home: "Location is off" when location is off, refused or approximate.
/// Hidden while loading, when ready, on error and offline. Never blocks.
class LocationOffBanner extends ConsumerWidget {
  const LocationOffBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DrivingCheck? check = ref.watch(locationBannerCheckProvider).value;
    if (check == null || check.locationReady) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    return AppAlertBanner(
      key: const Key('home.locationBanner'),
      tone: AppStateTone.warning,
      icon: Icons.location_off_outlined,
      title: l10n.locationBannerTitle,
      body: l10n.locationBannerBody,
      actionLabel: l10n.locationBannerAction,
      onAction: () => unawaited(
        showLocationSteps(context, blocking: false).then((_) {
          ref.invalidate(locationBannerCheckProvider);
        }),
      ),
    );
  }
}
