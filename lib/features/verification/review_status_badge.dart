import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// [AppStatusBadge] for the review status of a child or a car.
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({required this.status, super.key});

  final ReviewStatus status;

  @override
  Widget build(BuildContext context) {
    final (AppBadgeTone tone, IconData icon) = switch (status) {
      ReviewStatus.pending => (AppBadgeTone.warning, Icons.hourglass_top_rounded),
      ReviewStatus.approved => (AppBadgeTone.success, Icons.verified_rounded),
      ReviewStatus.rejected => (AppBadgeTone.error, Icons.error_outline_rounded),
    };
    return AppStatusBadge(label: reviewStatusLabel(context.l10n, status), tone: tone, icon: icon);
  }
}
