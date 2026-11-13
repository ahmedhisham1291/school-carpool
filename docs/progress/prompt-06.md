# Prompt 6: Carpools (F5, F6, F25, F26, F31, F32, F36, F39) — progress note

Branch: `prompt-06-carpools` (from `main` with Prompts 1 to 5, the design
refresh and docs/DECISIONS.md). Date: 14 Nov 2026. The coordinator gave
"go" on the owner's behalf.

## Plan

1. Functions (pure flows over a store, Firestore store, callables, unit
   tests): create, search, join request, cancel, approve or decline, leave,
   driver consent, pickup point sharing, invite links, "looking for a
   carpool" posts. Seat and consent logic in one pure module.
2. Rules and rules tests for every new collection; areas open for reading.
3. App: Carpools tab (my carpools), search, create (steps), detail
   (members, children, rules, contribution, consent, requests, invite),
   join sheet, invite landing (`/c/<code>`), "Looking for a carpool".
   Nearby parent card "Join" opens that parent's carpools.
4. Universal links: Hosting site `links` serves
   `apple-app-site-association` and the `/c/<code>` fallback page; the
   Associated Domains entitlement is added by `tool/patch_native.py` only
   when `INVITE_LINK_DOMAIN` is set (SETUP section 16).
5. Seed (cars for fake parents), SETUP, COSTS, DESIGN, tests, screenshots.
