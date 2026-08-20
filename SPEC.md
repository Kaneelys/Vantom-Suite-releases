Build "radar", a personal job-search pipeline. Read this entire spec 
before doing anything. It describes six phases. Build them ONE AT A 
TIME, stopping after each for my approval.

═══════════════════════════════════════════════════════════════
PHASE 0 — PLAN (do this first, write no implementation code)
═══════════════════════════════════════════════════════════════
1. Save this spec verbatim as SPEC.md in the repo root.
2. Write PLAN.md: module tree, SQLite schema, source-registry 
   design, dedup strategy, and every open question you have for me.
3. Write CLAUDE.md: project purpose, stack, conventions, and an 
   empty "Decisions" section you will append to after each phase.
4. git init, commit these three files.
5. STOP. Present PLAN.md and wait for my approval.

After every later phase: run tests, update CLAUDE.md's Decisions 
section, git commit with tag phase-N, report what you built and what 
you deliberately left out, then STOP and wait.

═══════════════════════════════════════════════════════════════
CONTEXT
═══════════════════════════════════════════════════════════════
Single user, runs locally, German job market (DACH).
I am a student seeking Werkstudent roles, secondarily part-time or 
entry-level full-time. Base: Marburg, Hessen. Remote strongly 
preferred; hybrid acceptable in Rhein-Main at max 2 office days/week.
Profile: generalist who independently ships digital products — 
design, frontend, backend, deployment, marketing, automation.

The pipeline aggregates postings from many sources, deduplicates, 
scores them against my profile, researches the company, and drafts a 
cover letter in my writing voice. I review everything in a local web 
UI and submit each application MYSELF.

═══════════════════════════════════════════════════════════════
ABSOLUTE CONSTRAINTS — never violate, in any phase
═══════════════════════════════════════════════════════════════
- NEVER build browser automation, form filling, or any code that 
  submits an application. The pipeline stops at "reviewed and ready".
- NEVER scrape HTML job boards. Use only: documented APIs, public 
  ATS feeds, RSS/Atom, and emails delivered to my own mailbox.
- NEVER put credentials in code or config. Environment variables 
  only, documented in .env.example.
- Generated cover letters may ONLY assert facts present in 
  profile.md. No invented experience, no inflated claims, no 
  fabricated enthusiasm about specifics you cannot verify. If a 
  requirement is unmet, address it honestly or omit it.
- Every network call: timeout, explicit error path, no bare except.

═══════════════════════════════════════════════════════════════
STACK
═══════════════════════════════════════════════════════════════
Python 3.11+, uv for deps, SQLite via stdlib sqlite3 (no ORM),
httpx, click (CLI), pydantic (models), FastAPI + Jinja2 (Phase 5),
weasyprint (PDF), feedparser (RSS), imaplib + BeautifulSoup (email),
anthropic SDK. Keep dependencies minimal. Prefer stdlib.

Layout:
  radar/
    sources/        one adapter per source, uniform interface
    store/          schema, queries, migrations
    normalize/      dates, locations, employment types
    dedup/          hashing + fuzzy matching
    scoring/        prefilter + detailed
    enrich/         company research
    letters/        voice extraction + generation
    ui/             FastAPI app (Phase 5)
    cli.py
  config.toml       every tunable, no magic numbers in code
  profile.md        my CV, skills, projects — scoring reads this
  voice.md          my writing style, generated in Phase 4
  blocks.md         reusable cover-letter paragraphs

═══════════════════════════════════════════════════════════════
PHASE 1 — FRAMEWORK + API SOURCES
═══════════════════════════════════════════════════════════════

SOURCE REGISTRY
Sources are declared in config.toml, not hardcoded. Each entry names 
an adapter class and its params; the registry loads them dynamically.
Uniform interface: fetch(params) -> list[RawJob].
RawJob: source, external_id, title, company, location, url, 
description, employment_type, posted_at, raw(dict).
Sources are isolated: any exception is caught, logged, recorded 
against that source, and the run continues. Per-source health 
(last_success, consecutive_failures) lives in the DB; a source auto-
disables after N failures (configurable) and `radar sources` shows 
status.
Global politeness: per-source rate limit, exponential backoff on 429 
and 5xx, a descriptive User-Agent, and a persistent HTTP cache using 
ETag/If-Modified-Since where supported.

