# Making the repository private again before public launch

Owner decision (docs/DECISIONS.md, "Improvements, revised", item 7): the
repository is public today because GitHub's checks are free for public
repositories. Before the public launch it goes private again. This page
gives the steps, what it costs and the checklist. Written 14 Nov 2026;
prices were read on GitHub's own pages that day (links in section 8).

## 1. Short answer

- Going private costs **nothing by itself**. A private repository on the
  free plan gets **2,000 free Linux minutes a month**; one full check run
  of ours uses about **16** of them, a branch run about **6**.
- A calm month after launch fits inside the free minutes. A heavy build
  month (like the days when 40 runs happened in one day) does not: either
  the checks stop until the next month, or you allow a small budget
  (USD 5 buys about 830 more minutes).
- Recommended: go private on the **free plan with a budget of USD 0 that
  stops usage**, watch one month, then decide on a small budget.
- Making the repository private does **not** hide what was public: anyone
  may already have a copy. So the real work is the checklist in section 6
  (no secrets in history, known gaps fixed), not the switch itself.

## 2. Prices (GitHub, read 14 Nov 2026)

| Plan | Price | Included Actions minutes a month (private repositories) | Included storage for artifacts |
| --- | --- | --- | --- |
| Free (personal account, or a free organization) | USD 0 | 2,000 | 500 MB |
| Pro (personal account) | about USD 4 a month (**not shown on GitHub's pricing page any more; check in your account's billing settings**) | 3,000 | 1 GB |
| Team (organization) | USD 4 per user a month | 3,000 | 2 GB |
| Enterprise | USD 21 per user a month | 50,000 | 50 GB |

- **Public repositories:** standard runners are free and do not use the
  included minutes. That is today's situation.
- **How the included amount works:** GitHub now counts it in dollars (USD
  12 on Free, USD 18 on Pro and Team). At the Linux rate that is the 2,000
  and 3,000 minutes above.
- **Price per extra minute:** Linux 2-core (what all our jobs use,
  `ubuntu-latest`) **USD 0.006**. For comparison: Linux 1-core USD 0.002,
  Windows USD 0.010, macOS USD 0.062. We run nothing on Windows or macOS at
  GitHub (iPhone builds are on Codemagic).
- **Rounding:** each job is rounded **up** to a whole minute. A run with
  three jobs of 1.7, 4.4 and 10.6 minutes is billed 2 + 5 + 11 = 18.
- **Storage:** artifacts (our screenshots zip, kept 30 days) count against
  the plan's storage; extra is USD 0.25 per GB a month. Caches have their
  own 10 GB per repository; extra is USD 0.07 per GB a month.
- **Without a payment method** on the account, checks simply stop when the
  included amount is used up, until the next billing month. Nothing is
  charged.

### Setting a spending limit ("budget")

GitHub replaced the old "spending limit" with **budgets**.

1. github.com > your photo > **Settings** > **Billing and licensing** (or
   open https://github.com/settings/billing).
2. **Budgets and alerts** > **New budget**.
3. Budget type: **Product-level budget**. Scope/product: **Actions**.
4. Budget: the amount in USD for a month. **0** means "never pay": checks
   stop when the free minutes are gone.
5. Tick **Stop usage when budget limit is reached**. Without this tick the
   budget only sends emails and the spending continues.
6. Tick **Receive budget threshold alerts** (emails at 75, 90 and 100
   percent).
7. **Create budget**.

(For an organization: the organization's **Settings** > **Billing &
Licensing** > **Budgets and alerts**, same fields.)

Check for an existing Actions budget first: we could not confirm whether
GitHub creates a default one for every account.

## 3. What our checks use per run

Measured on this repository's runs of 14 Nov 2026 (Actions history, caches
warm), per job, wall-clock time:

| Job in `.github/workflows/checks.yml` | When it runs | Measured | Billed minutes |
| --- | --- | --- | --- |
| Flutter analyze, tests (and screenshots on `main`) | every run | 3 min 24 s to 4 min 22 s | 4 to 5 |
| Web, admin panel and Android compile | `main`, tags, or `full=true` | 7 min 34 s to 10 min 39 s | 8 to 11 |
| Cloud Functions and rules tests on the emulators | every run | 1 min 41 s to 1 min 58 s | 2 |
| Lock files (manual, `update_locks=true`) | by hand only | 52 s (one run, 14 Nov 2026) | 1 |

| Kind of run | Billed minutes | Cost beyond the free minutes |
| --- | --- | --- |
| Push to `main` (all three jobs) | **14 to 18**, call it 16 | about USD 0.10 |
| Branch run by hand, `full=false` (two jobs) | **about 6** | about USD 0.04 |
| The same with cold caches (new Flutter version, changed lock files, cache older than 7 days) | up to about 2 times more; the Android build has a 45-minute cap | up to about USD 0.25 |
| Docs-only push | 0 (ignored by `paths-ignore`) | 0 |

