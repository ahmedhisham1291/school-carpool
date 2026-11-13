import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/settings/settings_section.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Placeholder for each bottom tab until its feature prompt builds it.
/// The Profile tab already holds the settings (language, appearance) and,
/// in the dev build, the developer tools.
class PlaceholderTabScreen extends StatelessWidget {
  const PlaceholderTabScreen({required this.tab, super.key});

  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final (String title, String body, IconData icon) = switch (tab) {
      AppTab.home => (l10n.tabHome, l10n.placeholderHomeBody, Icons.home_outlined),
      AppTab.carpools => (
        l10n.tabCarpools,
        l10n.placeholderCarpoolsBody,
        Icons.directions_car_outlined,
      ),
      AppTab.chats => (l10n.tabChats, l10n.placeholderChatsBody, Icons.chat_bubble_outline_rounded),
      AppTab.notifications => (
        l10n.tabNotifications,
        l10n.placeholderNotificationsBody,
        Icons.notifications_none_rounded,
      ),
      AppTab.profile => (l10n.tabProfile, l10n.placeholderProfileBody, Icons.person_outline_rounded),
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(title)),
      body: tab == AppTab.profile
          ? ListView(
              padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
              children: <Widget>[
                Padding(
                  padding: AppSpacing.screenPadding,
                  child: AppCard(
                    child: Row(
                      children: <Widget>[
                        Icon(icon, color: context.colors.primary),
                        const SizedBox(width: AppSpacing.s16),
                        Expanded(child: Text(body, style: context.text.bodyMedium)),
                      ],
                    ),
                  ),
                ),
                const SettingsSection(),
              ],
            )
          : EmptyStateView(icon: icon, title: l10n.comingSoon, body: body),
    );
  }
}
