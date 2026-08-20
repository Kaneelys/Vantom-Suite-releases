# CLAUDE.md — radar

## Purpose

A personal job-search pipeline for a single user, run locally on one machine.
It aggregates postings from documented APIs, public ATS feeds, RSS/Atom and
job-alert emails; deduplicates them; scores them against `profile.md`;
researches the company; and drafts a cover letter in the user's own writing
voice. The user reviews everything in a local web UI and **submits every
application themselves**.

Context: German/DACH market. Student seeking Werkstudent roles (secondarily
part-time, entry-level full-time). Base Marburg, Hessen. Remote strongly
preferred; hybrid acceptable in Rhein-Main at max 2 office days per week.
Profile: generalist who independently ships digital products.

Full brief: [SPEC.md](SPEC.md). Design: [PLAN.md](PLAN.md).

## Absolute constraints

These are never relaxed, in any phase, for any reason.

1. **No submission.** No browser automation, no form filling, no code that
   sends an application anywhere. The pipeline stops at "reviewed and ready".
   The final action is opening the employer's page in the user's browser.
2. **No HTML scraping of job boards.** Permitted inputs only: documented
   APIs, public ATS feeds, RSS/Atom, and emails delivered to the user's own
   mailbox.
3. **No credentials in code or config.** Environment variables only, every
   one documented in `.env.example`.
4. **No fabricated claims.** Generated cover letters may assert only facts
   present in `profile.md` (or `blocks.md`, which the user wrote). No invented
   experience, no inflated claims, no manufactured enthusiasm. Unmet
   requirements are addressed honestly or omitted. Company references must
   trace to an enrichment fact with a source URL.
5. **Every network call** has an explicit timeout and an explicit error path.
   No bare `except:`.

## Stack

Python 3.11+, `uv` for dependencies. SQLite via stdlib `sqlite3`, no ORM.
`httpx`, `click`, `pydantic`, `feedparser`, `rapidfuzz`, `imaplib` +
`BeautifulSoup` (email bodies only), `anthropic` SDK. Phase 5 adds `FastAPI` +
`Jinja2`; Phase 4 adds `weasyprint`. Keep dependencies minimal; prefer stdlib.

## Conventions

- **Config over constants.** Every tunable lives in `config.toml`. No magic
  numbers in code — thresholds, timeouts, batch sizes, token lists, weights,
  priorities all come from config.
- **Layering.** `sources/*` never imports `store/*`. Adapters return `RawJob`
  and nothing else; the runner normalises, dedups, excludes and persists.
- **Uniform source interface.** `fetch(params) -> list[RawJob]`. Adapters are
  declared in `config.toml` and resolved dynamically, restricted to the
  `radar.sources.` import prefix.
- **Source isolation.** One failing source never aborts a run. Failures are
  caught, logged, counted against that source in `source_health`, and the run
  continues. Auto-disable after N consecutive failures.
- **Time.** All timestamps stored as ISO-8601 UTC strings. Booleans as 0/1.
- **Migrations.** Numbered `.sql` files under `radar/store/migrations/`,
  tracked in `schema_migrations`. Never edit an applied migration; add a new
  one. The database is never recreated to apply a change.
- **Nothing is deleted.** Excluded jobs keep an `excluded` flag and a reason
  so the rules can be tuned. `scores` and `letters` are append-only histories.
- **LLM output is untrusted input.** Prompts demand JSON only; parsing is
  defensive with one retry, and a second failure is recorded, not raised.
  Every score row stores its `model` and `prompt_version`.
- **Tests never hit the network.** Fixtures only, enforced by an autouse
  fixture that fails any real connection attempt.
- **Local only.** The Phase 5 UI binds to 127.0.0.1 and is never exposed.

## Commands

```
uv run radar config-check      # validate config + resolve every source
uv run radar scan              # fetch, normalise, dedup, exclude, persist
uv run radar score             # prefilter + detailed scoring
uv run radar list [--min-score --max-age --student-only --remote-only --excluded]
uv run radar show <id>
uv run radar sources           # per-source health
uv run pytest                  # test suite
```

## Phase discipline

Six phases (0-5), built one at a time, each stopping for the user's approval.
After every phase: run tests, append to **Decisions** below, commit, tag
`phase-N`, report what was built and what was deliberately left out, then stop.

## Decisions

<!-- Append one dated entry per phase: what was decided, and why. -->

