import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_labels.dart';
import 'package:school_carpool/features/carpools/carpool_logic.dart';
import 'package:school_carpool/features/carpools/carpool_models.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/carpools/carpool_widgets.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/features/verification/verification_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

final _carpoolProvider = StreamProvider.autoDispose.family<Carpool?, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchCarpool(id),
);

final _myMembershipProvider = StreamProvider.autoDispose.family<Membership?, String>((Ref ref, String id) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<Membership?>.value(null);
  }
  return ref.watch(carpoolRepositoryProvider).watchMyMembership(id, session.uid);
});

final _membersProvider = StreamProvider.autoDispose.family<List<CarpoolMember>, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchMembers(id),
);

final _consentsProvider = StreamProvider.autoDispose.family<List<DriverConsent>, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchConsents(id),
);

final _requestsProvider = StreamProvider.autoDispose.family<List<JoinRequest>, String>(
  (Ref ref, String id) => ref.watch(carpoolRepositoryProvider).watchRequests(id),
);

/// Carpool detail (spec section 10): what anyone verified sees before
/// joining (school or activity, area, times, days, free seats, rules,
/// contribution, who started it), and for members the members with their
/// children's first names and grades, driver consent (F26), pickup point
/// sharing, join requests for the admin, Invite and Leave.
///
/// One primary action: Ask to join, or Invite parents for members.
/// States: loading (skeleton), not found (empty), error, offline; actions
/// show progress and a snackbar, and ask before anything that cannot be undone.
class CarpoolDetailScreen extends ConsumerStatefulWidget {
  const CarpoolDetailScreen({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  ConsumerState<CarpoolDetailScreen> createState() => _CarpoolDetailScreenState();
}

class _CarpoolDetailScreenState extends ConsumerState<CarpoolDetailScreen> {
  String? _busy;

  String get _id => widget.carpoolId;

  /// Runs [action] with the button [key] busy, then shows [done] or the failure.
  Future<bool> _run(String key, Future<void> Function() action, String done) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppLocalizations l10n = context.l10n;
    setState(() => _busy = key);
    try {
      await action();
      showAppSnackBarOn(messenger, done);
      return true;
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = null);
      }
    }
  }

  CarpoolRepository get _repo => ref.read(carpoolRepositoryProvider);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<Carpool?> carpool = ref.watch(_carpoolProvider(_id));
    final AsyncValue<Membership?> membership = ref.watch(_myMembershipProvider(_id));
    void reload() {
      ref
        ..invalidate(_carpoolProvider(_id))
        ..invalidate(_myMembershipProvider(_id));
    }

    final Object? error = carpool.error ?? membership.error;
    final Widget body;
    if (error != null) {
      body = carpoolErrorView(error, reload);
    } else if (!carpool.hasValue || !membership.hasValue) {
      body = const _DetailSkeleton();
    } else if (carpool.value == null) {
      body = EmptyStateView(
        key: const Key('detail.notFound'),
        icon: Icons.search_off_rounded,
        title: l10n.carpoolNotFoundTitle,
        body: l10n.carpoolErrorNotFound,
        actionLabel: l10n.tabCarpools,
        onAction: () => context.go(AppTab.carpools.path),
      );
    } else {
      body = _content(context, carpool.value!, membership.value);
    }
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.carpoolDetailTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _content(BuildContext context, Carpool c, Membership? m) {
    final AppLocalizations l10n = context.l10n;
    final String language = Localizations.localeOf(context).languageCode;
    final bool member = m?.status == MembershipStatus.approved;
    final bool requested = m?.status == MembershipStatus.requested;
    final bool admin = member && (m?.isAdmin ?? false);
    final Contribution? contribution = c.contribution;
    final String area = c.kind == CarpoolKind.activity ? c.activityLabel : c.areaName(language);
    final TextStyle? quiet = context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant);

    return ListView(
      key: const Key('detail.list'),
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, AppSpacing.s16, AppSpacing.screenGutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(header: true, child: Text(c.title(language), key: const Key('detail.title'), style: context.text.titleMedium)),
              if (area.isNotEmpty) Text(area, style: quiet),
              Text(l10n.carpoolStartedBy(c.creatorFirstName), style: quiet),
              if (!c.active) ...<Widget>[
                const SizedBox(height: AppSpacing.s16),
                AppInlineMessage(message: l10n.carpoolErrorClosed, tone: AppStateTone.warning),
              ],
            ],
          ),
        ),
        AppSectionHeader(l10n.carpoolTimesSection),
        if (c.morning != null)
          AppListRow(
            title: l10n.carpoolMorningAt(c.morning!),
            subtitle: l10n.carpoolMorningHelper,
            leadingIcon: Icons.wb_sunny_outlined,
            showChevron: false,
          ),
        if (c.afternoon != null)
          AppListRow(
            title: l10n.carpoolAfternoonAt(c.afternoon!),
            subtitle: l10n.carpoolAfternoonHelper,
            leadingIcon: Icons.wb_twilight_outlined,
            showChevron: false,
          ),
        AppListRow(
          title: daysText(l10n, c.days),
          subtitle: l10n.carpoolDaysLabel,
          leadingIcon: Icons.calendar_today_outlined,
          showChevron: false,
        ),
        AppSectionHeader(l10n.carpoolSeatsSection),
        AppListRow(
          key: const Key('detail.seats'),
          title: c.seatsLeft == 0 ? l10n.carpoolFull : l10n.carpoolSeatsLeft(c.seatsLeft),
          subtitle: l10n.carpoolSeatsOf(c.childrenCount, c.seats),
          leadingIcon: Icons.event_seat_outlined,
          showChevron: false,
        ),
        AppListRow(
          key: const Key('detail.contribution'),
          title: contribution == null ? l10n.contributionNone : contributionText(l10n, contribution),
          subtitle: contribution == null || contribution.note.isEmpty ? l10n.contributionHelper : contribution.note,
          leadingIcon: Icons.payments_outlined,
          showChevron: false,
        ),
        AppSectionHeader(l10n.carpoolRulesSection),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: c.rules.isEmpty ? Text(l10n.carpoolNoRules, style: quiet) : RulesWrap(rules: c.rules),
        ),
        if (member) _MembersSection(carpoolId: _id, busy: _busy, run: _run),
        if (admin) _RequestsSection(carpool: c, busy: _busy, run: _run),
        const SizedBox(height: AppSpacing.s32),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (member)
                AppButton(
                  key: const Key('detail.invite'),
                  label: l10n.inviteParents,
                  icon: Icons.share_outlined,
                  expand: true,
                  loading: _busy == 'invite',
                  onPressed: _busy != null || !c.active ? null : () => unawaited(_invite()),
                )
              else if (requested)
                AppButton(
                  key: const Key('detail.cancelRequest'),
                  label: l10n.carpoolCancelRequest,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  loading: _busy == 'cancel',
                  onPressed: _busy != null ? null : () => unawaited(_cancelRequest()),
                )
              else
                AppButton(
                  key: const Key('detail.join'),
                  label: l10n.carpoolAskToJoin,
                  icon: Icons.group_add_outlined,
                  expand: true,
                  loading: _busy == 'join',
                  onPressed: _busy != null || !c.active || c.seatsLeft == 0 ? null : () => unawaited(_join(c)),
                ),
              if (requested) ...<Widget>[
                const SizedBox(height: AppSpacing.s8),
                AppInlineMessage(key: const Key('detail.requestedNote'), message: l10n.carpoolRequestedNote),
              ],
              if (member) ...<Widget>[
                const SizedBox(height: AppSpacing.s8),
                AppButton(
                  key: const Key('detail.leave'),
                  label: l10n.carpoolLeave,
                  variant: AppButtonVariant.tertiary,
                  expand: true,
                  loading: _busy == 'leave',
                  onPressed: _busy != null ? null : () => unawaited(_leave()),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _join(Carpool c) async {
    List<ChildRecord> children;
    try {
      children = await ref.read(childrenProvider.future);
    } on Object {
      children = const <ChildRecord>[];
    }
    if (!mounted) {
      return;
    }
    final List<ChildRecord> eligible = <ChildRecord>[
      for (final ChildRecord child in children)
        if (child.status == ReviewStatus.approved && (c.kind == CarpoolKind.activity || child.schoolId == c.schoolId)) child,
    ];
    final _JoinChoice? choice = await showAppSheet<_JoinChoice>(
      context: context,
      title: context.l10n.carpoolAskToJoin,
      body: _JoinSheet(carpool: c, children: eligible),
    );
    if (choice == null || !mounted) {
      return;
    }
    await _run(
      'join',
      () => _repo.requestToJoin(carpoolId: c.id, childIds: choice.childIds, acceptContribution: choice.acceptContribution),
      context.l10n.carpoolRequestSent,
    );
  }

  Future<void> _cancelRequest() async {
    final AppLocalizations l10n = context.l10n;
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.carpoolCancelRequestTitle,
      body: l10n.carpoolCancelRequestBody,
      confirmLabel: l10n.carpoolCancelRequest,
      destructive: true,
    );
    if (sure && mounted) {
      await _run('cancel', () => _repo.cancelRequest(_id), l10n.carpoolRequestCancelled);
    }
  }

  Future<void> _leave() async {
    final AppLocalizations l10n = context.l10n;
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.carpoolLeaveTitle,
      body: l10n.carpoolLeaveBody,
      confirmLabel: l10n.carpoolLeave,
      destructive: true,
    );
    if (sure && mounted) {
      final bool left = await _run('leave', () => _repo.leave(_id), l10n.carpoolLeft);
      if (left && mounted) {
        context.go(AppTab.carpools.path);
      }
    }
  }

  Future<void> _invite() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    CarpoolInvite? invite;
    setState(() => _busy = 'invite');
    try {
      invite = await _repo.createInvite(_id);
    } on CarpoolFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _busy = null);
      }
    }
    final CarpoolInvite? link = invite;
    if (link == null || !mounted) {
      return;
    }
    await showAppSheet<void>(
      context: context,
      title: l10n.inviteParents,
      body: _InviteSheet(invite: link, messenger: messenger),
    );
  }
}

