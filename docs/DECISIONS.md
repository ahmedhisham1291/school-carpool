# Owner decisions

Decisions the owner has confirmed. Build agents follow these; ask before changing one.

## Legal (confirmed by the owner's lawyer, 14 Nov 2026)

The owner reports that the lawyer confirmed all of the following are allowed without issues:

1. **Schools list licence (ODbL):** using the OpenStreetMap / HDX schools data with the
   attribution on the About screen.
2. **Operating entity and licence:** running the parent-to-parent carpool app.
3. **Hosting abroad:** storing the data in Google Cloud `europe-west1` (Belgium).
4. **IDs and children's data:** collecting national IDs, selfies, children's details and
   locations with the consent screens in the app, and keeping ID images up to 7 days after review.
5. **Wallet:** the wallet run by a payment partner licensed by the Central Bank of Egypt.
6. **Liability:** terms of use and code of conduct as planned.

Keep the lawyer's written answers with the company records. If a later prompt changes how any of
these work (for example a new data type, a longer retention period or a new country for hosting),
check with the lawyer again.

## Product and build

- Design: direction A (teal), refreshed; every label, button, tab, chip and title on one line.
- CI checks on GitHub Actions; Codemagic only for iPhone builds.
- Bundle ID base `org.schoolcarpool.app`; Firebase region `europe-west1`.
- Free tier first for every service; upgrade when the usage limit is reached.
- `shared_preferences` approved.
- Algolia (14 Nov 2026): stay on the free plan while usage fits, then switch to the
  pay-as-you-go Grow plan ($0.50 per extra 1,000 searches). The free plan's limit is
  10,000 searches a month (not users), so watch the monthly search count in COSTS.md
  and switch when it nears the limit.