ADAPTERS FOR THIS PHASE
1. Arbeitsagentur
   Base https://rest.arbeitsagentur.de/jobboerse/jobsuche-service
   Header "X-API-Key: jobboerse-jobsuche"
   Search GET /pc/v4/app/jobs — params was, wo, umkreis, arbeitszeit, 
   veroeffentlichtseit, angebotsart, zeitarbeit, page, size
   Detail GET /pc/v4/jobdetails/{base64(refnr)}
   Accepts exactly ONE `was` per request → iterate the cartesian 
   product of (search ring x term) and merge.
   Verify the live response shape with a single real request before 
   writing the parser. Do not assume field names.
2. Arbeitnow — https://www.arbeitnow.com/api/job-board-api (paginated)
3. Remotive — https://remotive.com/api/remote-jobs?search=
4. Adzuna — API key from env; skip cleanly if absent.
Confirm each endpoint is live before building against it. If one has 
changed or died, say so and stub it rather than guessing.

NORMALIZE
Dates → UTC datetime (feeds use epoch ms, ISO, and German strings).
Locations → {city, postcode, region, country, remote_flag}, resolved 
against a German city/postcode table; handle "Remote", "Homeoffice", 
"bundesweit", multi-city strings, and empty values.
Employment type → enum: werkstudent | praktikum | teilzeit | 
vollzeit | freelance | unknown, inferred from field AND title text.

DEDUP
Primary key: sha256 of normalised(company + title + city).
Normalisation lowercases, strips legal suffixes (GmbH, AG, SE, mbH, 
& Co. KG, UG), removes gender markers ((m/w/d), (m/w/x), *in, :in), 
removes seniority noise, collapses whitespace.
Secondary: canonicalised URL (strip utm_*, gh_src, ref, source).
Tertiary: fuzzy title match (rapidfuzz, configurable threshold) when 
company and city already match exactly.
On duplicate: keep the existing row, append the new source to a 
sources list, and upgrade the stored apply_url if the new source 
ranks higher in config's source_priority. Direct ATS links always 
outrank aggregator links.
Running the same scan twice must insert nothing new.

STORE
Tables: jobs, job_sources, companies, scores, enrichment, letters, 
applications, source_health.
jobs keeps first_seen, last_seen, raw JSON, excluded flag + reason.
Excluded rows are never deleted — `radar list --excluded` shows them 
so I can tune rules.
Write a tiny migration mechanism (numbered .sql files); do not 
rely on recreating the DB.

EXCLUSIONS
Applied after ingest, before scoring, as case-insensitive string 
matching on title and company, configured in [exclusions].
Purpose: strip process-engineering/pharma/production noise (Marburg 
is a pharma town), staffing agencies, and sales roles.

SCORING
Two stages, both reading profile.md.
Stage 1 prefilter — claude-haiku-4-5-20251001, batches of ~20, 
title + company + location + first 500 chars. Returns keep/drop + 
one-line reason.
Stage 2 detailed — claude-sonnet-5, one call per survivor, full text.
Returns strict JSON:
  score 0-100
  reasoning
  matched_skills: [{skill, evidence_project}]   ← cite the project 
                                                  from profile.md 
                                                  that proves it
  missing_keywords
  red_flags
  employment_type
  hours_per_week (int|null, extracted; never inferred from title)
  student_viable (bool)
  remote_arrangement: full | hybrid | onsite | unknown
student_viable = false if hours_per_week > config max_hours_week 
(20, the German Werkstudentenprivileg limit) or full-time term 
availability is required. Unstated hours → null + viable, with the 
uncertainty noted in reasoning.

RUBRIC, in weight order:
1. Remote arrangement (full > hybrid-in-Rhein-Main > onsite).
2. Breadth fit — postings valuing cross-disciplinary ownership 
   outrank deep-specialist roles.