/// Members, driver consent (F26) and the pickup point; approved members only.
class _MembersSection extends ConsumerWidget {
  const _MembersSection({required this.carpoolId, required this.busy, required this.run});

  final String carpoolId;
  final String? busy;
  final Future<bool> Function(String key, Future<void> Function() action, String done) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<CarpoolMember>> membersValue = ref.watch(_membersProvider(carpoolId));
    final AsyncValue<List<DriverConsent>> consentsValue = ref.watch(_consentsProvider(carpoolId));
    final SessionState session = ref.watch(sessionProvider);
    final String uid = session is SessionSignedIn ? session.uid : '';
    final Object? error = membersValue.error ?? consentsValue.error;
    if (error != null) {
      return Padding(
        padding: AppSpacing.screenPadding,
        child: AppInlineMessage(message: CarpoolFailure.from(error).message(l10n), tone: AppStateTone.error),
      );
    }
    final List<CarpoolMember>? members = membersValue.value;
    final List<DriverConsent>? consents = consentsValue.value;
    if (members == null || consents == null) {
      return const Skeleton(child: Column(children: <Widget>[SkeletonListRow(), SkeletonListRow()]));
    }
    final DateTime today = DateTime.now();
    final CarpoolMember? me = members.where((CarpoolMember m) => m.uid == uid).firstOrNull;
    final Set<String> accepted = acceptedConsentKeys(consents);
    final List<CarpoolMember> others = members.where((CarpoolMember m) => m.uid != uid).toList();
    final CarpoolRepository repo = ref.read(carpoolRepositoryProvider);

