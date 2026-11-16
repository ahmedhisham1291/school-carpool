# Data protection impact assessment: live location of runs with children (R11)

Recommended change R11 of docs/legal/answers.md (1.9), approved by the
owner on 16 Nov 2026. Written by the build agent from the code; **not
legal advice**. The DPO reviews it and it goes into the PDPC licence file
(sensitive data: children's whereabouts). Method: GDPR Art. 35 structure
(systematic monitoring, vulnerable data subjects), applied to Law No. 151
of 2020 Art. 3 (purpose, minimisation, storage limitation) and Art. 12
(sensitive data). Reviewed: 16 Nov 2026.

## 1. What is processed

| Item | Detail | Where in the code |
| --- | --- | --- |
| Live points | The driving parent's phone position during a run (geolocator, "While Using the App", precise), sent every few seconds while the run is on | `functions/src/trips/flow.ts` `uploadPoints`, `trips/{id}/points` |
| Last point | The newest position on the trip record, cleared when tracking stops | `trips/{id}.last` |
| Stops and arrival times | Exact home pickup points and the school of that run, arrival estimates | `tripStops/{id}`, `trips/{id}/eta` |
| Route archive | One down-sampled track per run (about one point every 30 s), compressed | Storage `routeArchive/`, `routeArchives/{tripId}` |
| Who | The driving parent (adult) and, by inference, the children on that run (children's data: sensitive, Law Art. 1) | |

Not processed: location outside a run (tracking starts and stops with the
run and never runs in the background otherwise), "Always" location (never
asked), the children's own phones (children do not use the app).

## 2. Purpose and necessity

- **Purpose:** the safety of children on a school run: parents see where
  the car is and when it arrives; the Emergency button sends the point;
  "location stopped" and "child not confirmed" alerts; a safety
  investigation after a report.
- **Necessity:** a school run app without the car's position cannot show
  arrival times or a lost run. Less intrusive options considered: only
  arrival times without a map (rejected: parents need to see a stopped
  car); manual check-ins (kept as well: pickup and drop-off confirmations);
  no archive at all (rejected: reports about dangerous driving or a missed
  handover need the route for a short time).
- **Legal basis:** the driver's consent to location sharing (separate
  consent before the first run) and the guardian's written consent for the
  children's data (R3), plus the PDPC sensitive-data licence (R5: prod
  closed until it is granted).

## 3. Safeguards in place

| Risk | Safeguard | Status |
| --- | --- | --- |
| A stranger follows a car with children | Only that run's driver and the parents of children on the run read the trip and its points (`firestore.rules`, `viewerUids`); verified parents only; App Check | done |
| Location kept longer than needed | Live points deleted within 24 hours (`tripTick` + TTL); `last` cleared at the end; stops 1 day; **route archive 90 days after the run (R11, was 1 year)**; routes of a deleted driver go with the account | done |
| Insider browses routes | Routes readable only by admins through a callable with a fixed reason code, logged first, sign-in < 30 minutes; never shown to parents after the run | done |
| Tracking outside runs | Tracking starts on "Start run" and stops at the end and on sign-out; the server ends forgotten runs; no "Always" permission; the blue indicator shows on iPhone | done |
| Home addresses learned from pickup points | Exact pickup points readable only by approved members of that carpool; others see rounded points | done |
| Location in logs or error reports | Scrubbers remove coordinates from logs and Sentry (`functions/src/scrub.ts`, `lib/observability`) | done |
| Transfer abroad | Firestore and Storage in `europe-west1`; Google Routes (arrival times) receives car and stop points: named in the transfer licence (R10) | owner |
| Breach | 24-hour internal target for children's data (R15), PDPC within 72 hours, register 5 years (R7) | done |

## 4. Residual risk and decision

- **Likelihood of harm:** low (closed groups of ID-verified parents of the
  same school, run-only sharing, short retention).
- **Severity:** high if it happens (children's whereabouts).
- **Residual risk:** medium-low, accepted by the owner on 16 Nov 2026 with
  the 90-day archive. Review when: a new location feature, a change of
  retention, a new processor of location (for example another routing
  service), or a breach.

## 5. Actions

| # | Action | Owner | Status |
| --- | --- | --- | --- |
| 1 | Route archive 1 year -> 90 days | build | done (R11) |
| 2 | Re-apply the Storage lifecycle (`tool/setup_retention.sh`) in staging and prod | owner | open |
| 3 | DPO reviews this DPIA and adds it to the PDPC licence file | owner / DPO | open |
| 4 | Tell the lawyer the archive is now 90 days (the 1-year period was lawyer-confirmed on 14 Nov 2026) | owner | open |
