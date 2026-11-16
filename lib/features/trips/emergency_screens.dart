import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/about/legal_links.dart';
import 'package:school_carpool/features/auth/phone_number.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/carpools/carpool_repository.dart';
import 'package:school_carpool/features/maps/geo.dart';
import 'package:school_carpool/features/maps/map_view.dart';
import 'package:school_carpool/features/schedule/schedule_labels.dart';
import 'package:school_carpool/features/trips/trip_logic.dart';
import 'package:school_carpool/features/trips/trip_models.dart';
import 'package:school_carpool/features/trips/trip_repository.dart';
import 'package:school_carpool/features/trips/trip_widgets.dart';
import 'package:school_carpool/l10n/l10n.dart';

final _contactProvider = StreamProvider.autoDispose<EmergencyContact?>((Ref ref) {
  final SessionState session = ref.watch(sessionProvider);
  if (session is! SessionSignedIn) {
    return Stream<EmergencyContact?>.value(null);
  }
  return ref.watch(tripRepositoryProvider).watchEmergencyContact(session.uid);
});

/// F20: the person who gets a WhatsApp message with the car's location
/// when the driver presses Emergency. Name, mobile number and relation;
/// checked as the parent types. Removing asks first.
///
/// R6 (docs/legal/answers.md 1.8): saving needs the box "this person
/// agreed to be my emergency contact" (unticked each time). Once saved, a
/// status line says whether the contact confirmed, is still asked, or
/// asked for no messages, and "Send the link" opens WhatsApp with a short
/// note and the contact's confirm / stop link (sent from the parent's own
/// phone). Until confirmed, alerts still go; the first one introduces the
/// parent and says how to stop.
///
/// States: loading (skeleton), none saved yet (empty form), error, offline.
class EmergencyContactScreen extends ConsumerStatefulWidget {
  const EmergencyContactScreen({super.key});

  static const String path = '/profile/emergency-contact';

  @override
  ConsumerState<EmergencyContactScreen> createState() => _EmergencyContactScreenState();
}

class _EmergencyContactScreenState extends ConsumerState<EmergencyContactScreen> {
  String? _name;
  String? _phone;
  Relation? _relation;
  bool _agreed = false;
  bool _saving = false;

  Future<void> _save(EmergencyContact? current) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String name = (_name ?? current?.name ?? '').trim();
    final String phone = (_phone ?? current?.phone ?? '').trim();
    final Relation? relation = _relation ?? current?.relation;
    if (relation == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(tripRepositoryProvider).saveEmergencyContact(name: name, phone: phone, relation: relation, agreed: _agreed);
      if (mounted) {
        setState(() => _agreed = false);
      }
      showAppSnackBarOn(messenger, l10n.emergencyContactSaved);
    } on TripFailure catch (failure) {
      showAppSnackBarOn(messenger, failure.message(l10n));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// R6: WhatsApp with a short note and the confirm / stop link.
  Future<void> _sendLink(EmergencyContact current) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Uri? link = ref.read(legalLinksProvider).contactLink(current.token);
    if (link == null) {
      showAppSnackBarOn(messenger, l10n.emergencyContactNoLink);
      return;
    }
    final bool opened = await ref.read(linkSharerProvider).shareOnWhatsApp(l10n.emergencyContactShareText(link.toString()));
    if (!opened) {
      await ref.read(linkSharerProvider).copy(link.toString());
      showAppSnackBarOn(messenger, l10n.emergencyContactLinkCopied);
    }
  }

