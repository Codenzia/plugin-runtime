# Changelog

All notable changes to the reusable workflows in this repository.

Pre-1.0 SemVer, per the fleet dependency policy: **patch = compatible fix,
minor = breaking or behaviour change**.

## v1.5.0 — 2026-09-24

### Changed

- **The `mysql` leg applies the migrations; it no longer re-runs the Pest
  suite.** v1.4.0 also exported `DB_CONNECTION=mysql` to `vendor/bin/pest`. That
  is not portable across the fleet's test bootstraps: several packages build
  their own schema inside a `beforeEach` — `Schema::create('users', …)` with no
  matching drop — because Testbench hands every test a fresh `:memory:` SQLite
  database. One persistent MySQL database has no equivalent, so the second test
  dies on `SQLSTATE[42S01]: Base table or view already exists: 1050 Table
  'users' already exists`, which says nothing about the package.
  `codenzia/filament-comments` went red on exactly that: 240 failures, its
  migrations green. Making a suite connection-agnostic is per-package work, so
  the shared workflow stops pretending otherwise.

  The leg still does the thing it was added for — real MySQL DDL, with the
  SQLSTATE as the job's failure. `database: mysql` callers need no edit beyond
  the ref.

## v1.4.0 — 2026-09-24

### Added

- **`plugin-tests.yml` — a `database` input (`sqlite` | `mysql`, default
  `sqlite`).** `mysql` adds ONE job — not a matrix dimension, Actions bills per
  job — that brings up a `mysql:8` service, applies the package's migrations to
  it for real, and then runs the suite with `DB_CONNECTION=mysql`. The SQLite
  legs are untouched, so every existing caller behaves exactly as before.

  SQLite ignores `->after()`, accepts a foreign key to a table that does not
  exist and swallows several column changes MySQL rejects. A package migration
  can therefore be broken for every MySQL install while CI stays green — which
  is what happened: `codenzia/filament-dam` shipped
  `$table->foreignId('content_type_id')->after('type')` against a `media_files`
  table with no `type` column, and every MySQL `migrate:fresh` of the package
  died on `SQLSTATE[42S22]: Column not found: 1054 Unknown column 'type' in
  'media_files'` for months.

  The MySQL job migrates in install order: a minimal host `users` table (the
  Testbench skeleton ships no migrations, and MySQL — unlike SQLite — refuses a
  foreign key to a table that does not exist yet), then each
  `vendor/codenzia/*/database/migrations`, then the package's own. Same-named
  migrations are recorded once, so a file a package still ships under a
  dependency's filename is skipped here exactly as it would be in an app.

  Enable it on any package that ships `database/migrations`:

  ```yaml
  jobs:
    tests:
      uses: Codenzia/plugin-runtime/.github/workflows/plugin-tests.yml@v1.4.0
      with:
        database: mysql
      secrets: inherit
  ```

  Minor bump: a new input and a new job, no change to the existing interface.

## v1.3.0 — 2026-09-17

### Added

- **`plugin-tag.yml` — the "Cut release" button.** A `workflow_call` workflow
  that turns a `workflow_dispatch` (bump `patch|minor|major`, or an exact
  `version`) into an annotated `v*` tag on the chosen branch. It computes the
  next version from the caller repo's own latest tag, refuses an existing or
  non-increasing tag, and refuses unless the latest `tests.yml` run for that
  commit concluded `success` (skipped with a notice when the repo has no
  `tests.yml`; `require_green_tests: false` bypasses once). The tag is pushed
  with `CODENZIA_PAT`, not `GITHUB_TOKEN`, because a token-pushed tag never
  triggers the repo's tag-triggered workflows — and those (`release.yml`,
  `satis-on-tag.yml`) are what publish to Satis and Packagist. Minor bump
  because it is a new workflow, not a change to an existing one.

## v1.2.2 — 2026-07-26

### Fixed

