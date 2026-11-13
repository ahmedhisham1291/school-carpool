import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Home tab. Until trips arrive (Prompts 6 to 8) it leads to the maps:
/// parents nearby, the parent's home and their driving schools.
///
/// States: the home row says "Loading" while the home loads and "Not set
/// yet" when there is none or it could not be read (the row still opens
/// the picker, which has its own error and offline states).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<HomeLocation?> home = ref.watch(myHomeProvider);
    final String homeStatus = switch (home) {
      AsyncData<HomeLocation?>(:final HomeLocation? value) when value?.hasHome ?? false => l10n.homeRowSet,
      AsyncLoading<HomeLocation?>() => l10n.stateLoadingLabel,
      _ => l10n.homeRowNotSet,
    };

    return Scaffold(
      appBar: AppBar(title: AppBarTitle(l10n.tabHome)),
      body: ListView(
        padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.s32),
        children: <Widget>[
          AppSectionHeader(l10n.homeAroundYouSection),
          AppListRow(
            key: const Key('home.nearby'),
            title: l10n.nearbyTitle,
            subtitle: l10n.homeNearbyHelper,
            leadingIcon: Icons.people_outline_rounded,
            onTap: () => context.go(HomeRoutes.nearby),
          ),
          AppListRow(
            key: const Key('home.homeLocation'),
            title: l10n.homeLocationTitle,
            subtitle: homeStatus,
            leadingIcon: Icons.home_work_outlined,
            onTap: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (BuildContext context) => const HomeLocationScreen()),
              ),
            ),
          ),
          AppListRow(
            key: const Key('home.drivingSchools'),
            title: l10n.drivingSchoolsTitle,
            subtitle: l10n.profileDrivingSchoolsHelper,
            leadingIcon: Icons.alt_route_rounded,
            onTap: () => context.go(ProfileRoutes.drivingSchools),
          ),
          AppSectionHeader(l10n.homeTripsSection),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: AppSpacing.screenGutter),
            child: Text(
              l10n.placeholderHomeBody,
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
