import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/settings/settings_store.dart';

/// Offline (spec section 11, Prompt 12): "confirmations queue and send
/// once". A driver who confirms a run with no connection gets "Saved,
/// sends when you are back online"; the confirmation is kept on the phone
/// (carpool and run IDs only, no personal data) and sent at the next start,
/// on resume and every 30 seconds while any is waiting. Confirming is
/// idempotent on the server (a confirmed run stays confirmed), so a retry
/// can never confirm twice. Today's schedule and the pickup list come from
/// Firestore's offline cache (schedule and trip documents), so they stay
/// readable without a connection.

@immutable
class PendingConfirm {
  const PendingConfirm(this.carpoolId, this.runId);

  static PendingConfirm? parse(String value) {
    final List<String> parts = value.split('|');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return null;
    }
    return PendingConfirm(parts[0], parts[1]);
  }

  final String carpoolId;
  final String runId;

  String get key => '$carpoolId|$runId';

  @override
  bool operator ==(Object other) => other is PendingConfirm && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

abstract final class PendingConfirms {
  static const String storageKey = 'schedule.pendingConfirms';

  /// At most this many wait on the phone (oldest dropped).
  static const int max = 20;

  static List<PendingConfirm> decode(String? stored) => <PendingConfirm>[
    for (final String s in (stored ?? '').split(','))
      if (PendingConfirm.parse(s) case final PendingConfirm p) p,
  ];

  static String? encode(List<PendingConfirm> list) => list.isEmpty ? null : list.map((PendingConfirm p) => p.key).join(',');

  /// Adds once; the same run is never queued twice.
  static List<PendingConfirm> add(List<PendingConfirm> list, PendingConfirm p) {
    if (list.contains(p)) {
      return list;
    }
    final List<PendingConfirm> next = <PendingConfirm>[...list, p];
    return next.length > max ? next.sublist(next.length - max) : next;
  }
}

class ConfirmationQueue extends Notifier<List<PendingConfirm>> {
  Timer? _timer;
  bool _flushing = false;

  @override
  List<PendingConfirm> build() {
    final AppLifecycleListener lifecycle = AppLifecycleListener(onResume: () => unawaited(flush()));
    ref.onDispose(() {
      lifecycle.dispose();
      _timer?.cancel();
    });
    final List<PendingConfirm> saved = PendingConfirms.decode(ref.watch(settingsStoreProvider).read(PendingConfirms.storageKey));
    if (saved.isNotEmpty) {
      _schedule();
      unawaited(Future<void>.microtask(flush));
    }
    return saved;
  }

  Future<void> _save(List<PendingConfirm> next) async {
    state = next;
    await ref.read(settingsStoreProvider).write(PendingConfirms.storageKey, PendingConfirms.encode(next));
    if (next.isEmpty) {
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => unawaited(flush()));
  }

  Future<void> add(String carpoolId, String runId) => _save(PendingConfirms.add(state, PendingConfirm(carpoolId, runId)));

  /// Sends what waits, oldest first; stops at the first "still offline".
  Future<void> flush() async {
    if (_flushing || state.isEmpty) {
      return;
    }
    _flushing = true;
    try {
      final ScheduleRepository repo = ref.read(scheduleRepositoryProvider);
      for (final PendingConfirm p in List<PendingConfirm>.of(state)) {
        try {
          await repo.confirmRun(p.carpoolId, p.runId);
        } on CarpoolFailure catch (f) {
          if (f.kind == CarpoolFailureKind.offline) {
            return;
          }
          // Refused for good (too late, no longer the driver): the run's
          // screen shows its real state; nothing to send again.
        }
        await _save(state.where((PendingConfirm x) => x != p).toList());
      }
    } on Object catch (error) {
      debugPrint('confirmation queue: ${error.runtimeType}');
    } finally {
      _flushing = false;
    }
  }
}

final NotifierProvider<ConfirmationQueue, List<PendingConfirm>> confirmationQueueProvider =
    NotifierProvider<ConfirmationQueue, List<PendingConfirm>>(ConfirmationQueue.new);
