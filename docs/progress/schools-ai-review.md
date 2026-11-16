# schools-ai-review (16 Nov 2026)

Branch `schools-ai-review` off origin/schools-fixes (723aee2). Owner: the
name review runs automatically inside the Cloud Shell run.

## Built

- `tools/import_schools/ai_review.py`: kept schools from
  build/schools/review_input.csv (one entity per school; merged entries
  inside it), 5 nearest kept schools within 2 km per school (computed
  locally; positions never sent), batches of 150 by governorate, Vertex AI
  REST with `gcloud auth print-access-token`, strict answer validation
  (verdict ok | drop | rename | merge_with | kind; merge only into the batch
  or the school's neighbours; a rename must keep the old name's words or
  their sounds, never a new name), threshold 0.8, call cap 200 with an
  estimated cost, cache in Firestore schoolReview/{school id} (hash of what
  was sent + model), build/schools/ai_review.csv and ai_decisions.csv.
- Importer: `--ai-decisions`; manual decisions win per entry; AI drops have
  reason "ai_drop"; the summary counts AI decisions apart.
- Loader: unchanged rules protect admin-edited and parents' schools (not
  hidden, not renamed, survivor of a merge); hidden, never deleted.
- firestore.rules: schoolReview denied to clients; rules test; privacy
  coverage entry (not personal).
- Step 12: AI review between the import and the load, then the import again
  with its decisions; to-do when Vertex is not reachable; step 1 enables
  aiplatform.googleapis.com.

## Model and endpoint (checked 16 Nov 2026)

- gemini-3.8-flash: GA (2 Sep 2026), locations global, us, eu,
  northamerica-northeast1, asia-northeast1; structured output supported;
  thinking levels LOW / MEDIUM / HIGH. Default location "eu" (nearest
  multi-region; europe-west1 not listed for it); 404 -> "global".
- Claude on Vertex: claude-haiku-5-5, hosts global / aiplatform.{us,eu}.rep /
  {region}-aiplatform, body anthropic_version "vertex-2023-10-16", :rawPredict.

## Not run here

No Google Cloud access: Vertex calls and the Firestore REST cache are
tested with fakes only. Rules tests written, not run (emulators). Python
(136) and Functions (842) tests run and pass.

## Validator review (16 Nov 2026)

docs/reviews/schools-ai-review.md: PASS after fixes B1-B5 (Gemini default
temperature; AI merges re-checked against the dedupe guards and manual
"separate"; stricter rename check; injection guard with suspicious batches;
a failed run keeps earlier AI decisions so nothing hidden comes back).