  Future<void> _clear() async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool sure = await showConfirmDialog(
      context: context,
      title: l10n.emergencyContactRemoveTitle,
      body: l10n.emergencyContactRemoveBody,
      confirmLabel: l10n.emergencyContactRemove,
      destructive: true,
    );
    if (!sure || !mounted) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(tripRepositoryProvider).clearEmergencyContact();
      if (mounted) {
        setState(() {
          _name = null;
          _phone = null;
          _relation = null;
        });
      }
      showAppSnackBarOn(messenger, l10n.emergencyContactRemoved);
    } on TripFailure catch (failure) {
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
    final AsyncValue<EmergencyContact?> contact = ref.watch(_contactProvider);
    final Widget body = contact.when(
      loading: () => const Skeleton(child: Padding(padding: AppSpacing.screenPadding, child: SkeletonCard())),
      error: (Object error, StackTrace _) => TripFailure.from(error).isOffline
          ? OfflineStateView(onRetry: () => ref.invalidate(_contactProvider))
          : ErrorStateView(onRetry: () => ref.invalidate(_contactProvider)),
      data: (EmergencyContact? current) => _form(context, current),
    );
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.emergencyContactTitle)),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _form(BuildContext context, EmergencyContact? current) {
    final AppLocalizations l10n = context.l10n;
    final String name = _name ?? current?.name ?? '';
    final String phone = _phone ?? current?.phone ?? '';
    final Relation? relation = _relation ?? current?.relation;
    final bool nameOk = validPersonName(name);
    final bool phoneOk = EgyptPhone.isValid(phone);
    return ListView(
      key: ValueKey<String>('contact.${current?.phone ?? 'none'}'),
      padding: AppSpacing.screenPadding,
      children: <Widget>[
        Text(l10n.emergencyContactIntro, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
        const SizedBox(height: AppSpacing.s24),
        AppTextField(
          key: const Key('contact.name'),
          label: l10n.handoverNameLabel,
          initialValue: current?.name,
          errorText: name.isEmpty || nameOk ? null : l10n.handoverNameError,
          onChanged: (String v) => setState(() => _name = v),
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('contact.phone'),
          label: l10n.emergencyContactPhoneLabel,
          helperText: l10n.emergencyContactPhoneHelper,
          initialValue: current == null ? null : EgyptPhone.display(current.phone),
          errorText: phone.isEmpty || phoneOk ? null : l10n.handoverPhoneError,
          keyboardType: TextInputType.phone,
          onChanged: (String v) => setState(() => _phone = v),
        ),
        const SizedBox(height: AppSpacing.s16),
        Semantics(header: true, child: OneLineText(l10n.handoverRelationLabel, style: context.text.labelLarge)),
        const SizedBox(height: AppSpacing.s8),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s8,
          children: <Widget>[
            for (final Relation r in Relation.values)
              AppChip(
                key: Key('contact.relation.${r.name}'),
                label: relationLabel(l10n, r),
                selected: relation == r,
                onSelected: (bool _) => setState(() => _relation = r),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.s16),
        AppCheckRow(
          key: const Key('contact.agreed'),
          label: l10n.emergencyContactAgreeLabel,
          helperText: l10n.emergencyContactAgreeHelper,
          value: _agreed,
          onChanged: _saving ? null : (bool v) => setState(() => _agreed = v),
        ),
        const SizedBox(height: AppSpacing.s24),
        AppButton(
          key: const Key('contact.save'),
          label: l10n.actionSave,
          expand: true,
          loading: _saving,
          onPressed: !_saving && nameOk && phoneOk && relation != null && _agreed ? () => unawaited(_save(current)) : null,
        ),
        if (current != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(
            key: Key('contact.status.${current.status.name}'),
            tone: switch (current.status) {
              ContactStatus.confirmed => AppStateTone.neutral,
              ContactStatus.stopped => AppStateTone.warning,
              ContactStatus.pending => AppStateTone.neutral,
            },
            message: switch (current.status) {
              ContactStatus.confirmed => l10n.emergencyContactConfirmed(current.name),
              ContactStatus.stopped => l10n.emergencyContactStopped(current.name),
              ContactStatus.pending => l10n.emergencyContactPending(current.name),
            },
          ),
          if (current.status == ContactStatus.pending) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              key: const Key('contact.sendLink'),
              label: l10n.emergencyContactSendLink,
              icon: Icons.send_rounded,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: _saving ? null : () => unawaited(_sendLink(current)),
            ),
          ],
        ],
        if (current != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s8),
          AppButton(
            key: const Key('contact.remove'),
            label: l10n.emergencyContactRemove,
            variant: AppButtonVariant.tertiary,
            expand: true,
            onPressed: _saving ? null : () => unawaited(_clear()),
          ),
        ],
      ],
    );
  }
}

