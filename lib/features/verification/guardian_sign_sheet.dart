import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/consent_signature.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// What the parent signed in the sheet.
@immutable
class GuardianSignature {
  const GuardianSignature({required this.fullName});

  /// The typed full name (it matches the ID name).
  final String fullName;
}

/// R3: a verified parent adding or editing a child signs the guardian's
/// declaration again: its own unticked box, the typed full name (must match
/// the ID name, checked as typed) and, on "Sign and send", Face ID or the
/// passcode (asked by the caller right after). Returns null when closed.
///
/// No data is loaded here, so there is no loading, empty or offline state;
/// the caller shows the send progress and errors.
Future<GuardianSignature?> showGuardianSignSheet(BuildContext context, {required String firstName, required String lastName}) =>
    showModalBottomSheet<GuardianSignature>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => _GuardianSignSheet(firstName: firstName, lastName: lastName),
    );

class _GuardianSignSheet extends StatefulWidget {
  const _GuardianSignSheet({required this.firstName, required this.lastName});

  final String firstName;
  final String lastName;

  @override
  State<_GuardianSignSheet> createState() => _GuardianSignSheetState();
}

class _GuardianSignSheetState extends State<_GuardianSignSheet> {
  bool _guardian = false;
  String _name = '';

  bool get _nameOk => nameLooksFull(_name) && nameMatches(_name, widget.firstName, widget.lastName);
  bool get _ready => _guardian && _nameOk;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final String? error = _name.trim().isEmpty
        ? null
        : !nameLooksFull(_name)
        ? l10n.signNameError
        : _nameOk
        ? null
        : l10n.signNameMismatch('${widget.firstName} ${widget.lastName}');
    return AppSheet(
      title: l10n.guardianSignTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppCheckRow(
            key: const Key('guardianSign.box'),
            label: context.l10n.verifyGuardianLabel,
            helperText: context.l10n.verifyGuardianHelper,
            value: _guardian,
            onChanged: (bool v) => setState(() => _guardian = v),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppTextField(
            key: const Key('guardianSign.name'),
            label: l10n.signNameLabel,
            helperText: l10n.signNameHelperId,
            errorText: error,
            textInputAction: TextInputAction.done,
            onChanged: (String v) => setState(() => _name = v),
          ),
          if (!_ready) ...<Widget>[
            const SizedBox(height: AppSpacing.s8),
            AppInlineMessage(message: l10n.signHint),
          ],
        ],
      ),
      primaryAction: AppButton(
        key: const Key('guardianSign.send'),
        label: l10n.guardianSignAction,
        expand: true,
        onPressed: _ready ? () => Navigator.of(context).pop(GuardianSignature(fullName: _name)) : null,
      ),
    );
  }
}
