import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/features/verification/verification_labels.dart';
import 'package:school_carpool/features/verification/verification_models.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// [AppStatusBadge] for the review status of a child or a car.
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({required this.status, super.key});

  final ReviewStatus status;

  static AppBadgeTone _toneFor(ReviewStatus status) => switch (status) {
    ReviewStatus.pending => AppBadgeTone.warning,
    ReviewStatus.approved => AppBadgeTone.success,
    ReviewStatus.rejected => AppBadgeTone.error,
  };

  /// The icon for [status], shared with list rows that show the status as
  /// text.
  static IconData iconFor(ReviewStatus status) => switch (status) {
    ReviewStatus.pending => Icons.hourglass_top_rounded,
    ReviewStatus.approved => Icons.verified_rounded,
    ReviewStatus.rejected => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) => AppStatusBadge(
    label: reviewStatusLabel(context.l10n, status),
    tone: _toneFor(status),
    icon: iconFor(status),
  );
}