    Future<void> toggleConsent(CarpoolMember driver, bool accept) async {
      final bool sure = await showConfirmDialog(
        context: context,
        title: accept ? l10n.consentAcceptTitle(driver.firstName) : l10n.consentWithdrawTitle,
        body: accept ? l10n.consentAcceptBody(driver.firstName) : l10n.consentWithdrawBody(driver.firstName),
        confirmLabel: accept ? l10n.consentAccept : l10n.consentWithdraw,
        destructive: !accept,
      );
      if (sure) {
        await run(
          'consent.${driver.uid}',
          () => repo.setConsent(carpoolId: carpoolId, driverUid: driver.uid, accept: accept),
          accept ? l10n.consentAccepted : l10n.consentWithdrawn,
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.carpoolMembersSection),
        for (final CarpoolMember m in members)
          AppListRow(
            key: Key('detail.member.${m.uid}'),
            title: m.uid == uid ? l10n.carpoolYou(m.firstName) : m.firstName,
            subtitle: m.children.isEmpty ? l10n.carpoolNoChildren : childrenText(l10n, m.children),
            leadingIcon: m.isAdmin ? Icons.star_outline_rounded : Icons.person_outline_rounded,
            showChevron: false,
            trailing: _DriverBadge(status: driverStatus(m, members, consents, today)),
          ),
        if (me != null && me.children.isNotEmpty && others.isNotEmpty) ...<Widget>[
          AppSectionHeader(l10n.consentSection),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s8),
            child: Text(l10n.consentIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          ),
          for (final CarpoolMember driver in others)
            AppSwitchRow(
              key: Key('detail.consent.${driver.uid}'),
              title: driver.firstName,
              subtitle: accepted.contains('${uid}_${driver.uid}') ? l10n.consentOnHelper : l10n.consentOffHelper,
              value: accepted.contains('${uid}_${driver.uid}'),
              onChanged: busy != null ? null : (bool on) => unawaited(toggleConsent(driver, on)),
            ),
        ],
        if (me != null) ...<Widget>[
          AppSectionHeader(l10n.pickupSection),
          AppSwitchRow(
            key: const Key('detail.pickup'),
            title: l10n.pickupShare,
            subtitle: me.pickupShared ? l10n.pickupSharedHelper : l10n.pickupNotSharedHelper,
            value: me.pickupShared,
            onChanged: busy != null
                ? null
                : (bool on) => unawaited(
                    run(
                      'pickup',
                      () => repo.setPickupSharing(carpoolId: carpoolId, share: on),
                      on ? l10n.pickupShared : l10n.pickupStopped,
                    ),
                  ),
          ),
        ],
      ],
    );
  }
}

