# Workstream E: locked package versions, Meta WhatsApp guide, private-repo plan

Branch `improve-e-docs` (from main, 14 Nov 2026). Decision: docs/DECISIONS.md
"Improvements, revised", items 2 and 7. The coordinator said "go".

## Plan

| # | Task | Files |
| --- | --- | --- |
| 1 | Lock package versions: a manual-only CI job writes the lock files; every other install uses them when they exist | `.github/workflows/checks.yml`, `tool/bootstrap.sh`, `codemagic.yaml`, `docs/WORKFLOW.md`, `README.md`, `SETUP.md` 3.10 and 7 |
| 2 | Owner guide for Meta business verification and WhatsApp | `docs/meta-whatsapp-setup.md` (new), links from `SETUP.md` 11.5 and 18.4, `docs/open-items.md` A4 |
| 3 | Going private before launch: prices, minutes per run, checklist | `docs/launch-private-repo.md` (new), links from `docs/open-items.md` and `docs/COSTS.md` |
| 4 | Deploy warning "ENFORCE_APP_CHECK.value() invoked during function deployment": fix only if clean | `functions/src` (read only unless a clean fix exists) |

No data model change, no new screen, no new dependency, no new paid service.

## Open questions at the start

1. Which lock files: `pubspec.lock`, `packages/run_recovery/pubspec.lock`
   (our local plugin gets its own `pub get` in bootstrap),
   `functions/package-lock.json`, `tests/rules/package-lock.json` (CI
   installs all four).
2. Codemagic builds with `flutter: stable` (whatever is newest) while CI pins
   3.50.0. A lock file made on 3.50.0 can be refused by a newer Flutter (the
   SDK pins some packages itself), so Codemagic needs the same pin.
3. The code has two WhatsApp templates that SETUP.md does not list
   (`cp_child_not_coming`, `cp_new_device`), and open-items A4 names the code
   template `cp_code` while the code uses `login_code`.
