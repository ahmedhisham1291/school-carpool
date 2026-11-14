# Prompt 11 review: Trust and yearly checks (F17)

Branch `prompt-11-trust`, head `d7503c9` (includes `main` with Prompts 1
to 10 and 11B). I reviewed `git diff origin/main...HEAD` (71 files)
against CLAUDE.md (SECURITY, PRIVACY, DESIGN, COST MODE), docs/spec.md
(section 3 rules, section 6 in full, F17, section 7, section 9 "Guardian
link"), docs/build-prompts.md "Prompt 11" and its "Done when",
docs/DECISIONS.md (including "Data retention and collection"),
docs/DESIGN.md, docs/WORKFLOW.md and docs/progress/prompt-11.md.

## Verdict: PASS

The server side holds up when I probe it. Every trust write runs in Cloud
Functions. The six new collections are closed in the rules and covered by
`deny_all` and the rules tests. Ratings need a shared, finished trip with
a child actually carried. They are one per pair per month, created in a
transaction, never self-ratings, and use stars and fixed tags only.
Guardian links cannot be taken by force: the children's parent picks the
children and accepts. A link in review gives nothing. Only `active` links
reach the carpool, map and chat stores. The driving rules still go
through `withFreshCars` and `checkArrangement` on every assignment path,
and they now also cover expired papers by run date, a new car waiting for
review, fewer seats and a missed yearly check. A suspended or banned
driver's runs open, and the group hears only "driver unavailable". I found
nothing blocking. The non-blocking items are listed below.

## CI

Run 43579654005 on `d7503c9` (`gh api .../actions/runs/43579654005/jobs`,
re-checked): **success**.

| Job | Result |
| --- | --- |
| Flutter analyze, tests and screenshots | success |
| Cloud Functions tests and rules tests (emulators) | success |
| Web, admin panel and Android compile (staging) | skipped (by design on feature branches; runs at merge to `main`) |

What I ran here: an ARB check with python3. It found 1777 keys in Arabic
and 1777 in English, no missing keys, and every declared placeholder
present in both languages. I also checked `firestore.indexes.json` for
duplicate indexes and found none. I did not run Flutter, the Functions
tests or the emulators myself. I did not open the screenshot artifact.
CI ran all of them.

## What I checked

| Area | Finding |
| --- | --- |
| Ratings only after shared COMPLETED trips within 30 days | `sharedTrips` (`trust/model.ts:175`): the trip must be `ended`, dated within the window, with a stop `dropped` or `received`. Only the driver and the carried parent form a pair. Two passengers' parents do not. `rateParent` checks this again on the server (`flow.ts:225`). |
| One per pair per month, no self-rating | The ID is `{YYYY-MM}_{rater}_{ratee}` (Cairo month). `saveRating` creates it inside a transaction and refuses one that exists. A rater cannot rate themselves (`self`). There is a limit of 30 ratings a day. |
| Stars and fixed tags only | `parseRating`: integer 1 to 5, known tags only, and a vouch only with 4 or more stars and no concern. There is no free text anywhere. |
| Low or unsafe ratings reach admins | 2 stars or fewer, or "unsafe driving", creates `ratingFlags/{id}` in the same transaction. Admin > Trust closes a flag once, with an audit entry. The sheet points to Report for danger. |
| Visibility | A parent sees only their own summary. Another parent's summary is shown only to approved members of a shared carpool (`shareCarpool`, rate limited). The average appears from 3 ratings, and voucher uids are never returned. No public score exists, and the carpool screens do not show summaries yet. |
| Guardian links | Requests go by parent ID (normalised and rate limited, 5 a day). The owner picks only their own approved children (`not-your-child`), with at most 2 other adults per child. A `guardian` relation, or a child who already has a link, goes to admin review. A link in `review` grants nothing (`linkedChildIds`: `active` only). Either side can remove a link: the child leaves the linked parent's carpools and future pickup lists, and a parent left with no child leaves the carpool and its chat. The map and school groups follow (`refreshOnGuardianLinkWrite` → publicLocations → chat sync). Links have no wallet effect. A child is in a carpool once (`child-in-carpool` on request and approve). |
| Who may drive | No new assignment path bypasses `withFreshCars` (plan, confirm, swap, cancel swap, take, absent, reconcile, tick). `driverAccount` now also reads `yearCheckOverdue` as paused. `vehicleInfo` uses `usableVehicle`. A spouse drives only with their own verified account and approved car, and other parents must consent. |
| Papers expiry | Planning, confirming and taking refuse `car-expired` by run date. `trustDaily` (08:10 Cairo) sends 30/7/1-day reminders with fixed event IDs through the outbox and dispatcher. The WhatsApp group "trust" is off by default (COST MODE). "Expired" releases runs after the last valid day. The vehicle trigger does the same on any change. |
| Suspended or banned | `releaseRunsOnUserBlock` acts only on the change into blocked. It reuses Prompt 9's `releaseAfterPause` (event `driver-unavailable`, no reason). Admin suspend and ban texts say so in both languages. |
| Yearly check | `SCHOOL_YEAR_START` and the open, grace and first-year settings are configurable, with Cairo dates. Every approved child must be answered. A child who left becomes `left` and leaves the carpools and chats of the owner and of every linked parent. Links end. Reminders go out on the open, start and last days. After the deadline the parent gets no new driving days until they confirm. |
| New phone number | WhatsApp code to the new number with sign-in limits and a separate HMAC key, plus a live selfie (in-app capture) matched to the face reference. A mismatch is refused and reported. The number change runs in Auth first (`phone-number-already-exists` → `phone-taken`). The audit entry has no number. The upload rule allows only the verified owner and `selfie.jpg`, and nobody can read it. |
| New car | Same plate: the earlier approval stays usable until the reviewer decides. A rejected renewal keeps it, and a withdrawn one restores it. New plate: no driving days until review. `applyCarChange` refreshes the car copies, releases runs the car cannot carry, and lowers the creator's carpool seats (never below the children already in it). |
| Prompts 6/7/9/10 | Join and approve keep their checks. Trips use `usableVehicle` for the car card. The map store counts linked children. Notification kinds are in the same order on the server and the app (test updated). |
| Rules and tests | New collections are deny-all, added to the `deny_all` paths, and tested in `tests/rules/trust.test.ts` for the parents named in them and for admins. The users fields stay unwritable. Storage has its own tests. There are 30 Functions tests, plus logic, widget, one-line, admin and screenshot tests. |
| ARB, one line, design | Keys match in both languages. Labels use `OneLineText` and the shared components, which have one-line tests at 320 dp in Arabic and English at 1x and 2x. The star rating has 48-dp targets with screen-reader labels and is in the gallery first. I found no hard-coded sizes or colours in the new screens. |
| Done when | SETUP.md 22.4 covers all three checks: `finishtrip` then Rate parents; `expire` then a refused or released day; admin Suspend opening runs as "driver unavailable". |

## Blocking

None.

## Non-blocking

1. **`child-in-carpool` shows a generic error in the app.**
   - Where: `lib/features/carpools/carpool_models.dart:660-692` has no case
     for it, so it falls to `unknown` → `errorGeneric`. The server throws
     it at `functions/src/carpools/flow.ts:628,699`.
   - Why it matters: the join sheet now offers linked children, so a
     parent who picks a child the other parent already brought gets
     "Something went wrong" with no way to fix it. DESIGN says an error
     should tell the parent how to fix it.
   - Fix: add `CarpoolFailureKind.childInCarpool` and a short Arabic and
     English string such as "This child is already in this carpool with
     the other parent". Better still, leave such children out of the
     picker.

2. **A new grade does not reach linked parents' carpools.**
   - Where: `functions/src/trust/flow.ts:319` updates only the caller's
     memberships.
   - Fix: also call `updateChildGrade` for each live link's
     `guardianUid`, as the "left" branch already does.

3. **The overdue mark can get stuck.**
   - Where: `yearCheckOverdue` is cleared only by `saveYear`. If an
     overdue parent's children all become non-approved (rejected,
     removed), the state becomes `none`, and `confirmSchoolYear` refuses
     with `year-not-open` (`flow.ts:309`). The parent is blocked from
     driving for good.
   - Fix: in `trustDaily`, clear the mark when the state is `none` or
     `done`.

