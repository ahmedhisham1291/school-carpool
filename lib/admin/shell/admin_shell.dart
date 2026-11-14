import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/auth/idle_timeout.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/settings/app_settings.dart';

/// One section of the panel in the navigation rail.
class AdminSection {
  const AdminSection(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String Function(AppLocalizations l10n) label;
}

List<AdminSection> adminSections({required bool superAdmin}) => <AdminSection>[
  AdminSection(AdminRoutes.queue, Icons.fact_check_outlined, Icons.fact_check, (AppLocalizations l) => l.adminNavQueue),
  AdminSection(AdminRoutes.users, Icons.people_outline, Icons.people, (AppLocalizations l) => l.adminNavUsers),
  AdminSection(AdminRoutes.schools, Icons.school_outlined, Icons.school, (AppLocalizations l) => l.adminNavSchools),
  AdminSection(
    AdminRoutes.otherSchools,
    Icons.add_location_alt_outlined,
    Icons.add_location_alt,
    (AppLocalizations l) => l.adminNavOther,
  ),
  AdminSection(AdminRoutes.reports, Icons.flag_outlined, Icons.flag, (AppLocalizations l) => l.adminNavReports),
  AdminSection(
    AdminRoutes.wallets,
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet,
    (AppLocalizations l) => l.adminNavWallet,
  ),
  AdminSection(AdminRoutes.trust, Icons.shield_outlined, Icons.shield, (AppLocalizations l) => l.adminNavTrust),
  AdminSection(AdminRoutes.audit, Icons.history_outlined, Icons.history, (AppLocalizations l) => l.adminNavAudit),
  if (superAdmin)
    AdminSection(
      AdminRoutes.admins,
      Icons.admin_panel_settings_outlined,
      Icons.admin_panel_settings,
      (AppLocalizations l) => l.adminNavAdmins,
    ),
];

/// The panel frame: a navigation rail (sections, language, theme, sign
/// out) and the current page. Signs out after 15 idle minutes.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  /// How often an active admin tells the server (15-minute idle limit there).
  static const Duration pingEvery = Duration(minutes: 5);

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  DateTime? _lastPing;

  Future<void> _signOut(AdminSignOutReason? reason) async {
    ref.read(adminSignOutReasonProvider.notifier).set(reason);
    await ref.read(adminAuthRepositoryProvider).signOut();
  }

  void _activity() {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastPing;
    if (last != null && now.difference(last) < AdminShell.pingEvery) {
      return;
    }
    _lastPing = now;
    unawaited(_ping());
  }

  Future<void> _ping() async {
    try {
      await ref.read(adminApiProvider).ping();
    } on AdminFailure catch (failure) {
      if (failure.kind == AdminFailureKind.sessionExpired || failure.kind == AdminFailureKind.notAdmin) {
        await _signOut(AdminSignOutReason.expired);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final String location = widget.location;
    final AppLocalizations l10n = context.l10n;
    final AdminUser? user = adminUserOf(ref.watch(adminSessionProvider));
    final List<AdminSection> sections = adminSections(superAdmin: user?.isSuperAdmin ?? false);
    final int index = sections.indexWhere((AdminSection s) => location.startsWith(s.path));

    return IdleTimeout(
      timeout: kAdminIdleTimeout,
      onTimeout: () => unawaited(_signOut(AdminSignOutReason.idle)),
      onActivity: _activity,
      child: Scaffold(
        body: SafeArea(
          child: Row(
            children: <Widget>[
              // Labels stay on one line: text scale is clamped in the rail
              // only (like the app's bottom bar), and a label that is still
              // too wide scales down, never wraps (docs/DESIGN.md).
              // Prompt 11: with every section the rail can be taller than
              // the window; it then scrolls instead of overflowing.
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
                  key: const Key('admin.railScroll'),
                  child: SizedBox(
                    height: math.max(box.maxHeight.isFinite ? box.maxHeight : 0, _railHeight(sections.length)),
                    child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: AppTypeScale.maxNavTextScale,
                child: NavigationRail(
                  selectedIndex: index < 0 ? null : index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (int i) => context.go(sections[i].path),
                  leading: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(vertical: AppSpacing.s16),
                    child: Tooltip(
                      message: user?.displayName ?? l10n.adminPanelTitle,
                      child: CircleAvatar(
                        backgroundColor: context.colors.primaryContainer,
                        foregroundColor: context.colors.onPrimaryContainer,
                        child: OneLineText(_initial(user?.displayName ?? l10n.adminPanelTitle)),
                      ),
                    ),
                  ),
                  destinations: <NavigationRailDestination>[
                    for (final AdminSection s in sections)
                      NavigationRailDestination(
                        icon: Icon(s.icon),
                        selectedIcon: Icon(s.selectedIcon),
                        label: OneLineText(s.label(l10n), scaleDown: true),
                      ),
                  ],
                  trailingAtBottom: true,
                  trailing: Padding(
                    padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        IconButton(
                          key: const Key('admin.language'),
                          tooltip: l10n.settingsLanguage,
                          icon: const Icon(Icons.translate),
                          onPressed: () => unawaited(ref.read(localeProvider.notifier).toggle()),
                        ),
                        IconButton(
                          key: const Key('admin.theme'),
                          tooltip: l10n.settingsTheme,
                          icon: Icon(
                            Theme.of(context).brightness == Brightness.dark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                          ),
                          onPressed: () => unawaited(
                            ref
                                .read(themeModeProvider.notifier)
                                .setThemeMode(
                                  Theme.of(context).brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark,
                                ),
                          ),
                        ),
                        IconButton(
                          key: const Key('admin.signOut'),
                          tooltip: l10n.profileSignOut,
                          icon: const Icon(Icons.logout),
                          onPressed: () => unawaited(_signOut(null)),
                        ),
                      ],
                    ),
                  ),
                ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(),
              Expanded(child: widget.child),
            ],
          ),
        ),
      ),
    );
  }

  /// Room the rail needs: the avatar, each section (icon and a label at the
  /// clamped text scale, generous) and the three buttons at the bottom.
  static double _railHeight(int sections) =>
      AppSpacing.s16 * 2 + AppSpacing.s40 + sections * AppSpacing.s64 * 1.25 + AppSpacing.minTouchTarget * 3 + AppSpacing.s16;

  static String _initial(String name) {
    final String trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }
}