3. Process/automation/digitalisation relevance.
4. Student fit — werkstudent > praktikum > teilzeit > vollzeit.
Treat shipped projects in profile.md as at least equal in weight to 
formal employment history; I have little of the latter.

SCORING MODE
config scoring.mode = "api" | "manual".
"api": call the Anthropic API directly.
"manual": write pending jobs to outbox/to_score.jsonl and read 
results from outbox/scored.jsonl, so an interactive Claude Code 
session can do the scoring instead of paid API calls.
Both modes write to the same scores table.
Both prompts must demand JSON only — no prose, no markdown fences — 
and parse defensively with a retry on malformed output.

CLI
radar scan | score | list | show <id> | sources | config-check
`list` supports --min-score --max-age --student-only --remote-only 
--excluded. Every command prints per-source counts: fetched / new / 
duplicate / excluded / error.

TESTS: normalisation, dedup, URL canonicalisation, employment-type 
inference, config loading. Fixtures only — never hit live APIs.

═══════════════════════════════════════════════════════════════
PHASE 2 — ATS FEEDS + COMPANY REGISTRY + EMAIL
═══════════════════════════════════════════════════════════════
This is the highest-signal layer: ATS feeds carry postings days 
before aggregators, and small companies often never post elsewhere.

ATS ADAPTERS (all public, no auth)
  Personio    GET https://{tenant}.jobs.personio.de/xml?language=de
              (also try .com; XML, one document, all positions)
  Greenhouse  GET https://boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true
  Lever       GET https://api.lever.co/v0/postings/{slug}?mode=json
  Recruitee   GET https://{slug}.recruitee.com/api/offers/
  Ashby, Workable, Join — implement if you can confirm the current 
  public endpoint; otherwise stub with a clear TODO.
Verify each against one real tenant before writing its parser.

COMPANY REGISTRY
companies table: name, normalised_name, ats_type, ats_tenant, 
careers_url, city, last_checked, source_of_discovery, active.
Discovery, automatic: for each company seen in any source, fetch its 
apply URL, follow redirects, and detect the ATS from the final host 
(jobs.personio.de, boards.greenhouse.io, jobs.lever.co, 
.recruitee.com, jobs.ashbyhq.com, apply.workable.com, join.com). 
Extract the tenant slug and store it. From then on poll that tenant 
directly on every scan.
Discovery, manual: `radar company add --name X --ats personio 
--tenant y` and a seed file companies.seed.toml I fill in by hand.
`radar company scan` re-checks known companies for ATS changes.

EMAIL SOURCE (IMAP)
Reads a dedicated mailbox that receives job alerts. Credentials from 
env only. One parser per sender, dispatched on From-address:
StepStone, Indeed, LinkedIn, Xing, Absolventa, Jobmensa, Workwise, 
get-in-it, Berufsstart, Praktikum.info, Stellenanzeigen.de, Instaffo.
Each extracts title, company, location, destination URL from the 
HTML body; strips tracking params; resolves redirect wrappers to the 
real target URL.
Unknown sender → log, skip, save the raw body to samples/ so a 
parser can be written later. Never raise.
Mark read only after successful parsing. Parsers are tested against 
saved fixture emails, never a live mailbox.

Note in the report which senders you could not implement without 
sample emails from me.

