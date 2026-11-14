import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/maps/home_location_screen.dart';
import 'package:school_carpool/features/maps/map_models.dart';
import 'package:school_carpool/features/maps/map_repository.dart';
import 'package:school_carpool/features/trips/location_gate.dart';
import 'package:school_carpool/l10n/l10n.dart';
import 'package:school_carpool/router/app_router.dart';

/// Home tab: the location banner (Prompt 13), the maps (parents nearby,
/// the parent's home, driving schools) and a way to today's runs.
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
          // Prompt 13: location off, refused or approximate (never blocks).
          const LocationOffBanner(),
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
          // Prompt 13 design pass: the old "will appear here" text is gone;
          // today's runs live on each carpool's page (Prompt 10).
          AppListRow(
            key: const Key('home.runs'),
            title: l10n.homeRunsRow,
            subtitle: l10n.homeRunsHelper,
            leadingIcon: Icons.directions_car_outlined,
            onTap: () => context.go(AppTab.carpools.path),
          ),
        ],
      ),
    );
  }
}