- **`composer update` is now retried on transient transport failures.** Since
  v1.2.1 every one of the 16 consumers resolves through
  `packages.codenzia.com`, making it a single point of failure for the whole
  fleet's CI; a run during the v1.2.1 rollout died on `curl error 28 … Failed
  to connect to packages.codenzia.com port 443 after 10006 ms` and was green on
  re-run. Up to 3 attempts with 15s / 30s backoff.

  Composer has no setting that covers this: `process-timeout` bounds a running
  process rather than a TCP connect, `retry-auth-failure` only controls
  re-prompting for credentials, and Composer's internal retries apply to
  individual package downloads, not to the repository metadata fetch whose
  failure aborts the whole resolution.

  **Genuine failures are not retried.** If the output matches an
  authentication error (`HTTP 401/403/404`, `URL required authentication`,
  `interactive console to authenticate`, `{"message":"Not Found"}`) or a
  resolution error (`Your requirements could not be resolved`, `could not be
  found in any version`), the step fails immediately on the first attempt. A
  returning `COMPOSER_AUTH` regression — the bug v1.2.0 fixed — must stay loud,
  and retrying it would triple the billed minutes for a failure that cannot
  succeed.

No caller-visible interface change; `@v1.2.1` callers can move to `@v1.2.2`
with no edit beyond the ref.

## v1.2.1 — 2026-07-26

### Fixed

- `COMPOSER_AUTH` is now assembled with `jq` and includes each block only when
  its secrets are non-empty. v1.2.0 always emitted
  `{"github-oauth":{"github.com":""}}`, which is worse than omitting it — on the
  consumers that have no `CODENZIA_PAT` (`filament-dam`,
  `filament-release-tracker`, `laravel-ai-assistant`, `laravel-ai-translations`,
  `laravel-superadmin`) Composer would send empty credentials to github.com
  instead of falling back to anonymous access.

**Consumers should pin `@v1.2.1`, not `@v1.2.0`.**

## v1.2.0 — 2026-07-26

### Fixed

- **`plugin-tests.yml` never set `COMPOSER_AUTH`.** Every consumer that depends
  on another in-house `codenzia/*` package failed at `composer update` with
  `The 'https://packages.codenzia.com/packages.json' URL required
  authentication (HTTP 401) … You must be using the interactive console to
  authenticate`. This made the reusable test matrix red 100% of the time on
  ~11 package repos for a month. The test job now exports `COMPOSER_AUTH` built
  from `CODENZIA_PAT` (github-oauth) and `SATIS_USER` / `SATIS_PASS`
  (http-basic for `packages.codenzia.com`).

### Changed (breaking for callers)

- **Callers must now pass `secrets: inherit`.** `workflow_call` declares
  `CODENZIA_PAT`, `SATIS_USER` and `SATIS_PASS` (all optional, so a package
  with no in-house dependencies still works). Without `secrets: inherit` the
  credentials resolve empty and the pre-existing 401 persists.
- The dedicated `matrix` job was **removed**; the include list is now built
  inline in `strategy.matrix` from `inputs.*`. It existed only to `echo` a JSON
  string and cost a full billed minute per run on all 16 consumers.
- The dedicated `pint` job was **removed**; `pint --test` is now a step of the
  single matrix leg flagged `pint: true`. `inputs.pint` still gates it, so the
  caller-facing switch is unchanged.
- The "both `skip_filament_v4` and `skip_filament_v5` are true" guard moved
  from the deleted `matrix` job into a first step of the test job; the error
  message and failure behaviour are unchanged.

Net effect per run: **5 jobs → 3** (2 with `skip_filament_v5`), roughly 300
billed minutes/month recovered across the fleet, and — more importantly — the
matrix actually produces a test result instead of dying in 30 seconds.

## v1.1.0

- `plugin-release.yml`: include the Composer package name in the Satis dispatch
  payload; `persist-credentials: false` so the mirror push uses `CODENZIA_PAT`.
- `check-dependencies.yml`: central in-house dependency-policy checker.
- `plugin-tests.yml`: `skip_filament_v4` / `skip_filament_v5` inputs; ignore the
  Filament v5 beta advisory `PKSA-5bdf-2x61-v43c`.

## v1.0.0

- Initial `plugin-tests.yml` and `plugin-release.yml` reusable workflows.
