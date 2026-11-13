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

## Environment note
The cloud workspace has no Flutter SDK, so code is compiled and tested on Codemagic.
A review that could not run the compiler or tests says so.
