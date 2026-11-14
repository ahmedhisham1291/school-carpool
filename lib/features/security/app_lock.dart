import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/wallet/device_auth.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// App lock with Face ID, fingerprint or the phone passcode (spec section
/// 7, Prompt 12). Off by default; the parent switches it on in Settings
/// after one successful check. While on:
/// - the app opens locked;
/// - leaving the app covers it at once (the app switcher shows no data);
/// - back after [kAppLockGrace] or longer, it is locked again.
/// Transfers still ask for their own fresh check (MONEY rules).

const Duration kAppLockGrace = Duration(seconds: 30);

@immutable
class AppLockState {
  const AppLockState({required this.enabled, required this.locked, this.covered = false});

  final bool enabled;
  final bool locked;

  /// The app is in the background: covered, not locked yet.
  final bool covered;

  bool get showLock => enabled && (locked || covered);
}

/// Pure rule: locked again when the app was away for the grace time or longer.
bool lockAfterBackground({required bool enabled, required DateTime? leftAt, required DateTime now, Duration grace = kAppLockGrace}) =>
    enabled && (leftAt == null || now.difference(leftAt) >= grace);

class AppLockController extends Notifier<AppLockState> {
  static const String storageKey = 'appLock.enabled';

  DateTime? _leftAt;
  DateTime Function() now = () => DateTime.now().toUtc();

  @override
  AppLockState build() {
    final bool enabled = ref.watch(settingsStoreProvider).read(storageKey) == 'true';
    return AppLockState(enabled: enabled, locked: enabled);
  }

  /// The app left the foreground (inactive, hidden or paused).
  void left() {
    if (!state.enabled || state.covered) {
      return;
    }
    _leftAt = now();
    state = AppLockState(enabled: true, locked: state.locked, covered: true);
  }

  /// The app is back.
  void resumed() {
    if (!state.enabled) {
      return;
    }
    final bool lock = state.locked || lockAfterBackground(enabled: true, leftAt: _leftAt, now: now());
    _leftAt = null;
    state = AppLockState(enabled: true, locked: lock);
  }

  /// Asks the phone for Face ID, fingerprint or the passcode; true when unlocked.
  Future<bool> unlock(String reason) async {
    final DeviceAuthResult result = await ref.read(deviceAuthProvider).confirm(reason);
    if (result != DeviceAuthResult.ok) {
      return false;
    }
    state = AppLockState(enabled: state.enabled, locked: false);
    return true;
  }

  /// Switches the lock on (after one successful check) or off.
  Future<DeviceAuthResult> setEnabled(bool enabled, String reason) async {
    if (enabled) {
      final DeviceAuthResult result = await ref.read(deviceAuthProvider).confirm(reason);
      if (result != DeviceAuthResult.ok) {
        return result;
      }
    }
    await ref.read(settingsStoreProvider).write(storageKey, enabled ? 'true' : null);
    state = AppLockState(enabled: enabled, locked: false);
    return DeviceAuthResult.ok;
  }
}

final NotifierProvider<AppLockController, AppLockState> appLockProvider = NotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);

/// Wraps the whole app (MaterialApp builder). Locks only a signed-in parent.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final AppLockController lock = ref.read(appLockProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        lock.resumed();
      case AppLifecycleState.inactive || AppLifecycleState.hidden || AppLifecycleState.paused:
        lock.left();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLockState lock = ref.watch(appLockProvider);
    final bool signedIn = ref.watch(sessionProvider) is SessionSignedIn;
    final bool show = signedIn && lock.showLock;
    return Stack(
      children: <Widget>[
        ExcludeSemantics(excluding: show, child: widget.child),
        // Keyed on locked: when the switcher cover turns into the lock, a new
        // screen is built and asks for Face ID at once (review item 15).
        if (show) Positioned.fill(child: AppLockScreen(key: ValueKey<bool>(lock.locked), covered: !lock.locked)),
      ],
    );
  }
}

/// The lock screen: one primary action. [covered] only hides the app while
/// it is in the background (no check is asked then).
class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({required this.covered, super.key});

  final bool covered;

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.covered) {
      // Ask at once when the lock screen appears.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_unlock()));
    }
  }

  Future<void> _unlock() async {
    if (_busy || !mounted) {
      return;
    }
    final String reason = context.l10n.appLockReason;
    setState(() => _busy = true);
    final bool ok = await ref.read(appLockProvider.notifier).unlock(reason);
    if (mounted) {
      setState(() {
        _busy = false;
        _failed = !ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Material(
      color: context.colors.surface,
      child: SafeArea(
        child: Padding(
          padding: AppSpacing.screenPadding,
          child: Column(
            children: <Widget>[
              const Spacer(),
              Icon(Icons.lock_outline_rounded, size: AppIconSize.xl, color: context.colors.primary, semanticLabel: l10n.appLockTitle),
              const SizedBox(height: AppSpacing.s16),
              OneLineText(l10n.appLockTitle, style: context.text.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.s8),
              Text(
                _failed ? l10n.appLockFailed : l10n.appLockBody,
                style: context.text.bodyLarge?.copyWith(color: context.colors.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              if (!widget.covered)
                AppButton(
                  key: const Key('appLock.unlock'),
                  label: l10n.appLockUnlock,
                  icon: Icons.face_retouching_natural_outlined,
                  expand: true,
                  loading: _busy,
                  onPressed: _busy ? null : () => unawaited(_unlock()),
                ),
              const SizedBox(height: AppSpacing.s16),
            ],
          ),
        ),
      ),
    );
  }
}
