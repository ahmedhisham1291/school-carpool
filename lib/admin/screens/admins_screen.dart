import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/admin/auth/admin_session.dart';
import 'package:school_carpool/admin/data/admin_api.dart';
import 'package:school_carpool/admin/data/admin_failure.dart';
import 'package:school_carpool/admin/data/admin_models.dart';
import 'package:school_carpool/admin/widgets/admin_labels.dart';
import 'package:school_carpool/admin/widgets/admin_widgets.dart';
import 'package:school_carpool/design/bidi.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/l10n/l10n.dart';

final FutureProvider<List<AdminAccount>> adminAccountsProvider = FutureProvider<List<AdminAccount>>(
  (Ref ref) => ref.watch(adminApiProvider).admins(),
);

/// Admin accounts (super admins only; the router and the functions both
/// check). Add an admin (one primary action): email, name and role. The
/// super admin gets a one-time link to pass on directly; the new admin
/// sets their own password there and adds the authenticator app at first
/// sign-in. Disable or enable other admins.
///
/// States: loading (skeleton), empty, error and offline (retry), sending
/// (button spinner), refusal (message).
class AdminsScreen extends ConsumerWidget {
  const AdminsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = context.l10n;
    final String? link = await showAppSheet<String>(context: context, title: l10n.adminAddAdmin, body: const _NewAdminForm());
    if (link == null || !context.mounted) {
      return;
    }
    ref.invalidate(adminAccountsProvider);
    await showAppSheet<void>(
      context: context,
      title: l10n.adminLinkTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(l10n.adminLinkBody),
          const SizedBox(height: AppSpacing.s16),
          AppCopyValue(label: l10n.adminLinkLabel, value: link),
        ],
      ),
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, AdminAccount a) async {
    final AppLocalizations l10n = context.l10n;
    final bool disable = !a.disabled;
    final bool ok = await showConfirmDialog(
      context: context,
      title: disable ? l10n.adminDisableTitle(a.displayName) : l10n.adminEnableTitle(a.displayName),
      body: disable ? l10n.adminDisableBody : l10n.adminEnableBody,
      confirmLabel: disable ? l10n.adminDisable : l10n.adminEnable,
      destructive: disable,
    );
    if (!ok || !context.mounted) {
      return;
    }
    try {
      await ref.read(adminApiProvider).setAdminDisabled(uid: a.uid, disabled: disable);
      if (context.mounted) {
        showAppSnackBar(context, l10n.adminSaved);
      }
      ref.invalidate(adminAccountsProvider);
    } on AdminFailure catch (failure) {
      if (context.mounted) {
        showAppSnackBar(context, failure.message(l10n));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = context.l10n;
    final String? me = adminUserOf(ref.watch(adminSessionProvider))?.uid;
    return AdminPage(
      title: l10n.adminAdminsTitle,
      actions: <Widget>[
        AppButton(
          key: const Key('admins.add'),
          label: l10n.adminAddAdmin,
          icon: Icons.person_add_alt_outlined,
          onPressed: () => unawaited(_add(context, ref)),
        ),
      ],
      body: AdminAsyncView<List<AdminAccount>>(
        value: ref.watch(adminAccountsProvider),
        onRetry: () => ref.invalidate(adminAccountsProvider),
        isEmpty: (List<AdminAccount> a) => a.isEmpty,
        builder: (List<AdminAccount> admins) => ListView.builder(
          itemCount: admins.length,
          itemBuilder: (BuildContext context, int i) {
            final AdminAccount a = admins[i];
            return AppListRow(
              key: Key('admins.${a.uid}'),
              title: a.displayName,
              subtitle: '${ltrIsolate(a.email)} · ${adminRoleLabel(l10n, a.role)}',
              leadingIcon: a.role == AdminRole.superAdmin ? Icons.admin_panel_settings_outlined : Icons.person_outline,
              trailing: a.disabled
                  ? AppStatusBadge(label: l10n.adminDisabled, tone: AppBadgeTone.error)
                  : AppStatusBadge(label: l10n.adminActive, tone: AppBadgeTone.success),
              onTap: a.uid == me ? null : () => unawaited(_toggle(context, ref, a)),
            );
          },
        ),
      ),
    );
  }
}

/// Email, name and role, checked as typed. Pops the setup link.
class _NewAdminForm extends ConsumerStatefulWidget {
  const _NewAdminForm();

  @override
  ConsumerState<_NewAdminForm> createState() => _NewAdminFormState();
}

class _NewAdminFormState extends ConsumerState<_NewAdminForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _name = TextEditingController();
  AdminRole _role = AdminRole.admin;
  bool _busy = false;
  AdminFailure? _failure;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _emailOk => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(_email.text.trim());
  bool get _nameOk => _name.text.trim().length >= 2 && _name.text.trim().length <= 60;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final String link = await ref
          .read(adminApiProvider)
          .createAdmin(email: _email.text.trim(), displayName: _name.text.trim(), role: _role);
      if (mounted) {
        Navigator.of(context).pop<String>(link);
      }
    } on AdminFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = failure;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final AdminFailure? failure = _failure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          key: const Key('newAdmin.email'),
          label: l10n.adminEmailLabel,
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.ltr,
          errorText: _email.text.isEmpty || _emailOk ? null : l10n.adminEmailError,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppTextField(
          key: const Key('newAdmin.name'),
          label: l10n.adminNameLabel,
          helperText: l10n.adminNameHelp,
          controller: _name,
          errorText: _name.text.isEmpty || _nameOk ? null : l10n.adminNameError,
        ),
        const SizedBox(height: AppSpacing.s16),
        AppSelectField<AdminRole>(
          key: const Key('newAdmin.role'),
          label: l10n.adminRoleLabel,
          options: <(AdminRole, String)>[
            (AdminRole.admin, l10n.adminRoleAdmin),
            (AdminRole.superAdmin, l10n.adminRoleSuper),
          ],
          value: _role,
          onChanged: (AdminRole r) => setState(() => _role = r),
        ),
        if (failure != null) ...<Widget>[
          const SizedBox(height: AppSpacing.s16),
          AppInlineMessage(message: failure.message(l10n), tone: AppStateTone.error),
        ],
        const SizedBox(height: AppSpacing.s16),
        AppButton(
          key: const Key('newAdmin.submit'),
          label: l10n.adminCreate,
          expand: true,
          loading: _busy,
          onPressed: _emailOk && _nameOk && !_busy ? () => unawaited(_create()) : null,
        ),
      ],
    );
  }
}
