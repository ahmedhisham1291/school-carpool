import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/admin/widgets/watermarked_image.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// A plain 4 by 4 picture standing in for a document in the gallery.
final Uint8List kGalleryDocumentPng = Uint8List.fromList(<int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 4, 0, 0, 0, 4, 8, 2, 0, 0, 0, 38, //
  147, 9, 41, 0, 0, 0, 17, 73, 68, 65, 84, 120, 156, 99, 184, 255, 236, 29, 28, 49, 16, 199, 1, 0, 98, 96, //
  43, 49, 247, 151, 113, 226, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

/// Dev only: the admin panel's components (CLAUDE.md: a new component goes
/// into the gallery first). Built only from shared tokens and components.
class AdminGalleryScreen extends StatelessWidget {
  const AdminGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AdminPage(
      title: l10n.adminGalleryTitle,
      body: ListView(
        padding: AppSpacing.screenPadding,
        children: <Widget>[
          const AppSectionHeader('OneLine'),
          SizedBox(
            width: AppSpacing.s64 * 3,
            child: OneLineText(l10n.adminNameCheckHelp, style: context.text.bodyMedium),
          ),
          const SizedBox(height: AppSpacing.s24),
          const AppSectionHeader('AdminFact'),
          AdminFact(label: l10n.adminParentId, value: 'ABCD2345'),
          const SizedBox(height: AppSpacing.s24),
          const AppSectionHeader('WatermarkedImage'),
          WatermarkedImage(
            url: null,
            image: MemoryImage(kGalleryDocumentPng),
            watermark: 'Reviewer (test) · reviewer@example.com · 2026-11-13 10:42',
            semanticLabel: l10n.adminDocIdFront,
          ),
          const SizedBox(height: AppSpacing.s16),
          WatermarkedImage(url: null, watermark: 'Reviewer (test)', semanticLabel: l10n.adminDocSelfie),
          const SizedBox(height: AppSpacing.s24),
          const AppSectionHeader('AdminAsyncView'),
          SizedBox(
            height: AppSpacing.s64 * 3,
            child: AdminAsyncView<int>(
              value: const AsyncLoading<int>(),
              onRetry: () {},
              builder: (int v) => Text('$v'),
            ),
          ),
          SizedBox(
            height: AppSpacing.s64 * 5,
            child: AdminAsyncView<List<int>>(
              value: const AsyncData<List<int>>(<int>[]),
              onRetry: () {},
              isEmpty: (List<int> v) => v.isEmpty,
              builder: (List<int> v) => Text('$v'),
            ),
          ),
        ],
      ),
    );
  }
}
