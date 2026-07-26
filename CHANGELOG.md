# Changelog

All notable changes to the reusable workflows in this repository.

Pre-1.0 SemVer, per the fleet dependency policy: **patch = compatible fix,
minor = breaking or behaviour change**.

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