/// What a member's driving looks like now (F26 and seats).
class _DriverBadge extends StatelessWidget {
  const _DriverBadge({required this.status});

  final DriverStatus status;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String label, AppBadgeTone tone) = switch (status) {
      DriverStatus(canDrive: true) => (l10n.driverCanDrive, AppBadgeTone.success),
      DriverStatus(problem: DriverProblem.noCar) => (l10n.driverNoCar, AppBadgeTone.neutral),
      DriverStatus(problem: DriverProblem.carExpired) => (l10n.driverCarExpired, AppBadgeTone.error),
      DriverStatus(problem: DriverProblem.carTooSmall) => (l10n.driverCarTooSmall, AppBadgeTone.warning),
      _ => (l10n.driverNeedsConsent, AppBadgeTone.warning),
    };
    return AppStatusBadge(label: label, tone: tone);
  }
}

/// Join requests (F6), for the admin: children's first names and grades,
/// and whether the parent has a car. Approve or Decline (asks first).
class _RequestsSection extends ConsumerWidget {
  const _RequestsSection({required this.carpool, required this.busy, required this.run});

  final Carpool carpool;
  final String? busy;
  final Future<bool> Function(String key, Future<void> Function() action, String done) run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<JoinRequest>> requests = ref.watch(_requestsProvider(carpool.id));
    final CarpoolRepository repo = ref.read(carpoolRepositoryProvider);
    final List<JoinRequest> list = requests.value ?? const <JoinRequest>[];

