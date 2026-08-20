# radar — Implementation Plan (Phase 0)

Status: planning only. No implementation code written yet.
Spec of record: [SPEC.md](SPEC.md) (verbatim copy of the brief).

---

## 0. Read this first — one blocking finding

**This build environment has no outbound network access to any of the target
APIs.** The egress proxy answers `403` to `CONNECT` for
`rest.arbeitsagentur.de` and `www.arbeitnow.com`; the same is expected for
`remotive.com`, `api.adzuna.com`, `boards-api.greenhouse.io`, `api.lever.co`,
`*.jobs.personio.de`, `*.recruitee.com`, `hn.algolia.com`, `reddit.com`, IMAP
hosts, and `api.anthropic.com`. This is an organisation egress policy, not a
transient failure, and it must not be routed around.

Phase 1 says: *"Verify the live response shape with a single real request
before writing the parser. Do not assume field names."* I cannot do that here.
This is open question **Q1** below and it needs your answer before Phase 1
starts, because every adapter parser depends on it.

Everything else in this plan is unaffected: normalisation, dedup, store,
migrations, registry, CLI, exclusions, scoring plumbing and the whole test
suite are offline-testable against fixtures, which is what the spec demands
anyway ("Fixtures only — never hit live APIs").

---

## 1. Module tree

```
radar/
  __init__.py
  cli.py                    click group: scan score list show sources config-check
  config.py                 load + validate config.toml into pydantic models
  models.py                 RawJob, NormalisedJob, Score, LetterDraft, Enrichment
  logging.py                structured logging setup, one place
  errors.py                 RadarError hierarchy (SourceError, ParseError, ...)
  http.py                   shared httpx client: timeouts, retry/backoff, UA,
                            per-source rate limiter, ETag/If-Modified-Since cache
  runner.py                 scan orchestration: registry -> fetch -> normalise ->
                            dedup -> exclude -> persist; per-source counters
  sources/
    __init__.py             SOURCE registry + dynamic loader
    base.py                 class Source: name, fetch(params) -> list[RawJob]
    arbeitsagentur.py       (Phase 1)
    arbeitnow.py            (Phase 1)
    remotive.py             (Phase 1)
    adzuna.py               (Phase 1, skips cleanly without ADZUNA_* env)
    ats/                    (Phase 2) personio, greenhouse, lever, recruitee,
                            ashby*, workable*, join*   (* = stub until confirmed)
    email/                  (Phase 2) imap client + one parser per sender
    community/              (Phase 3) hackernews, reddit, rss
  normalize/
    __init__.py
    dates.py                epoch-ms | ISO-8601 | German strings -> aware UTC
    locations.py            free text -> {city, postcode, region, country,
                            remote_flag}; PLZ/city lookup table
    employment.py           field + title text -> employment_type enum
    text.py                 whitespace, gender markers, seniority noise, HTML->text
    company.py              legal-suffix stripping, normalised_name
  dedup/
    __init__.py
    fingerprint.py          sha256(normalised(company + title + city))
    url.py                  canonicalisation (strip utm_*, gh_src, ref, source)
    fuzzy.py                rapidfuzz title match, threshold from config
    merge.py                duplicate merge rules + apply_url upgrade by priority
  store/
    __init__.py
    db.py                   connect(), pragmas, transaction helper
    migrations.py           numbered .sql runner + schema_migrations table
    migrations/
      001_initial.sql
      002_....sql           (later phases add, never rewrite 001)
    queries.py              all SQL used by the app, named functions, no ORM
  exclusions.py             case-insensitive title/company matching
  scoring/
    __init__.py
    prefilter.py            Stage 1, haiku, batches of ~20
    detailed.py             Stage 2, sonnet, one call per survivor
    prompts.py              prompt templates + prompt_version constants
    parse.py                strict-JSON parsing, defensive, one retry
    manual.py               outbox/to_score.jsonl <-> outbox/scored.jsonl
    client.py               anthropic wrapper (api mode) / no-op in manual mode
  enrich/                   (Phase 4) company research, TTL cache
  letters/                  (Phase 4) voice extraction, block selection, drafting
  ui/                       (Phase 5) FastAPI app, Jinja2 templates, 127.0.0.1
tests/
  fixtures/                 recorded API payloads, sample emails, feeds
  conftest.py               autouse fixture that hard-fails any real network call
  test_normalize_*.py  test_dedup_*.py  test_config.py  test_store_*.py ...
data/
  plz_de.csv                German postcode/city/region table (see Q7)
templates/                  (Phase 4/5) Jinja/HTML for PDF + UI
outbox/                     manual-mode jsonl exchange (gitignored)
samples/                    unparsed email bodies, writing samples (gitignored)
config.toml                 every tunable
companies.seed.toml         (Phase 2) hand-maintained ATS tenants
profile.md  voice.md  blocks.md
.env.example                every env var, no values
pyproject.toml              uv-managed deps
radar.db                    SQLite, gitignored
```

