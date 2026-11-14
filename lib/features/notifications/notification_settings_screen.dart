import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/notifications/notification_labels.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Alert settings (spec section 10, "WhatsApp notifications on or off by
/// type"; F12). Push always comes; each group can also come by WhatsApp.
/// COST MODE: only the urgent groups are on by default. Quiet hours make
/// other alerts silent at night; urgent alerts always sound.
///
/// Every switch saves at once through updateNotificationSettings: it moves
/// right away and goes back if saving fails (snackbar says why).
///
/// States: loading (skeleton), error and offline (retry). There is no
/// empty state: a parent who never saved sees the defaults.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  /// Changes shown before the server confirms them.
  NotificationSettings? _pending;
  bool _saving = false;

  Future<void> _save(NotificationSettings next, Future<void> Function(NotificationRepository repo) call) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _pending = next;
      _saving = true;
    });
    try {
      await call(ref.read(notificationRepositoryProvider));
      showAppSnackBarOn(messenger, l10n.settingsSaved);
    } on NotificationFailure catch (failure) {
      if (mounted) {
        setState(() => _pending = null);
      }
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<NotificationSettings> stored = ref.watch(notificationSettingsProvider);
    final Widget body;
    final Object? error = stored.error;
    if (error != null) {
      void retry() => ref.invalidate(notificationSettingsProvider);
      body = NotificationFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry);
    } else if (!stored.hasValue) {
      body = const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow()]));
    } else {
      final NotificationSettings s = _pending ?? stored.value!;
      final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
      body = ListView(
        key: const Key('notifSettings.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
            child: Text(l10n.notifSettingsIntro, style: quiet),
          ),
          AppSectionHeader(l10n.notifWhatsAppSection),
          for (final WhatsAppGroup g in WhatsAppGroup.values)
            AppSwitchRow(
              key: Key('notifSettings.${g.name}'),
              title: whatsAppGroupTitle(l10n, g),
              subtitle: s.whatsappOn(g) ? l10n.notifWhatsAppOn : l10n.notifWhatsAppOff,
              leadingIcon: g.defaultOn ? Icons.warning_amber_rounded : Icons.chat_outlined,
              value: s.whatsappOn(g),
              onChanged: _saving
                  ? null
                  : (bool on) => unawaited(_save(s.withWhatsApp(g, on), (NotificationRepository r) => r.setWhatsApp(g, on: on))),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s8, AppSpacing.screenGutter, 0),
            child: Text(l10n.notifChatPushOnly, style: quiet),
          ),
          AppSectionHeader(l10n.notifQuietSection),
          AppSwitchRow(
            key: const Key('notifSettings.quiet'),
            title: l10n.notifQuietHours,
            subtitle: l10n.notifQuietHelper(s.quietFrom, s.quietTo),
            leadingIcon: Icons.bedtime_outlined,
            value: s.quietHours,
            onChanged: _saving
                ? null
                : (bool on) => unawaited(_save(s.withQuietHours(on), (NotificationRepository r) => r.setQuietHours(on: on))),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.notifSettingsTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}