    Future<void> decide(JoinRequest r, bool approve) async {
      if (!approve) {
        final bool sure = await showConfirmDialog(
          context: context,
          title: l10n.requestDeclineTitle,
          body: l10n.requestDeclineBody(r.firstName),
          confirmLabel: l10n.requestDecline,
          destructive: true,
        );
        if (!sure) {
          return;
        }
      }
      await run(
        'decide.${r.uid}',
        () => repo.decide(carpoolId: carpool.id, uid: r.uid, approve: approve),
        approve ? l10n.requestApproved : l10n.requestDeclined,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.requestsSection),
        if (requests.hasError)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: AppInlineMessage(message: CarpoolFailure.from(requests.error!).message(l10n), tone: AppStateTone.error),
          )
        else if (requests.isLoading && !requests.hasValue)
          const Skeleton(child: SkeletonListRow())
        else if (list.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Text(
              l10n.requestsEmpty,
              key: const Key('detail.requestsEmpty'),
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        for (final JoinRequest r in list)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(AppSpacing.screenGutter, 0, AppSpacing.screenGutter, AppSpacing.s16),
            child: AppCard(
              key: Key('detail.request.${r.uid}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  OneLineText(r.firstName, style: context.text.titleSmall),
                  Text(childrenText(l10n, r.children), style: context.text.bodyMedium),
                  Text(
                    r.hasCar ? l10n.requestHasCar : l10n.requestNoCar,
                    style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  if (r.children.length > carpool.seatsLeft) ...<Widget>[
                    const SizedBox(height: AppSpacing.s8),
                    AppInlineMessage(message: l10n.carpoolErrorNoSeats, tone: AppStateTone.warning),
                  ],
                  const SizedBox(height: AppSpacing.s16),
                  AppButton(
                    key: Key('detail.approve.${r.uid}'),
                    label: l10n.requestApprove,
                    variant: AppButtonVariant.secondary,
                    expand: true,
                    loading: busy == 'decide.${r.uid}',
                    onPressed: busy != null || r.children.length > carpool.seatsLeft ? null : () => unawaited(decide(r, true)),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  AppButton(
                    key: Key('detail.decline.${r.uid}'),
                    label: l10n.requestDecline,
                    variant: AppButtonVariant.tertiary,
                    expand: true,
                    onPressed: busy != null ? null : () => unawaited(decide(r, false)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _JoinChoice {
  const _JoinChoice(this.childIds, {required this.acceptContribution});

  final List<String> childIds;
  final bool acceptContribution;
}

/// Ask to join (F6): which children ride, and accepting the rules (F36)
/// and the contribution (F25). Checks the free seats as the parent picks.
class _JoinSheet extends StatefulWidget {
  const _JoinSheet({required this.carpool, required this.children});

  final Carpool carpool;
  final List<ChildRecord> children;

  @override
  State<_JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<_JoinSheet> {
  final Set<String> _picked = <String>{};
  bool _rules = false;
  bool _contribution = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final Carpool c = widget.carpool;
    final Contribution? contribution = c.contribution;
    if (widget.children.isEmpty) {
      return AppInlineMessage(key: const Key('join.noChildren'), message: l10n.joinNoChildren, tone: AppStateTone.warning);
    }
    final bool fits = fitsSeats(_picked.length, c.seatsLeft);
    final String? seatError = _picked.length > c.seatsLeft ? l10n.joinTooManyChildren(c.seatsLeft) : null;
    final bool ready = fits && _rules && (contribution == null || _contribution);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.joinChildrenIntro, style: context.text.bodyMedium),
        for (final ChildRecord child in widget.children)
          AppCheckRow(
            key: Key('join.child.${child.id}'),
            label: l10n.childWithGrade(child.firstName, gradeLabel(l10n, child.grade)),
            value: _picked.contains(child.id),
            onChanged: (bool on) => setState(() => on ? _picked.add(child.id) : _picked.remove(child.id)),
          ),
        if (seatError != null) AppInlineMessage(key: const Key('join.seatError'), message: seatError, tone: AppStateTone.error),
        const SizedBox(height: AppSpacing.s16),
        if (c.rules.isNotEmpty) ...<Widget>[RulesWrap(rules: c.rules), const SizedBox(height: AppSpacing.s8)],
        AppCheckRow(
          key: const Key('join.rules'),
          label: c.rules.isEmpty ? l10n.joinAcceptNoRules : l10n.joinAcceptRules,
          value: _rules,
          onChanged: (bool on) => setState(() => _rules = on),
        ),
        if (contribution != null)
          AppCheckRow(
            key: const Key('join.contribution'),
            label: l10n.joinAcceptContribution(contributionText(l10n, contribution)),
            helperText: l10n.contributionHelper,
            value: _contribution,
            onChanged: (bool on) => setState(() => _contribution = on),
          ),
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('join.send'),
          label: l10n.joinSend,
          expand: true,
          onPressed: ready
              ? () => Navigator.of(context).pop(_JoinChoice(_picked.toList(), acceptContribution: contribution != null))
              : null,
        ),
      ],
    );
  }
}

/// The invite link (F31) with Share on WhatsApp and Copy link.
class _InviteSheet extends ConsumerWidget {
  const _InviteSheet({required this.invite, required this.messenger});

  final CarpoolInvite invite;
  final ScaffoldMessengerState messenger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final LinkSharer sharer = ref.read(linkSharerProvider);
    final String message = l10n.inviteMessage(invite.url);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(l10n.inviteIntro, style: context.text.bodyMedium),
        const SizedBox(height: AppSpacing.s16),
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(invite.url, key: const Key('invite.url'), style: context.text.bodyLarge),
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('invite.whatsapp'),
          label: l10n.inviteWhatsApp,
          icon: Icons.chat_outlined,
          expand: true,
          onPressed: () async {
            final bool opened = await sharer.shareOnWhatsApp(message);
            if (!opened) {
              await sharer.copy(invite.url);
              showAppSnackBarOn(messenger, l10n.inviteCopiedNoWhatsApp);
            }
          },
        ),
        const SizedBox(height: AppSpacing.s8),
        AppButton(
          key: const Key('invite.copy'),
          label: l10n.inviteCopy,
          icon: Icons.copy_rounded,
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: () async {
            await sharer.copy(invite.url);
            showAppSnackBarOn(messenger, l10n.copiedToClipboard);
          },
        ),
      ],
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) => const Skeleton(
    child: Padding(
      padding: AppSpacing.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SkeletonBox(height: AppSpacing.s24, width: AppSpacing.s64 * 3),
          SizedBox(height: AppSpacing.s16),
          SkeletonListRow(),
          SkeletonListRow(),
          SkeletonListRow(),
          SizedBox(height: AppSpacing.s16),
          SkeletonCard(),
        ],
      ),
    ),
  );
}