Rule: `sources/*` may not import `store/*`. Adapters return `RawJob` and
nothing else — persistence is the runner's job. This keeps every adapter
testable with a fixture and no database.

---

## 2. SQLite schema

Managed by numbered migrations in `radar/store/migrations/`. `001_initial.sql`
is the Phase 1 schema below; later phases append new numbered files and never
edit an applied one.

```sql
CREATE TABLE schema_migrations (
  version     INTEGER PRIMARY KEY,
  applied_at  TEXT NOT NULL              -- ISO-8601 UTC
);

-- One row per real-world posting (after dedup).
CREATE TABLE jobs (
  id                 INTEGER PRIMARY KEY,
  fingerprint        TEXT NOT NULL UNIQUE,   -- sha256(company|title|city)
  company_id         INTEGER REFERENCES companies(id),
  company_name       TEXT NOT NULL,          -- as displayed
  company_normalised TEXT NOT NULL,
  title              TEXT NOT NULL,
  title_normalised   TEXT NOT NULL,
  city               TEXT,
  postcode           TEXT,
  region             TEXT,
  country            TEXT,
  remote_flag        INTEGER NOT NULL DEFAULT 0,
  employment_type    TEXT NOT NULL DEFAULT 'unknown',
  description        TEXT,
  language           TEXT,                   -- 'de' | 'en' | NULL
  apply_url          TEXT,                   -- best URL known (see priority)
  apply_url_source   TEXT,                   -- which source supplied it
  posted_at          TEXT,                   -- ISO-8601 UTC, nullable
  first_seen         TEXT NOT NULL,
  last_seen          TEXT NOT NULL,
  source_confidence  REAL NOT NULL DEFAULT 1.0,  -- Phase 3 lowers this
  excluded           INTEGER NOT NULL DEFAULT 0,
  exclusion_reason   TEXT,
  raw                TEXT                    -- JSON of the winning source payload
);
CREATE INDEX idx_jobs_company_city ON jobs(company_normalised, city);
CREATE INDEX idx_jobs_posted ON jobs(posted_at);
CREATE INDEX idx_jobs_excluded ON jobs(excluded);

-- Every source that has ever reported this job. Dedup appends here.
CREATE TABLE job_sources (
  id             INTEGER PRIMARY KEY,
  job_id         INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  source         TEXT NOT NULL,
  external_id    TEXT NOT NULL,
  url            TEXT,
  url_canonical  TEXT,
  first_seen     TEXT NOT NULL,
  last_seen      TEXT NOT NULL,
  raw            TEXT,                       -- JSON payload from this source
  UNIQUE(source, external_id)
);
CREATE INDEX idx_job_sources_job ON job_sources(job_id);
CREATE INDEX idx_job_sources_url ON job_sources(url_canonical);

CREATE TABLE companies (
  id                  INTEGER PRIMARY KEY,
  name                TEXT NOT NULL,
  normalised_name     TEXT NOT NULL UNIQUE,
  ats_type            TEXT,                  -- personio|greenhouse|lever|...
  ats_tenant          TEXT,
  careers_url         TEXT,
  city                TEXT,
  last_checked        TEXT,
  source_of_discovery TEXT,                  -- 'auto:<source>' | 'manual' | 'seed'
  active              INTEGER NOT NULL DEFAULT 1
);

-- Append-only. Latest row per (job_id, stage) is the current verdict.
CREATE TABLE scores (
  id                 INTEGER PRIMARY KEY,
  job_id             INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  stage              TEXT NOT NULL,          -- 'prefilter' | 'detailed'
  verdict            TEXT,                   -- prefilter: 'keep' | 'drop'
  score              INTEGER,                -- detailed: 0-100
  reasoning          TEXT,
  matched_skills     TEXT,                   -- JSON [{skill, evidence_project}]
  missing_keywords   TEXT,                   -- JSON []
  red_flags          TEXT,                   -- JSON []
  employment_type    TEXT,
  hours_per_week     INTEGER,                -- nullable, extracted only
  student_viable     INTEGER,
  remote_arrangement TEXT,                   -- full|hybrid|onsite|unknown
  model              TEXT NOT NULL,
  prompt_version     TEXT NOT NULL,
  mode               TEXT NOT NULL,          -- 'api' | 'manual'
  created_at         TEXT NOT NULL
);
CREATE INDEX idx_scores_job_stage ON scores(job_id, stage, created_at DESC);

CREATE TABLE enrichment (                    -- Phase 4, table created in 001
  id          INTEGER PRIMARY KEY,
  company_id  INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  summary     TEXT,
  size_stage  TEXT,
  tech_stack  TEXT,                          -- JSON []
  recent_news TEXT,                          -- JSON [{fact, url}]
  tone        TEXT,
  hooks       TEXT,                          -- JSON [{hook, url}] — may be []
  sources     TEXT,                          -- JSON [url]
  model       TEXT,
  fetched_at  TEXT NOT NULL,
  expires_at  TEXT NOT NULL
);
CREATE INDEX idx_enrichment_company ON enrichment(company_id, fetched_at DESC);

CREATE TABLE letters (                       -- Phase 4
  id           INTEGER PRIMARY KEY,
  job_id       INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  revision     INTEGER NOT NULL,
  language     TEXT NOT NULL,
  body         TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'draft', -- draft|edited|final
  blocks_used  TEXT,                          -- JSON [block_id]
  sources_used TEXT,                          -- JSON [url]
  instruction  TEXT,                          -- free-text regenerate instruction
  model        TEXT,
  created_at   TEXT NOT NULL,
  UNIQUE(job_id, revision)
);

-- Workflow state, one row per job. Kept out of `jobs` so ingest never
-- touches review state and a re-scan can never reset it.
CREATE TABLE applications (
  id         INTEGER PRIMARY KEY,
  job_id     INTEGER NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
  status     TEXT NOT NULL DEFAULT 'new',
             -- new|scored|drafted|reviewed|applied|rejected|interview
  applied_at TEXT,
  notes      TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE source_health (
  source               TEXT PRIMARY KEY,
  last_attempt         TEXT,
  last_success         TEXT,
  consecutive_failures INTEGER NOT NULL DEFAULT 0,
  last_error           TEXT,
  disabled             INTEGER NOT NULL DEFAULT 0,
  disabled_at          TEXT,
  updated_at           TEXT NOT NULL
);

-- Persistent conditional-request cache (ETag / Last-Modified).
CREATE TABLE http_cache (
  url_hash      TEXT PRIMARY KEY,            -- sha256 of full URL
  url           TEXT NOT NULL,
  etag          TEXT,
  last_modified TEXT,
  status        INTEGER,
  body          BLOB,
  fetched_at    TEXT NOT NULL
);

-- Per-run per-source counters, so `radar sources` and the CLI summary
-- report real numbers instead of recomputing them.
CREATE TABLE scan_runs (
  id         INTEGER PRIMARY KEY,
  started_at TEXT NOT NULL,
  finished_at TEXT
);
CREATE TABLE scan_source_stats (
  run_id    INTEGER NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
  source    TEXT NOT NULL,
  fetched   INTEGER NOT NULL DEFAULT 0,
  new       INTEGER NOT NULL DEFAULT 0,
  duplicate INTEGER NOT NULL DEFAULT 0,
  excluded  INTEGER NOT NULL DEFAULT 0,
  errors    INTEGER NOT NULL DEFAULT 0,
  error_detail TEXT,
  PRIMARY KEY (run_id, source)
);
```

