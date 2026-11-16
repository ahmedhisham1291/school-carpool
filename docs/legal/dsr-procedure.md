# Data subject requests (privacy requests): procedure

Law No. 151 of 2020: the controller answers a data subject's request within
**six working days**. We use: Cairo working days Sunday to Thursday;
**public holidays are counted as working days** (gives an earlier deadline,
never a later one). Code: `responseDueAt`, `slaOf`, `adminQueue` in
`functions/src/privacy/requests.ts`; tests `functions/test/dsr.test.ts`.
Not legal advice.

## What is answered at once by the app

See, download (export), correct own fields, withdraw a consent, switch
analytics, delete the account: the app does these immediately and logs a
`privacyRequests/{id}` record (status `done`, kept 3 years).

## What waits for an admin (the queue)

Corrections of ID details (name, ID number, birth date), copies of photos,
anything else the app cannot do alone, and requests by email to the
support/DPO address.

1. Every request gets `dueAt` = 6 working days after it arrives.
   Email requests: an admin logs them in the panel the same day (or
   reply by email and keep the email; the clock starts when we receive it).
2. Admins open the queue (callable `adminListPrivacyRequests`): sorted
   most urgent first, each with `sla` = `onTime`, `dueSoon` (less than
   one day left) or `overdue`, plus the `overdue` count. Until the panel
   screen exists (open item D13), use the Firebase console query
   `privacyRequests where status == "open" order by dueAt`.
3. Check identity: the request comes from the signed-in account; for
   email requests ask the parent to send it from the app.
4. Do it, or refuse with a reason the law allows (e.g. the data is needed
   for an open safety case), then close it with `adminClosePrivacyRequest`
   (`done` / `refused`; audit-logged).
5. Daily: the owner or DPO checks that `overdue` is 0. An overdue request
   is reported to the DPO the same day.

## Not yet built (open)

- Admin panel screen for the queue (D13).
- An automatic daily alert when a request becomes overdue.
- Showing "answer due by" to the parent on "Your requests" (the server
  already sends `dueAtMs`).