final _emergenciesProvider = StreamProvider.autoDispose.family<List<EmergencyAlert>, String>(
  (Ref ref, String carpoolId) => ref.watch(tripRepositoryProvider).watchEmergencies(carpoolId),
);

/// F20: the group's emergency alerts of the last 24 hours, with where the
/// car was. Calls the ambulance (123) or opens the point in the maps app.
///
/// States: loading (skeleton), none (empty), error, offline.
class EmergencyScreen extends ConsumerWidget {
  const EmergencyScreen({required this.carpoolId, super.key});

  final String carpoolId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<EmergencyAlert>> alerts = ref.watch(_emergenciesProvider(carpoolId));
    final TripRepository repo = ref.read(tripRepositoryProvider);
    final Widget body = alerts.when(
      loading: () => const Skeleton(child: Padding(padding: AppSpacing.screenPadding, child: SkeletonCard())),
      error: (Object error, StackTrace _) => TripFailure.from(error).isOffline
          ? OfflineStateView(onRetry: () => ref.invalidate(_emergenciesProvider(carpoolId)))
          : ErrorStateView(onRetry: () => ref.invalidate(_emergenciesProvider(carpoolId))),
      data: (List<EmergencyAlert> list) => list.isEmpty
          ? EmptyStateView(key: const Key('emergency.empty'), icon: Icons.health_and_safety_outlined, title: l10n.emergencyNoneTitle, body: l10n.emergencyNoneBody)
          : ListView(
              padding: AppSpacing.screenPadding,
              children: <Widget>[
                for (final EmergencyAlert a in list) ...<Widget>[
                  _AlertCard(alert: a, onOpenMap: (Uri uri) => unawaited(repo.openExternal(uri))),
                  const SizedBox(height: AppSpacing.s16),
                ],
                AppButton(
                  key: const Key('emergency.call'),
                  label: l10n.emergencyCallAmbulance,
                  icon: Icons.call_rounded,
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.large,
                  expand: true,
                  onPressed: () => unawaited(repo.openExternal(Uri(scheme: 'tel', path: '123'))),
                ),
              ],
            ),
    );
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.emergencyTitle)),
      body: SafeArea(top: false, child: body),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onOpenMap});

  final EmergencyAlert alert;
  final ValueChanged<Uri> onOpenMap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final GeoPin? point = alert.point;
    return AppCard(
      key: Key('emergency.${alert.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OneLineText(l10n.emergencyFrom(alert.driverFirstName), style: context.text.titleMedium),
          Text(deadlineText(context, alert.at), style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          if (point != null) ...<Widget>[
            const SizedBox(height: AppSpacing.s16),
            SizedBox(height: AppSpacing.s64 * 3, child: _PointMap(point: point, label: l10n.tripCarPinLabel(alert.driverFirstName))),
            const SizedBox(height: AppSpacing.s8),
            AppButton(
              key: Key('emergency.map.${alert.id}'),
              label: l10n.emergencyOpenMap,
              icon: Icons.map_outlined,
              variant: AppButtonVariant.tertiary,
              expand: true,
              onPressed: () => onOpenMap(Uri.https('maps.google.com', '/', <String, String>{'q': '${point.lat},${point.lng}'})),
            ),
          ] else
            Text(l10n.emergencyNoPoint, style: context.text.bodyMedium),
        ],
      ),
    );
  }
}

/// A small map with one pin; owns its camera.
class _PointMap extends StatefulWidget {
  const _PointMap({required this.point, required this.label});

  final GeoPin point;
  final String label;

  @override
  State<_PointMap> createState() => _PointMapState();
}

class _PointMapState extends State<_PointMap> {
  late final MapCameraController _camera = MapCameraController(center: widget.point, zoom: AppMapTokens.streetZoom);

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppMapView(
    config: MapViewConfig(
      camera: _camera,
      semanticLabel: context.l10n.emergencyMapLabel,
      markers: <MapMarker>[MapMarker(id: 'car', at: widget.point, kind: MapMarkerKind.car, label: widget.label)],
    ),
  );
}
