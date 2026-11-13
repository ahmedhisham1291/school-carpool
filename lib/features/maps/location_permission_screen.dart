import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Shown before the system's location prompt (and when it was refused for
/// good): what we use the location for, and that others only see an area
/// of about 500 m. Returns true when the parent taps the main button.
///
/// Static screen: no loading, empty, error or offline state.
class LocationPermissionScreen extends StatelessWidget {
  const LocationPermissionScreen({required this.blocked, super.key});

  /// Refused for good: the button opens the phone's Settings.
  final bool blocked;

  static Future<bool> open(BuildContext context, {required bool blocked}) async {
    final bool? go = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (BuildContext context) => LocationPermissionScreen(blocked: blocked)),
    );
    return go ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.locationPermissionTitle)),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                padding: AppSpacing.screenPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: AppSpacing.s32),
                    Icon(Icons.my_location_rounded, size: AppIconSize.xl, color: context.colors.onSurfaceVariant),
                    const SizedBox(height: AppSpacing.s24),
                    Semantics(
                      header: true,
                      child: Text(l10n.locationPermissionHeading, style: context.text.titleMedium),
                    ),
                    const SizedBox(height: AppSpacing.s8),
                    Text(
                      blocked ? l10n.locationPermissionBlockedBody : l10n.locationPermissionBody,
                      style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: AppSpacing.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AppButton(
                    key: const Key('location.continue'),
                    label: blocked ? l10n.locationOpenSettings : l10n.actionContinue,
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  AppButton(
                    key: const Key('location.notNow'),
                    label: l10n.locationNotNow,
                    variant: AppButtonVariant.tertiary,
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
