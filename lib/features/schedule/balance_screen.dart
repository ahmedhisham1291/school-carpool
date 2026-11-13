import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/schedule/schedule_logic.dart';
import 'package:school_carpool/features/schedule/schedule_models.dart';
import 'package:school_carpool/features/schedule/schedule_repository.dart';
import 'package:school_carpool/features/schedule/schedule_screen.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _balanceProvider = StreamProvider.autoDispose.family<DriveBalance?, (String, String)>(
  (Ref ref, (String, String) key) => ref.watch(scheduleRepositoryProvider).watchBalance(key.$1, key.$2),
);

final _membersProvider = StreamProvider.autoDispose.family<List<CarpoolMember>, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchMembers(id),
);

/// Drive balance (F37): runs each family drove and received this term.
/// Families furthest behind their fair share come first (fair shares follow
/// the number of children); the family that drove least has a badge and is
/// offered more runs by the rotation and swaps.
///
/// States: loading (skeleton), no runs yet (a note above the families),
/// error and offline (retry). Read only: no actions.
class BalanceScreen extends ConsumerWidget {
  const BalanceScreen({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String termId = ScheduleDates.termId(ref.watch(scheduleClockProvider)());
    final (String, String) key = (carpoolId, termId);
    final AsyncValue<DriveBalance?> balance = ref.watch(_balanceProvider(key));
    final AsyncValue<List<CarpoolMember>> members = ref.watch(_membersProvider(carpoolId));
    final String uid = signedInUid(ref);
    void reload() {
      ref
        ..invalidate(_balanceProvider(key))
        ..invalidate(_membersProvider(carpoolId));
    }

    final Object? error = balance.error ?? members.error;
    final Widget body;
    if (error != null) {
      body = carpoolErrorView(error, reload);
    } else if (!balance.hasValue || !members.hasValue) {
      body = const ScheduleSkeleton();
    } else {
      final List<CarpoolMember> people = members.value!;
      final List<FamilyBalance> rows = balanceOrder(balance.value, people);
      final String? least = droveLeast(balance.value, people);
      final bool none = rows.every((FamilyBalance f) => f.driven == 0 && f.received == 0);
      final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);
      body = ListView(
        key: const Key('balance.list'),
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
            child: Text(l10n.balanceIntro, style: quiet),
          ),
          if (none)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
              child: AppInlineMessage(key: const Key('balance.none'), message: l10n.balanceEmptyBody),
            ),
          AppSectionHeader(l10n.balanceTerm),
          for (final FamilyBalance f in rows)
            AppListRow(
              key: Key('balance.${f.uid}'),
              title: f.uid == uid ? l10n.carpoolYou(f.firstName) : f.firstName,
              subtitle: l10n.balanceRow(f.driven, f.received),
              leadingIcon: Icons.family_restroom_outlined,
              showChevron: false,
              trailing: f.uid == least ? AppStatusBadge(label: l10n.balanceLeast, tone: AppBadgeTone.success) : null,
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.scheduleBalance)),
      body: SafeArea(top: false, child: body),
    );
  }
}
