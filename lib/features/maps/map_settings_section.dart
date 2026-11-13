import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/auth/session.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Settings (spec section 6 and 10): hide me from the nearby map, and
/// new-parent alerts on or off. Saved at once through updateMapSettings;
/// the switch moves right away and goes back if saving fails.
///
/// Shown only when signed in. While the settings load, the switches show
/// the defaults (on) and are disabled; on an error they stay disabled.
class MapSettingsSection extends ConsumerStatefulWidget {
  const MapSettingsSection({super.key});

  @override
  ConsumerState<MapSettingsSection> createState() => _MapSettingsSectionState();
}

class _MapSettingsSectionState extends ConsumerState<MapSettingsSection> {
  bool? _showOnMap;
  bool? _notify;
  bool _saving = false;

  Future<void> _set({bool? showOnMap, bool? notify}) async {
    final AppLocalizations l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? beforeShow = _showOnMap;
    final bool? beforeNotify = _notify;
    setState(() {
      _saving = true;
      _showOnMap = showOnMap ?? _showOnMap;
      _notify = notify ?? _notify;
    });
    try {
      await ref.read(mapRepositoryProvider).updateSettings(showOnMap: showOnMap, notifyNewParents: notify);
      showAppSnackBarOn(messenger, l10n.settingsSaved);
    } on MapFailure catch (failure) {
      if (mounted) {
        setState(() {
          _showOnMap = beforeShow;
          _notify = beforeNotify;
        });
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
    if (ref.watch(sessionProvider) is! SessionSignedIn) {
      return const SizedBox.shrink();
    }
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HomeLocation?> home = ref.watch(myHomeProvider);
    final HomeLocation settings = home.value ?? const HomeLocation();
    final bool ready = home.hasValue && !_saving;
    final bool show = _showOnMap ?? settings.showOnMap;
    final bool notify = _notify ?? settings.notifyNewParents;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(l10n.settingsMapSection),
        AppSwitchRow(
          key: const Key('settings.showOnMap'),
          title: l10n.settingsShowOnMap,
          subtitle: show ? l10n.settingsShowOnMapOn : l10n.settingsShowOnMapOff,
          leadingIcon: Icons.visibility_outlined,
          value: show,
          onChanged: ready ? (bool v) => unawaited(_set(showOnMap: v)) : null,
        ),
        AppSwitchRow(
          key: const Key('settings.newParentAlerts'),
          title: l10n.settingsNewParentAlerts,
          subtitle: l10n.settingsNewParentAlertsHelper,
          leadingIcon: Icons.notifications_active_outlined,
          value: notify,
          onChanged: ready ? (bool v) => unawaited(_set(notify: v)) : null,
        ),
      ],
    );
  }
}
