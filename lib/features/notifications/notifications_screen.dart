import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/notifications/notification_center.dart';
import 'package:school_carpool/features/notifications/notification_labels.dart';
import 'package:school_carpool/features/notifications/notification_logic.dart';
import 'package:school_carpool/features/notifications/notification_models.dart';
import 'package:school_carpool/features/notifications/notification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Notifications tab (spec section 10; F12): swaps, join requests,
/// reminders and alerts, newest first, unread under "New". A row opens its
/// screen and marks it read. The app bar has "Mark all read" and the
/// notification settings.
///
/// States: loading (skeleton rows), empty ("No alerts yet"), error and
/// offline (retry). An unopened critical alert shows the alert banner on
/// top (spec section 11).
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<AppNotification>> list = ref.watch(notificationsProvider);
    final List<AppNotification> all = list.value ?? const <AppNotification>[];
    final bool anyUnread = all.any((AppNotification n) => n.unread);
    final DateTime now = ref.watch(notificationClockProvider)();

    final Widget body;
    final Object? error = list.error;
    if (error != null) {
      void retry() => ref.invalidate(notificationsProvider);
      body = NotificationFailure.from(error).isOffline ? OfflineStateView(onRetry: retry) : ErrorStateView(onRetry: retry);
    } else if (!list.hasValue) {
      body = const Skeleton(
        child: Column(
          children: <Widget>[SkeletonListRow(), SkeletonListRow(), SkeletonListRow(), SkeletonListRow()],
        ),
      );
    } else if (all.isEmpty) {
      body = EmptyStateView(
        key: const Key('notifications.empty'),
        icon: Icons.notifications_none_rounded,
        title: l10n.notifEmptyTitle,
        body: l10n.notifEmptyBody,
      );
    } else {
      final (List<AppNotification> fresh, List<AppNotification> earlier) = splitByRead(all);
      body = ListView(
        key: const Key('notifications.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          if (fresh.isNotEmpty) ...<Widget>[
            AppSectionHeader(l10n.notifNew),
            for (final AppNotification n in fresh) NotificationRow(notification: n, now: now),
          ],
          if (earlier.isNotEmpty) ...<Widget>[
            AppSectionHeader(l10n.notifEarlier),
            for (final AppNotification n in earlier) NotificationRow(notification: n, now: now),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: AppBarTitle(l10n.tabNotifications),
        actions: <Widget>[
          IconButton(
            key: const Key('notifications.markAll'),
            tooltip: l10n.notifMarkAllRead,
            icon: const Icon(Icons.done_all_rounded),
            onPressed: anyUnread ? () => unawaited(_markAll(context, ref, all)) : null,
          ),
          IconButton(
            key: const Key('notifications.settings'),
            tooltip: l10n.notifSettingsTitle,
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.go(ProfileRoutes.notifications),
          ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Future<void> _markAll(BuildContext context, WidgetRef ref, List<AppNotification> all) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final SessionState session = ref.read(sessionProvider);
    if (session is! SessionSignedIn) {
      return;
    }
    try {
      await ref.read(notificationRepositoryProvider).markAllRead(session.uid, <String>[
        for (final AppNotification n in all)
          if (n.unread) n.id,
      ]);
      showAppSnackBarOn(messenger, l10n.notifAllRead);
    } on NotificationFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    }
  }
}

/// One notification: icon, title (one line), the sentence, the time, and
/// a dot while unread. Tapping opens its screen.
class NotificationRow extends ConsumerWidget {
  const NotificationRow({required this.notification, required this.now, super.key});

  final AppNotification notification;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AppNotification n = notification;
    return AppListRow(
      key: Key('notification.${n.id}'),
      title: notificationTitle(l10n, n.kind),
      subtitle: notificationBody(l10n, n),
      leadingIcon: notificationIcon(n.kind),
      showChevron: false,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          OneLineText(
            notificationTime(l10n, n.createdAt, now),
            style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          if (n.unread) ...<Widget>[
            const SizedBox(height: AppSpacing.s4),
            AppUnreadDot(semanticLabel: l10n.notifUnread),
          ],
        ],
      ),
      onTap: () => openFromApp(ref, context, n),
    );
  }
}

/// The newest unopened critical alert, pinned above the tabs until opened
/// (spec section 11). Nothing when there is none.
class CriticalAlertBanner extends ConsumerWidget {
  const CriticalAlertBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppNotification? n = ref.watch(openCriticalProvider);
    if (n == null) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    return AppAlertBanner(
      key: const Key('notifications.criticalBanner'),
      title: notificationTitle(l10n, n.kind),
      body: notificationBody(l10n, n),
      actionLabel: l10n.notifOpen,
      onAction: () => openFromApp(ref, context, n),
    );
  }
}
