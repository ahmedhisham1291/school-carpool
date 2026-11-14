import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/analytics/analytics.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/privacy/privacy_labels.dart';
import 'package:school_carpool/features/privacy/privacy_models.dart';
import 'package:school_carpool/features/privacy/privacy_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Signs this phone in again with the fresh token the server handed out
/// after it cut every session (Firebase can only end all of them at once).
typedef SessionRenewer = Future<void> Function(String token);

final Provider<SessionRenewer> sessionRenewerProvider = Provider<SessionRenewer>(
  (Ref ref) => (String token) async {
    final FirebaseAuth auth = ref.read(firebaseAuthProvider);
    await auth.signInWithCustomToken(token);
  },
);

/// Phones and sign-ins (spec section 7: "show active devices and recent
/// logins with sign-out for each"). Layout: one sentence; the list of
/// phones (this phone first and marked, the others with "Sign out"); the
/// primary action "Sign out other phones" when there are any; recent
/// sign-ins, a new phone marked.
///
/// States: loading (skeleton), empty (only this phone: a short note),
/// error and offline (retry).
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    void reload() => ref.invalidate(deviceListProvider);
    final Widget body = switch (ref.watch(deviceListProvider)) {
      AsyncData<DeviceList>(:final DeviceList value) => _DevicesContent(list: value, onChanged: reload),
      AsyncError<DeviceList>(:final Object error) => privacyErrorView(context, PrivacyFailure.from(error), reload),
      _ => const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()])),
    };
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.devicesTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _DevicesContent extends ConsumerStatefulWidget {
  const _DevicesContent({required this.list, required this.onChanged});

  final DeviceList list;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DevicesContent> createState() => _DevicesContentState();
}

class _DevicesContentState extends ConsumerState<_DevicesContent> {
  bool _busy = false;

  Future<void> _signOut({DeviceEntry? device}) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await showConfirmDialog(
      context: context,
      title: device == null ? l10n.devicesSignOutAllTitle : l10n.devicesSignOutTitle,
      body: l10n.devicesSignOutBody,
      confirmLabel: l10n.devicesSignOut,
      destructive: true,
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String token = await ref.read(privacyRepositoryProvider).signOutDevice(deviceKey: device?.key, all: device == null);
      if (token.isNotEmpty) {
        await ref.read(sessionRenewerProvider)(token);
      }
      ref.read(analyticsProvider).track(AnalyticsEvent.deviceSignedOut, <String, Object?>{'all': device == null});
      showAppSnackBarOn(messenger, l10n.devicesSignedOut);
      widget.onChanged();
    } on PrivacyFailure catch (f) {
      showAppSnackBarOn(messenger, f.message(l10n));
    } on Object {
      showAppSnackBarOn(messenger, l10n.errorGeneric);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
    final List<DeviceEntry> active = widget.list.devices.where((DeviceEntry d) => d.active).toList()
      ..sort((DeviceEntry a, DeviceEntry b) {
        if (a.key == widget.list.current) {
          return -1;
        }
        if (b.key == widget.list.current) {
          return 1;
        }
        return b.lastSeen.compareTo(a.lastSeen);
      });
    final bool others = active.any((DeviceEntry d) => d.key != widget.list.current);
    return ListView(
      key: const Key('devices.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(padding: AppSpacing.screenPadding, child: Text(l10n.devicesIntro, style: quiet)),
        AppSectionHeader(l10n.devicesActiveSection),
        // No trailing buttons or badges: the title keeps its room at 320 dp
        // and 200 percent text. Tapping another phone asks to sign it out.
        for (final DeviceEntry d in active)
          AppListRow(
            key: Key('devices.device.${d.key}'),
            title: d.key == widget.list.current ? l10n.devicesThisPhone : platformLabel(l10n, d.platform),
            subtitle: d.key == widget.list.current
                ? '${l10n.devicesCurrent} · ${l10n.devicesLastSeen(shortDateTime(context, d.lastSeen))}'
                : '${l10n.devicesLastSeen(shortDateTime(context, d.lastSeen))} · ${l10n.devicesTapToSignOut}',
            leadingIcon: d.platform == DevicePlatform.web ? Icons.laptop_outlined : Icons.phone_iphone_rounded,
            showChevron: d.key != widget.list.current,
            onTap: d.key == widget.list.current || _busy ? null : () => unawaited(_signOut(device: d)),
          ),
        if (!others) Padding(padding: AppSpacing.screenPadding, child: Text(l10n.devicesOnlyThis, style: quiet)),
        if (others)
          Padding(
            padding: AppSpacing.screenPadding,
            child: AppButton(
              key: const Key('devices.signOutAll'),
              label: l10n.devicesSignOutAll,
              icon: Icons.logout_rounded,
              variant: AppButtonVariant.secondary,
              expand: true,
              loading: _busy,
              onPressed: _busy ? null : () => unawaited(_signOut()),
            ),
          ),
        if (widget.list.logins.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.devicesRecentSection),
          for (final LoginEntry l in widget.list.logins)
            AppListRow(
              title: platformLabel(l10n, l.platform),
              subtitle: l.newDevice ? '${shortDateTime(context, l.at)} · ${l10n.devicesNewPhone}' : shortDateTime(context, l.at),
              leadingIcon: l.newDevice ? Icons.new_releases_outlined : Icons.login_rounded,
              showChevron: false,
            ),
        ],
      ],
    );
  }
}