Conventions: all timestamps are ISO-8601 UTC strings (SQLite has no date
type; strings sort correctly and stay readable). Booleans are `INTEGER 0/1`.
`PRAGMA foreign_keys = ON` and `journal_mode = WAL` on every connect.
Excluded rows are flagged, never deleted.

---

## 3. Source registry design

**Declaration** — `config.toml`, one table per source:

```toml
[[sources]]
name     = "arbeitsagentur"
adapter  = "radar.sources.arbeitsagentur:ArbeitsagenturSource"
enabled  = true
priority = 40                 # apply_url tie-break, higher wins
rate_limit_per_sec = 1.0
[sources.params]
terms  = ["Werkstudent Softwareentwicklung", "Werkstudent Marketing", "..."]
rings  = [ {wo = "Marburg", umkreis = 50}, {wo = "Frankfurt am Main", umkreis = 30} ]
veroeffentlichtseit = 14
size = 100
```

**Loading** — `radar/sources/__init__.py` resolves `adapter` with `importlib`,
restricted to the `radar.sources.` prefix (a config file should not be able to
import arbitrary modules), verifies the class subclasses `Source`, and
instantiates it with its `params` validated by that adapter's own pydantic
params model. An unknown adapter, a bad param, or an import error is a
config-check failure, not a crash at scan time — `radar config-check`
resolves and validates every declared source without making a request.