4. **Two ratings for one trip across a month boundary.**
   - A trip on 31 Oct can be rated in October and again on 1 November,
     because the window is 30 days and the limit is per calendar month.
   - Fix: also refuse a second rating for the same `tripId`, or take
     the window from the start of the current month.

5. **Rating manipulation hardening.** None of these is needed for the
   pilot:
   - A flagged rating (2 stars or fewer, or unsafe) counts in the average
     before an admin closes it.
   - Nothing caps how much one carpool can raise a parent's average or
     vouches when its members collude.
   - Once there are 3 or more ratings, the change in the average reveals
     the latest rater's stars to the ratee.
   - Options: hold flagged ratings out of the average until the flag is
     closed as "no issue"; count at most N ratings per carpool per
     quarter; refresh the shown average only weekly.

6. **Guardian request spam and identity.**
   - A declined requester can ask again at once, up to 5 a day
     (`flow.ts:372` allows any non-`requested` status).
   - The accept sheet shows only the first name and relation
     (`family_screen.dart:377`).
   - Suggested fix: add a cool-down after a decline (for example 7
     days), and show the requester's parent ID and Verified badge so the
     owner can confirm it is the real spouse.

7. **The child's parent cannot see where the linked parent took the
   child.**
   - A linked parent can bring the child into carpools and consent to
     drivers. The owner is not told and is not a viewer of those trips.
   - This is by design (decision 5), but the owner should at least be
     told when a linked parent adds the child to a carpool, and could
     see a "Carpools of {child}" list on Family links.

8. **The licence release depends on the daily job and a 3-day window.**
   - Where: `functions/src/trust/jobs.ts:97`.
   - Planning already refuses runs after expiry, so this is only a
     safety net. Reminders fire only on the exact days, so a day the job
     fails is a reminder lost.
   - Fix: release whenever `validUntil < today` and the driver still has
     a run after it, and send a missed reminder when the job sees a
     smaller number of days left.

9. **Data and the lawyer.**
   - Ratings, vouches and guardian links are new personal data. Under
     DECISIONS.md "Legal", they need the lawyer's check, entries on the
     privacy screen and in the consent records, and App Store answers.
   - Account deletion must cover them (progress note open question 2 and
     "Not done"; Prompt 12).
   - The phone-change selfie is deleted at once (`phone.ts:119`), but
     DECISIONS.md lists "live selfie checks" as kept. This is the same
     open point as Prompt 10 review follow-up 4: settle it in the
     data-retention step.

10. **The phone change in prod waits for Valify.**
    - Where: `phoneDeps()` (`trust/callables.ts:176-181`) uses a disabled
      Valify config, as `trips/callables.ts` does. When
      `KYC_PROVIDER` is unset in prod it throws "internal" instead of
      `check-unavailable`.
    - Fix: wire the real Valify config when the contract lands, and map
      `KycNotConfiguredError` to `check-unavailable`.

11. **Carried over:** Prompt 6 review item 7 (report path for the
    free-text activity label and contribution note) is still open, as
    the progress note says.
