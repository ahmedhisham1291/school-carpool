import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/auth/idle_timeout.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
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
class AdminShell extends ConsumerWidget {
  const AdminShell({required this.location, required this.child, super.key});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AdminUser? user = adminUserOf(ref.watch(adminSessionProvider));
    final List<AdminSection> sections = adminSections(superAdmin: user?.isSuperAdmin ?? false);
    final int index = sections.indexWhere((AdminSection s) => location.startsWith(s.path));

    Future<void> signOut(AdminSignOutReason? reason) async {
      ref.read(adminSignOutReasonProvider.notifier).set(reason);
      await ref.read(adminAuthRepositoryProvider).signOut();
    }

    return IdleTimeout(
      timeout: kAdminIdleTimeout,
      onTimeout: () => unawaited(signOut(AdminSignOutReason.idle)),
      child: Scaffold(
        body: SafeArea(
          child: Row(
            children: <Widget>[
              NavigationRail(
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
                      child: OneLine(_initial(user?.displayName ?? l10n.adminPanelTitle)),
                    ),
                  ),
                ),
                destinations: <NavigationRailDestination>[
                  for (final AdminSection s in sections)
                    NavigationRailDestination(
                      icon: Icon(s.icon),
                      selectedIcon: Icon(s.selectedIcon),
                      label: OneLine(s.label(l10n)),
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
                        onPressed: () => unawaited(signOut(null)),
                      ),
                    ],
                  ),
                ),
              ),
              const VerticalDivider(),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  static String _initial(String name) {
    final String trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
  }
}