**Interface** — `radar/sources/base.py`:

```python
class Source(Protocol):
    name: str
    ParamsModel: type[BaseModel]
    def fetch(self, params: BaseModel) -> list[RawJob]: ...
```

`RawJob` is exactly the spec's field list: `source, external_id, title,
company, location, url, description, employment_type, posted_at, raw`.
`location` and `employment_type` stay raw strings here; normalisation happens
downstream, so an adapter never needs to know about the PLZ table.

**Isolation** — the runner wraps each `fetch` in its own try/except catching
`Exception` (never bare `except:`), logs with the source name, increments
`source_health.consecutive_failures`, records the error against that source's
`scan_source_stats` row, and continues to the next source. A partial failure
inside an adapter (one page of ten fails) is the adapter's own business: it
returns what it has and raises only if it got nothing usable.

**Health / auto-disable** — after `sources.max_consecutive_failures` (config,
default 5) the source is marked `disabled = 1` and skipped on later runs;
`radar sources` shows the table and `radar sources --enable <name>` clears it.
A success resets the counter to 0.

**Politeness** — one shared `httpx.Client` per process, configured centrally
in `radar/http.py`:

- explicit connect/read/write/pool timeouts from config (no unbounded calls),
- token-bucket rate limiter keyed by source,
- retry with exponential backoff + jitter on 429 and 5xx only, honouring
  `Retry-After`, capped attempts from config; 4xx other than 429 fails fast,
- `User-Agent: radar/<version> (personal job search; +contact)` — see Q14,
- conditional requests from `http_cache`: send `If-None-Match` /
  `If-Modified-Since` when stored, treat `304` as "unchanged, reuse body".

Adapters never construct their own client.

---

## 4. Dedup strategy

Applied per incoming `RawJob` after normalisation, inside one transaction.

**Tier 1 — fingerprint (authoritative).**
`sha256(normalise_company(company) + "|" + normalise_title(title) + "|" +
normalise_city(city))`, where normalisation:

- lowercases and NFKC-normalises, transliterates umlauts consistently
  (`ä→ae`, `ö→oe`, `ü→ue`, `ß→ss`),
- company: strips legal suffixes `GmbH, mbH, AG, SE, UG (haftungsbeschränkt),
  KG, & Co. KG, GmbH & Co. KG, e.K., e.V., OHG, Ltd, Inc, B.V., N.V.,
  S.à r.l.` and trailing punctuation,
- title: removes gender markers `(m/w/d) (m/w/x) (w/m/d) (m/f/d) (all genders)
  *in :in _in /-in`, removes seniority/noise tokens (`junior, senior, working
  student, (Vollzeit), (Teilzeit), m/w/d`, bracketed location suffixes,
  req-IDs), collapses whitespace and separators,
- city: empty/remote-only → the literal `remote` bucket, so two remote
  postings from the same company with the same title still collide.

All token lists live in `config.toml` under `[dedup]`, not in code.

**Tier 2 — canonical URL.** Lowercase scheme/host, drop `www.`, drop
`utm_*`, `gh_src`, `ref`, `source`, `trk`, `lang`, `fbclid`, `gclid`, sort
remaining params, strip trailing slash and fragment. Looked up against
`job_sources.url_canonical`. Catches the same posting whose title differs
enough to miss Tier 1.

**Tier 3 — fuzzy title.** Only among candidates already matching
`company_normalised` **and** `city` exactly: `rapidfuzz.fuzz.token_set_ratio`
over the normalised titles, threshold from config (default 92). Deliberately
conservative — a false merge loses a real job, which is worse than a
duplicate row.

**On duplicate:**
1. keep the existing `jobs` row; update `last_seen`;
2. insert or update the `job_sources` row for the new source (its own
   `external_id`, url, raw payload);
3. fill in fields the existing row is missing (a longer description, a
   `posted_at`, a resolved city) — never overwrite a non-empty field with an
   empty one;
4. upgrade `apply_url` only if the new source's `priority` in config exceeds
   `apply_url_source`'s. Direct ATS sources get the highest priority band
   (e.g. ATS 90-99 > company careers 80 > Arbeitsagentur 40 > aggregators
   20-30 > email alerts 10), so an ATS link always displaces an aggregator
   link and never the other way round.

**Idempotence.** `job_sources UNIQUE(source, external_id)` plus the
fingerprint uniqueness means a second identical scan performs only
`last_seen` updates: 0 new. There will be a test that runs the same fixture
scan twice and asserts `new == 0` on the second pass.

---

## 5. Scoring plumbing (Phase 1, both modes)

- `radar score` selects jobs with no current `prefilter` row and not excluded,
  batches ~20 (config), Stage 1 → `keep`/`drop` + one-line reason. `drop` is
  recorded as a score row, not an `excluded` flag: exclusions are your rules,
  prefilter is the model's opinion, and they should stay distinguishable.
- Survivors go to Stage 2, one call each, full text.
- **api mode**: anthropic SDK, `max_tokens` and models from config
  (`claude-haiku-4-5-20251001`, `claude-sonnet-5`).
- **manual mode**: `outbox/to_score.jsonl` written with one request object per
  line (`{job_id, stage, prompt_version, payload}`); `radar score --collect`
  reads `outbox/scored.jsonl` (`{job_id, stage, result}`), validates each
  result against the same pydantic model the api path uses, and writes to
  `scores`. Same prompts, same parser, same table — the only difference is
  who executes the call.
- Both prompts end with a hard "output JSON only, no prose, no code fences"
  instruction; the parser strips accidental fences, tries `json.loads`, and on
  failure retries once with the malformed output quoted back. A second failure
  records a parse error against the job rather than raising.
- `hours_per_week` is extracted from the text only. Never inferred from the
  title. Unstated → `null`, `student_viable = true`, uncertainty stated in
  `reasoning`.
- Rubric weights (remote > breadth > automation relevance > student fit) live
  in the prompt, and the prompt file carries a `prompt_version` string that is
  stored with every score so re-scores are comparable.

---

## 6. Phase 1 build order

1. `pyproject.toml` + uv, package skeleton, logging, errors.
2. config loading + pydantic models + `radar config-check` + tests.
3. store: db, migration runner, `001_initial.sql`, queries + tests.
4. normalize: dates, text, company, locations, employment + tests.
5. dedup: fingerprint, url, fuzzy, merge + idempotence test.
6. exclusions + tests.
7. http layer: timeouts, backoff, rate limit, ETag cache.
8. registry + base + runner with per-source isolation and health.
9. the four adapters — **gated on Q1**.
10. scoring: prompts, parser, manual mode, api mode.
11. CLI surface + README + fixtures + full test pass.

Steps 1-8 and 10-11 are fully buildable offline today.

---

## 7. Open questions

Blocking ones first.

**Q1 — API verification (blocks Phase 1 adapters).** No network here (§0). Pick one:
  (a) you run a small read-only probe script I provide, on your machine, and
      paste the JSON back — I then write parsers against real shapes;
  (b) you paste one sample response per source yourself;
  (c) I write the parsers from documented shapes, defensively (unknown fields
      ignored, every field access tolerant), mark each clearly as
      `UNVERIFIED` in code and in the report, and you verify on first run.
  My recommendation: (a) for Arbeitsagentur (its v4 shape is the one most
  likely to bite), (c) for the other three.

**Q2 — profile.md.** Scoring reads it from Phase 1 onward. Will you write it,
or do you want me to generate a skeleton with the sections the scorer needs
(projects with what you shipped and which stack, skills, availability,
languages, formal history) for you to fill in?

**Q3 — Anthropic API key + default mode.** Is `ANTHROPIC_API_KEY` available
locally, and should `scoring.mode` default to `manual`? Manual costs nothing
and matches how you'll likely run it at first; I'd default to `manual`.

**Q4 — Search terms and rings.** Arbeitsagentur takes exactly one `was` per
request, so the cost is `len(terms) × len(rings)` requests per scan. Give me
your term list, or approve a starter set (Werkstudent Softwareentwicklung /
Webentwicklung / Marketing / Automatisierung / Digitalisierung / IT, plus
"Werkstudent remote") × rings (Marburg+50km, Frankfurt+30km, remote/bundesweit).

**Q5 — Rhein-Main definition.** Which cities count as acceptable-hybrid?
Proposed: Frankfurt, Offenbach, Eschborn, Wiesbaden, Mainz, Darmstadt, Hanau,
Bad Homburg, Rüsselsheim. Add or remove?

**Q6 — Exclusion seeds.** Confirm the starter list: pharma/production
(Verfahrenstechnik, Pharmatechnik, Produktion, GMP, Labor, Chemie, Biotech,
Reinraum, Fertigung, Instandhaltung), staffing (Zeitarbeit, Personaldienst,
Randstad, Adecco, Hays, Manpower, Orizon, Tempton), sales (Vertrieb,
Außendienst, Sales Manager, Account Executive, Telefonakquise). Note this
matches substrings case-insensitively, so "Vertrieb" also kills
"Vertriebsinnendienst" — intended?

**Q7 — PLZ dataset.** Location resolution wants a German postcode/city/region
table. I can't download one here. Options: you drop a CSV into `data/`
(OpenPLZ or the Zuordnung PLZ-Ort-Bundesland dataset, ~8k rows), or I
hand-write a starter table covering Hessen + the ~60 largest DACH cities and
degrade gracefully (unknown city → stored verbatim, region `null`). Preference?

**Q8 — rapidfuzz.** The spec names it and also says "prefer stdlib".
`difflib.SequenceMatcher` would avoid the dependency but is slower and has no
`token_set_ratio` equivalent. I'd take rapidfuzz. Confirm?

**Q9 — Adzuna credentials.** `ADZUNA_APP_ID` / `ADZUNA_APP_KEY` — do you have
them? Without them the adapter registers and skips cleanly with a log line.

**Q10 — Repo layout.** This repo currently holds unrelated
`Vantom-Suite-releases` content (`README.md`, `brand/icon_big.ico`). Should
radar live at the repo root next to it (current assumption), in a `radar/`
subtree of its own, or should the old files be removed? I have not touched
them.

**Q11 — ATS discovery vs "never scrape" (Phase 2, flagging early).** Automatic
ATS discovery means fetching a company's apply URL and following redirects to
read the *final hostname*. That's an HTTP request to a job board page, though
it parses no page content. My reading is that this is within the rule (host
detection, not content extraction), but it sits close to the line — confirm,
or restrict discovery to `companies.seed.toml` + manual `radar company add`.

**Q12 — weasyprint (Phase 4).** It needs system libraries (pango, cairo,
gdk-pixbuf). If those aren't installable on your machine the fallback is
`--print-to-pdf` via a headless browser, which is another dependency. Worth
knowing before Phase 4; no action needed now.

**Q13 — Stale jobs.** Should a job not seen for N days be marked stale
(hidden from `list` by default, still in the DB)? Postings expire and the
queue will otherwise fill with dead links. Proposed default: 30 days.

**Q14 — User-Agent contact string.** A polite UA usually carries a contact.
Do you want your email in it, a GitHub URL, or neither (just
`radar/0.1 (personal job search)`)?

**Q15 — Git tags and pushes.** Tag `phase-N` per the spec — confirm plain
lightweight tags on `claude/radar-job-search-pipeline-si9dln`, pushed with
the branch, and that you do *not* want a PR opened.

Non-blocking notes:

- `applications` holds review state (status/applied_at/notes) rather than
  `jobs`, so re-scans can never clobber it. Say if you'd rather have it on
  `jobs`.
- `scores` is append-only; the UI and CLI read the newest row per
  (job, stage). This keeps re-scores after a prompt change comparable.
- The test suite will include an autouse fixture that makes any real socket
  connection fail, enforcing "fixtures only" mechanically.
