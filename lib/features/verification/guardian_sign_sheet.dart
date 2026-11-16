import 'package:material_ui/material_ui.dart';
import 'package:school_carpool/design/components/components.dart';
import 'package:school_carpool/design/tokens/tokens.dart';
import 'package:school_carpool/features/auth/consent_signature.dart';
import 'package:school_carpool/l10n/l10n.dart';

/// What the parent signed in the sheet.
@immutable
class GuardianSignature {
  const GuardianSignature({required this.fullName, this.teenAgreement = false});

  /// The typed full name (it matches the ID name).
  final String fullName;

  /// R4: the child is 15 or older and the guardian declared the child agrees.
  final bool teenAgreement;
}

/// R3: a verified parent adding or editing a child signs the guardian's
/// declaration again: its own unticked box, the typed full name (must match
/// the ID name, checked as typed) and, on "Sign and send", Face ID or the
/// passcode (asked by the caller right after). Returns null when closed.
///
/// No data is loaded here, so there is no loading, empty or offline state;
/// the caller shows the send progress and errors.
/// [teen]: the child is 15 or older (R4): a second unticked box, "my
/// child was told and agrees".
Future<GuardianSignature?> showGuardianSignSheet(BuildContext context, {required String firstName, required String lastName, bool teen = false}) =>
    showModalBottomSheet<GuardianSignature>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => _GuardianSignSheet(firstName: firstName, lastName: lastName, teen: teen),
    );

class _GuardianSignSheet extends StatefulWidget {
  const _GuardianSignSheet({required this.firstName, required this.lastName, required this.teen});

  final String firstName;
  final String lastName;
  final bool teen;

  @override
  State<_GuardianSignSheet> createState() => _GuardianSignSheetState();
}

class _GuardianSignSheetState extends State<_GuardianSignSheet> {
  bool _guardian = false;
  bool _teenAgrees = false;
  String _name = '';

  bool get _nameOk => nameLooksFull(_name) && nameMatches(_name, widget.firstName, widget.lastName);
  bool get _ready => _guardian && (!widget.teen || _teenAgrees) && _nameOk;

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
          if (widget.teen)
            AppCheckRow(
              key: const Key('guardianSign.teen'),
              label: l10n.verifyTeenLabel,
              helperText: l10n.verifyTeenHelper,
              value: _teenAgrees,
              onChanged: (bool v) => setState(() => _teenAgrees = v),
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
        onPressed: _ready ? () => Navigator.of(context).pop(GuardianSignature(fullName: _name, teenAgreement: widget.teen && _teenAgrees)) : null,
      ),
    );
  }
}