These are few measurements from one day. Take them as "about", not as a
promise; the Android build varies the most.

**What that means per month**

| Month | Runs | Minutes | Free plan (2,000) |
| --- | --- | --- | --- |
| Calm (after launch): 30 merges to `main`, 30 branch checks | 60 | about 660 | fits, a third used |
| Normal build month: 60 merges, 100 branch checks | 160 | about 1,560 | fits, tight |
| Heavy build month: 120 merges, 300 branch checks | 420 | about 3,700 | 1,700 over: about **USD 10**, or checks stop around day 16 |

The rules already in the workflow keep this low: only `main` runs by
itself, branches run by hand, docs pushes run nothing, a failed job cancels
the others, a newer push cancels the older run.

Easy savings if minutes get tight (developer work, small):
- do not run the Android and web builds on every push to `main`, only on
  tags and by hand (saves about 9 of the 16 minutes);
- keep the screenshots artifact 7 days instead of 30 (storage);
- run the emulator tests only when `functions/`, `tests/rules/` or the
  rules files changed.

## 4. The choices

| # | Choice | Cost a month | Good | Bad |
| --- | --- | --- | --- | --- |
| 1 | **Private, Free plan, budget USD 0 with "stop usage"** | 0 | No bill possible. Enough for calm and normal months | In a heavy month the checks stop until the 1st; merging then waits or happens unchecked (not allowed by our workflow) |
| 2 | Private, Free plan, **budget USD 5 to 10** with "stop usage" | 0 to 10, only what is used | Covers heavy months; hard ceiling | Needs a card on the account |
| 3 | Private, **Pro** (personal account) | about 4 (check) | 3,000 minutes, 1 GB storage; also brings back branch protection on a private repository (section 5) | Fixed cost even in calm months; 1,000 extra minutes cost only USD 6 as you go in choice 2 |
| 4 | Private, **Team** in an organization | 4 per person | Right when a second human developer joins: roles, protected branches, 3,000 minutes | Moving the repository to an organization changes its address (Codemagic and clone commands must be updated) |
| 5 | **Own runner** (a Mac or small Linux machine you keep on, registered as a self-hosted runner) | 0 to GitHub today | No minute limits | A machine to keep running, patched and secure; a job with write access to it is a risk; GitHub has discussed charging for self-hosted runners (its billing page still says they are free on 14 Nov 2026: check again) |
| 6 | **Checks elsewhere** (Codemagic Linux, Google Cloud Build, GitLab CI) | varies | Not tied to GitHub's minutes | Codemagic's free tier has no Linux minutes (that is why the checks left it, docs/COSTS.md); any other service is a new tool, the workflow must be rewritten and kept in two places. Not worth it at this size |
| 7 | Stay public | 0 | Free checks without limit | Against the owner's decision: the reviews, open items and security notes stay readable by anyone |

**Recommendation:** choice 1 on the day of the switch, moving to choice 2
(budget USD 5) the first time the checks stop in a month that matters.
Choice 4 when a second person needs write access.

## 5. What else changes when the repository is private

