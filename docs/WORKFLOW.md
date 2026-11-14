# Build workflow

## Branches
- `main` holds only work the validator has approved. Nobody commits to it directly.
- One branch per prompt: `prompt-NN-<name>` (for example `prompt-01-foundation`,
  `prompt-02-whatsapp-signup`, `prompt-04b-schools`).
- When several agents work on one prompt at the same time, each agent gets its own
  branch from the prompt branch: `prompt-NN-<name>--<agent-task>`. The coordinator
  merges each agent branch into the prompt branch after it passes validation.
- Commits: one feature ID per commit where possible, for example `F7: rotation per direction`.

## Flow for every prompt
1. The coordinator creates the prompt branch from the latest `main`.
2. The build agent(s) work on their branches and write `docs/progress/prompt-NN.md`
   (what was built, decisions, open questions, iPhone test steps, what is not done).
3. The **validator agent** reviews the branch against `docs/spec.md`, the rules file
   (`AGENTS.md` / `CLAUDE.md`) and the prompt's "Done when" list. It checks:
   correctness and likely compile errors, security, privacy, money rules, design rules,
   translations (Arabic and English), tests for each feature ID, free-tier cost rules.
   It writes `docs/reviews/prompt-NN-review.md` with a verdict: PASS or CHANGES NEEDED.
4. CHANGES NEEDED: the build agent fixes the listed items on the same branch and the
   validator reviews again.
5. PASS: the coordinator merges with `--no-ff` into `main` and pushes. The branch stays
   on GitHub for history.

## Package versions (locked)

Every build installs exactly the package versions written in the lock files, so
a version never changes by accident (a newer package once broke a build that had
passed the day before). The lock files are committed:

| File | Locks | Used by |
| --- | --- | --- |
| `pubspec.lock` | Dart and Flutter packages of the app | `tool/bootstrap.sh` (GitHub Actions, Codemagic, the Cloud Shell setup script, a Mac) |
| `packages/run_recovery/pubspec.lock` | our local iPhone plugin's own packages | `tool/bootstrap.sh` |
| `functions/package-lock.json` | Cloud Functions packages | CI (`npm ci`), `tool/cloud_setup.sh`, and Google's build at deploy time |
| `tests/rules/package-lock.json` | rules tests packages | CI (`npm ci`) |

How they are enforced:
- `tool/bootstrap.sh` runs `flutter pub get --enforce-lockfile` when `pubspec.lock`
  is committed: the build stops if `pubspec.yaml` and the lock disagree. CI uses
  `npm ci`, which stops in the same way for `package.json`.
- Until the first lock commit exists, the same steps fall back to a plain install
  and print a warning ("versions are NOT locked").
- The lock is made with one Flutter version. `FLUTTER_VERSION` in
  `.github/workflows/checks.yml` and `flutter:` in `codemagic.yaml` must be the
  same number; change both together, then refresh the lock files (below).

**Updating packages on purpose** (the only way versions change):
1. Work on a branch (never `main`). To add or change one package, edit
   `pubspec.yaml` or `package.json` there and push. To take the newest versions
   of everything the manifests allow, change nothing.
2. Start the lock job on that branch. This workspace has no pub.dev or npm
   access, so GitHub Actions writes the files:
   - keep current versions, only add what the manifests now ask for:
     `gh workflow run checks.yml --ref <branch> -f update_locks=true`
   - newest allowed versions of everything:
     `gh workflow run checks.yml --ref <branch> -f update_locks=true -f upgrade_packages=true`

   The job runs nothing else (about 2 minutes), commits the lock files to the
   same branch as `github-actions[bot]` and pushes. It refuses to run on `main`
   or on a tag.
3. `git pull`, then review the diff of the lock files (`git show --stat`, and the
   changed versions): expect only the packages you meant to change and what they
   pull in. A major version jump of a package nobody asked for is a reason to stop.
4. One CI run on the branch (the bot's push does not start one):
   `gh workflow run checks.yml --ref <branch> -f full=true`.
5. Green: validator review, then merge as usual. Red: fix on the branch, or drop
   the lock commit.

On a Mac, a developer who edits `pubspec.yaml` runs `UPDATE_LOCK=1 tool/bootstrap.sh`
once and commits the changed `pubspec.lock` (and `npm install --prefix functions`
for `package-lock.json`). Do not delete a lock file to "fix" a build.

## Environment note
The cloud workspace has no Flutter SDK, so code is compiled and tested on GitHub
Actions (checks) and Codemagic (iPhone builds).
A review that could not run the compiler or tests says so.
