# Algolia: school search over every school (owner guide)

Staging now holds every school and kindergarten in Egypt that OpenStreetMap
knows (tens of thousands). The app's built-in search can only look at 200
schools, so with the real list it says "search unavailable" until Algolia
is set up. Algolia is the search service in our plan (CLAUDE.md, STACK);
you accepted a paid plan if one is ever needed (DECISIONS.md, 15 Nov 2026).

Time: about 10 minutes. You need: an email address, and Google Cloud Shell
(the same place you run `tool/cloud_setup.sh`).

**Never paste an Algolia key into a chat, an email, a document or GitHub.**
The setup script asks for the keys with hidden typing and stores them in
Google Secret Manager. The developer never needs to see them.

## 1. Create the account and the application

1. Open <https://www.algolia.com> and sign up (the free plan, no card).
2. Algolia creates a first **application** for you (or asks you to create
   one). Name it `school-carpool`. **If it asks for a region, pick one in
   Europe** (closest to Egypt and to our Firebase region, europe-west1).
3. You do not need to create an index: the setup script creates
   `schools_staging` and its settings (Arabic and English, typo tolerance).

## 2. Find the three values

In the Algolia dashboard: **Settings** (gear) > **Team and Access** >
**API keys**. The page shows:

| On the page | What it is | Secret? |
| --- | --- | --- |
| **Application ID** | about 10 letters and digits | No |
| **Search API Key** (also called Search-only API key) | lets someone search only | Yes |
| **Write API Key** | lets the server add and remove schools in the index and change its settings | Yes |

Do **not** use the **Admin API Key**: the script refuses it as the search
key (the app's one-hour search keys are made from the search key and
inherit its rights) and does not need it as the write key.

## 3. Give them to the setup script

In Cloud Shell, run the same command as always:

```sh
cd ~/school-carpool && git checkout -- . && git pull
bash tool/cloud_setup.sh staging school-carpool-staging <your-admin-email>
```

At step 6 it asks:

1. `Algolia Application ID`: type or paste it, press Enter.
2. `Algolia Write API Key (hidden...)`: paste it (nothing shows), Enter.
3. `Algolia Search-only API Key (hidden...)`: paste it (nothing shows), Enter.

It checks both keys with Algolia, stores them in Secret Manager, switches
staging to Algolia, deploys the functions, and at step 12 loads the
schools and sends them all to Algolia. At the end it prints three lines
under **NON-SECRET SEARCH SETTINGS** (`SCHOOL_SEARCH_PROVIDER=algolia`,
`ALGOLIA_APP_ID=...`, `ALGOLIA_INDEX=schools_staging`): copy those three
lines (they are not secret) to the developer so they are committed.

- **Press Enter without typing an ID** to skip Algolia for now. Search then
  covers only 200 schools, and with the real list the app says "search
  unavailable".
- A key you typed wrongly: the script says why and stores nothing; run it
  again.
- To change keys later: add `--replace-algolia` at the end of the command.
  Without it, stored keys are never replaced.

## 4. Optional hardening (recommended before the pilot)

The dashboard's default keys work for every index of the application. For
staging that is fine. Before prod, in **API keys > All API keys > New API
key**, make two keys limited to the index (SETUP.md 14.4):

- write: index `schools_staging`, rights `addObject`, `deleteObject`,
  `editSettings` (`search` too, so the script can check it);
- search: index `schools_staging`, right `search` only, **Max queries per
  IP per hour 100**, max hits per query 20 (the app's keys carry a hashed
  user token, so Algolia counts the limit per parent).

Then run the script with `--replace-algolia` and give it those two keys.

## Free plan and when we would pay

Read on algolia.com on 15 Nov 2026 (the plan Algolia used to call "Build"
is now called **Free**):

| | Free plan | Grow (pay as you go) |
| --- | --- | --- |
| Search requests | 10,000 a month | 10,000 a month included, then USD 0.50 per 1,000 |
| Records (one school = one record) | 50,000 | 100,000 included, then USD 0.40 per 1,000 |
| Indexes | 20 per application | |

- **Records:** Egypt's OpenStreetMap list is expected to be about 20,000
  to 30,000 schools after cleaning: **it fits the Free plan** with room to
  spare. Staging and prod together (two indexes in one application) can
  pass 50,000 only if the list grows a lot; then Grow costs about USD 0.40
  per extra 1,000 schools a month.
- **Searches:** one school search is 2 to 4 requests (the app waits for 2
  letters and a pause, and caches answers for 10 minutes). 10,000 a month
  covers roughly 1,000 parents registering in a month. Above that, Grow
  costs USD 0.50 per extra 1,000 requests.
- **Upgrade when:** the dashboard's Usage page shows 8,000 searches in a
  month or 40,000 records (docs/COSTS.md).

Sources: algolia.com/pricing and algolia.com/pricing/grow-plan (read 15
Nov 2026). Prices can change; check the pricing page before upgrading.