Besides the minutes (our understanding of the free plan; confirm on
GitHub's plan comparison before the switch):

- **Branch protection** rules for `main` are not enforced on a private
  repository of the Free plan. Our rule "nobody commits to `main`
  directly" then rests on discipline, or on Pro/Team.
- **Secret scanning and push protection** are free only for public
  repositories. Use them now, while public (section 6, step 2).
- **GitHub Pages** from a private repository needs a paid plan. We do not
  use Pages (the sites are on Firebase Hosting).
- **Forks** made while public stay public, cut loose from ours. Stars and
  watchers are removed.
- **Codemagic** keeps working if its GitHub app has access to the private
  repository; check after the switch (step 7.4).
- **Cloud Shell setup:** `docs/owner-cloud-shell.md` and the header of
  `tool/cloud_setup.sh` tell the owner to `git clone
  https://github.com/...` without signing in. That stops working. After
  the switch the owner runs `gh auth login` in Cloud Shell first (or the
  developer changes the instructions to `gh repo clone`). To be updated in
  the same change as the switch.
- **Links** to files of the repository in emails or notes stop opening
  for people who are not collaborators.

## 6. Checklist before the switch

History is the point. Everything that was ever pushed while public must be
treated as **published for good**: it may be in someone's clone, in a
fork, or in an archive of public code. Going private (or even rewriting
history) does not take it back.

1. **Scan the whole history for secrets.** One-off, on the developer's
   machine or as a one-time manual job (no new dependency in the project):

   ```sh
   # gitleaks (open source); scans every commit of every branch
   gitleaks git --redact --log-opts="--all" .
   # or: trufflehog git file://. --only-verified
   ```

   Also search by hand for the kinds of value this project has:
   `git log --all -p -S 'EAA' -- .` (Meta tokens), `-S 'AIza'` (Google API
   keys), `-S 'BEGIN PRIVATE KEY'`, `-S 'sk_'`, and the file names in
   `.gitignore` (`*.p8`, `*.p12`, `service-account*.json`,
   `GoogleService-Info.plist`, `.env.*`).
2. **Turn on GitHub's own scanner while it is free:** repository
   **Settings** > **Advanced Security** (older name: Code security) >
   enable **Secret Protection** and **Push protection**. Open **Security**
   > **Secret scanning** and clear every alert.
3. **Anything found is rotated, not just deleted.** A key that was public
   for one minute is burnt: make a new one at the provider (Firebase,
   Google Maps, Meta, Algolia, Sentry, Codemagic), put it in Secret
   Manager, then remove the old one.
4. **Values that are in the repository on purpose** and are fine: the
   Firebase options files (`lib/firebase/firebase_options_*.dart`: these
   keys identify the project and are protected by App Check and the
   rules), the non-secret `functions/.env.*` flags, bundle IDs, the App
   Store Apple ID in `codemagic.yaml`. Check that the Google Maps keys are
   **not** in the repository and are restricted to the bundle IDs (SETUP.md
   15.2).
5. **Read what the public can read today** and decide if it matters:
   - `docs/reviews/` (every review, including security findings and how
     they were fixed);
   - `docs/open-items.md` and `SECURITY.md` (known gaps, for example the
     items in section D and the pending penetration test);
   - `docs/progress/` (design decisions, limits, rate-limit numbers);
   - `firestore.rules`, `storage.rules` and the Functions code (limits and
     checks an attacker could study).

   Rule of thumb: the app must be safe even if all of this is public
   (rules deny by default, App Check, server-side checks). Open gaps are
   the exception: **fix or accept every open security item before launch**
   rather than rely on hiding the list.
6. **If you want the reviews and open items out of the public tree now**
   (before the switch): move `docs/reviews/` and `docs/open-items.md` to a
   private place (a second private repository, or a private Claude
   Project) and delete them from `main`. Be clear about what this does:
   new readers of `main` no longer see them, but **the old commits still
   contain them and stay public until the repository is private**, and in
   any copy made before. Rewriting history (`git filter-repo`) changes
   every commit ID, breaks open branches and Codemagic build references,
   and still cannot reach existing copies; we do not recommend it.
7. **Rules for after the switch stay the same:** private is not a place
   for secrets either. Secrets live in Secret Manager and in Codemagic's
   secret groups, never in the repository (CLAUDE.md, SECURITY).
8. Note the date and what was found in `SECURITY.md` (one line).

## 7. The switch, step by step

1. Finish section 6. Merge or close open branches you no longer need.
2. Set the budget first (section 2), so the first private run cannot
   surprise you.
3. github.com > the repository > **Settings** > **General** > scroll to
   **Danger Zone** > **Change repository visibility** > **Change to
   private** > read the warnings > type the repository name to confirm.
4. **Codemagic:** open the app > start an `ios-staging` build only if one
   is due anyway (macOS minutes are limited); otherwise check that the
   repository still appears under the app's settings. If not: Codemagic >
   Teams > Integrations > GitHub > allow the private repository.
5. **Checks:** start one run by hand
   (`gh workflow run checks.yml --ref main -f full=false`) and see it turn
   green. Open **Settings > Billing and licensing > Usage**: the run's
   minutes must appear there (they did not while public).
6. **Cloud Shell:** follow `docs/owner-cloud-shell.md` once with the new
   clone step, so the instructions are proven before they are needed.
7. Update the top comment of `.github/workflows/checks.yml`, the GitHub
   Actions row of `docs/COSTS.md` and SETUP.md section 7 ("public" becomes
   "private, 2,000 free minutes"), and tick the item in
   `docs/open-items.md`.
8. After one month: look at **Usage**, compare with section 3, and decide
   between choices 1 and 2.

Going public again later is the same switch. Nothing in the build depends
on the repository being private.

## 8. Sources (read 14 Nov 2026) and what we could not confirm

- Plans, prices and included minutes: https://github.com/pricing and
  https://docs.github.com/en/billing/reference/product-usage-included
- Price per minute by runner, rounding:
  https://docs.github.com/en/billing/reference/actions-runner-pricing
- How Actions is billed (public free, included amount in dollars, storage
  prices, no payment method means usage stops, self-hosted free):
  https://docs.github.com/en/billing/concepts/product-billing/github-actions
- Budgets: https://docs.github.com/en/billing/how-tos/set-up-budgets
- Our run times: this repository's Actions history, runs of 14 Nov 2026.

Not confirmed:
- The price of **GitHub Pro** (USD 4 a month is the long-standing price;
  the pricing page no longer lists Pro).
- Whether every account has a **default Actions budget** already.
- The exact list of features lost on a private repository of the Free
  plan (section 5 is our understanding, not read from a GitHub page today).
- Whether GitHub will charge for **self-hosted runners**.
- Cold-cache run times (estimates).
- The current menu names in **Settings > Advanced Security**; GitHub
  renamed these in 2025.
