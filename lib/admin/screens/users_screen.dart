import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/router/admin_redirect.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// Users (F14): search on the server by name, phone or parent ID. Searches
/// are rate limited and logged (kind and count only); phones come back
/// masked. Nothing is listed before a search, so nobody can browse every
/// parent.
///
/// States: before a search (what to type), searching (skeleton), no
/// results, error with what to do (too many searches: wait), offline.
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  final TextEditingController _query = TextEditingController();
  AsyncValue<List<UserSummary>>? _results;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _canSearch => _query.text.trim().length >= 2 && _results is! AsyncLoading<List<UserSummary>>;

  Future<void> _search() async {
    if (!_canSearch) {
      return;
    }
    setState(() => _results = const AsyncLoading<List<UserSummary>>());
    try {
      final List<UserSummary> users = await ref.read(adminApiProvider).searchUsers(_query.text.trim());
      if (mounted) {
        setState(() => _results = AsyncData<List<UserSummary>>(users));
      }
    } on AdminFailure catch (failure, stack) {
      if (mounted) {
        setState(() => _results = AsyncError<List<UserSummary>>(failure, stack));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AsyncValue<List<UserSummary>>? results = _results;
    return AdminPage(
      title: l10n.adminUsersTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: AppSpacing.screenPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: AppTextField(
                    key: const Key('users.query'),
                    label: l10n.adminUsersSearchLabel,
                    helperText: l10n.adminUsersSearchHelp,
                    controller: _query,
                    prefixIcon: Icons.search,
                    textInputAction: TextInputAction.search,
                    onFieldSubmitted: (_) => unawaited(_search()),
                  ),
                ),
                const SizedBox(width: AppSpacing.s16),
                AppButton(
                  key: const Key('users.search'),
                  label: l10n.adminSearch,
                  onPressed: _canSearch ? () => unawaited(_search()) : null,
                ),
              ],
            ),
          ),
          Expanded(
            child: results == null
                ? EmptyStateView(
                    icon: Icons.person_search_outlined,
                    title: l10n.adminUsersStartTitle,
                    body: l10n.adminUsersStartBody,
                  )
                : AdminAsyncView<List<UserSummary>>(
                    value: results,
                    onRetry: () => unawaited(_search()),
                    isEmpty: (List<UserSummary> users) => users.isEmpty,
                    empty: EmptyStateView(
                      icon: Icons.person_off_outlined,
                      title: l10n.adminUsersNoneTitle,
                      body: l10n.adminUsersNoneBody,
                    ),
                    builder: (List<UserSummary> users) => ListView.builder(
                      itemCount: users.length,
                      itemBuilder: (BuildContext context, int i) {
                        final UserSummary u = users[i];
                        return AppListRow(
                          key: Key('users.${u.uid}'),
                          title: u.fullName ?? l10n.adminNoName,
                          subtitle: <String>[
                            ltrIsolate(u.parentId),
                            if (u.maskedPhone != null) ltrIsolate(u.maskedPhone!),
                          ].join(' · '),
                          leadingIcon: Icons.person_outline,
                          trailing: AppStatusBadge(
                            label: accountStatusLabel(l10n, u.status, banned: u.banned),
                            tone: accountStatusTone(u.status, banned: u.banned),
                          ),
                          onTap: () => context.go(AdminRoutes.user(u.uid)),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
