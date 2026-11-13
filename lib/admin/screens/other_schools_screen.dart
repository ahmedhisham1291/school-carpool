import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/screens/schools_screen.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Schools parents typed under "Other" (status awaiting review). Open one
/// to correct it and approve it as new, or merge it into an existing
/// school. Parents add these from Prompt 4B on; the dev seed has two.
///
/// States: loading (skeleton), empty (nothing to review), error and
/// offline (retry).
class OtherSchoolsScreen extends StatelessWidget {
  const OtherSchoolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AdminPage(
      title: l10n.adminOtherTitle,
      body: SchoolList(
        status: SchoolStatus.awaitingReview,
        onOpen: (School s) => context.go(AdminRoutes.otherSchool(s.id)),
        empty: EmptyStateView(
          icon: Icons.task_alt_outlined,
          title: l10n.adminOtherEmptyTitle,
          body: l10n.adminOtherEmptyBody,
        ),
      ),
    );
  }
}