═══════════════════════════════════════════════════════════════
PHASE 3 — COMMUNITY + RSS
═══════════════════════════════════════════════════════════════
Hacker News via the free Algolia API 
(https://hn.algolia.com/api/v1/search) — parse the monthly 
"Ask HN: Who is hiring?" threads, filter comments for Europe/remote.
Reddit via PRAW (official API, credentials from env): r/forhire, 
r/germanyjobs, r/cscareerquestionsEU, r/remotework. Subreddits 
configurable.
Generic RSS/Atom adapter driven purely by config (feed URL + field 
mapping), so I can add feeds without code.
These sources are noisy: route everything through the prefilter with 
a stricter threshold, and tag rows with a low source_confidence that 
the scorer takes into account.

═══════════════════════════════════════════════════════════════
PHASE 4 — VOICE + ENRICHMENT + COVER LETTERS
═══════════════════════════════════════════════════════════════

VOICE EXTRACTION
`radar voice build` reads everything in samples/writing/ (texts I 
have written myself) and produces voice.md: sentence length and 
rhythm, formality register, Sie/Du default, typical openings and 
closings, vocabulary I favour and avoid, structural habits, degree 
of directness. Descriptive, not prescriptive — it must capture how I 
actually write, not how a cover letter is "supposed" to sound.
voice.md is a plain editable file; I will hand-correct it and that 
correction must survive re-runs (write to voice.generated.md and 
merge only on explicit --overwrite).

COMPANY ENRICHMENT
Once per company, not per job. Cached in the enrichment table with a 
TTL. Uses the Anthropic API with the web_search tool enabled:
  tools: [{"type": "web_search_20250305", "name": "web_search"}]
Produces: what the company does in one sentence, size and stage, 
tech stack if discoverable, recent news or launches, tone of their 
own public writing, and two or three specific, verifiable hooks a 
cover letter could reference.
Explicitly instruct the model to return only facts it found and to 
return an empty hooks list rather than inventing plausible ones. 
Store the source URLs alongside each fact so I can verify.
In scoring.mode = "manual", enrichment writes a request file to 
outbox/ the same way scoring does.

COVER LETTER GENERATION
Inputs: profile.md, voice.md, blocks.md, the posting, the score 
record (especially matched_skills with their evidence_project), and 
the company enrichment.
blocks.md holds my reusable paragraphs, each tagged by theme. The 
model SELECTS applicable blocks and writes only the job-specific 
paragraphs around them — it does not rewrite my blocks.
Structure: hook referencing something concrete about the company, 
one paragraph mapping their stated requirements to a specific 
project of mine, one paragraph on why this role and this company, 
close.
Hard rules for the generation prompt:
  - Every claim must trace to profile.md or blocks.md.
  - Every company reference must trace to an enrichment fact with a 
    source URL.
  - No superlatives about the company, no filler enthusiasm.
  - Target length configurable, default ~250 words.
  - German by default; English if the posting is in English.
Output goes to the letters table with status draft, plus the list of 
sources it drew on so the UI can display them.
`radar draft <job_id>` and `radar draft --top 10`.

EXPORT
weasyprint renders letter + CV to PDF from a Jinja/HTML template in 
templates/. Simplest working approach — no custom PDF layout code.
Filenames: {date}_{company}_{role}.pdf

═══════════════════════════════════════════════════════════════
PHASE 5 — REVIEW UI
═══════════════════════════════════════════════════════════════
FastAPI + Jinja2 + plain HTML. Deliberately rudimentary — server-
rendered, minimal CSS, no build step, no frontend framework.
Bind to 127.0.0.1 only. Never expose externally. No auth needed 
because it is local-only; make that a comment in the code.

Views:
  /            queue, sorted by score, with filter controls
  /job/{id}    posting, score breakdown, matched skills with their 
               evidence projects, red flags, company enrichment with 
               source links, generated letter
  Letter editor: plain textarea, save revisions, regenerate with a 
               free-text instruction ("kürzer", "weniger formell")
  Actions:     mark reviewed → export PDF → open the apply URL in a 
               new browser tab
  /companies   registry, ATS status, manual add
  /sources     health dashboard

The UI must NEVER submit an application. The final action is opening 
the employer's page in my browser so I do it myself. Put that 
sentence in the code as a comment where the action is handled.

Track per job: status (new | scored | drafted | reviewed | applied | 
rejected | interview), applied_at, and free-text notes.

═══════════════════════════════════════════════════════════════
DELIVERABLES PER PHASE
═══════════════════════════════════════════════════════════════
Working code, passing tests, updated README, updated CLAUDE.md, 
git commit tagged phase-N, and a short report: what works, what is 
stubbed, what you need from me. Then stop.

Begin with Phase 0 now. Write PLAN.md and wait.
