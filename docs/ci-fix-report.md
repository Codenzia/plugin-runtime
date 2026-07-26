# Fleet CI fix — `plugin-tests.yml` (2026-07-26)

Executes item **#1** of [`fleet-ci-minutes-audit.md`](../../fleet-ci-minutes-audit.md):
the reusable plugin test workflow was both **broken** (100% failure across ~11
package repos for a month) and **wasteful** (63% of its billed minutes were
scaffolding jobs).

---

## 1. Verified root cause

The audit's diagnosis was confirmed against a real failing run before anything
was changed.

**Evidence — `Codenzia/filament-panel-base-dev` run `30006309967`** (push to
`main`, 2026-07-23, `tests / L12.* F4.* PHP8.3`):

```
2026-07-23T12:16:31.7270716Z ##[error]The 'https://packages.codenzia.com/packages.json'
                             URL required authentication (HTTP 401).
                             You must be using the interactive console to authenticate
2026-07-23T12:16:31.7360534Z ##[error]Process completed with exit code 100.
```

`plugin-tests.yml@v1.1.0` never set `COMPOSER_AUTH` anywhere and its
`workflow_call` block declared **no `secrets:` at all**, so no caller could pass
credentials even if it wanted to. Every package that resolves an in-house
`codenzia/*` dependency (or otherwise touches the private Satis registry) died
at `composer update` in ~30 seconds, before a single test ran.

The same run's `tests / Pint` job failed independently on 4 real style
violations:

```
2026-07-23T12:16:24.8990884Z  FAIL  ...... 261 files, 4 style issues
```

**Which secret already existed.** Surveying working fleet workflows
(`aqarkom/ci.yml`, `asset-flow/tests.yml`, `dari-platform/ci.yml`,
`task-off-workspace/ci.yml`) the established convention is repo-level
`SATIS_USER` / `SATIS_PASS` for `http-basic` against `packages.codenzia.com`,
plus `CODENZIA_PAT` for `github-oauth`. Org-level secrets do not propagate on
the GitHub Free plan. Every `-dev` package repo already had `CODENZIA_PAT` but
**none had `SATIS_USER` / `SATIS_PASS`** — they were never added because the
reusable workflow never asked for them.

**Yes, the reusable workflow needed a `secrets:` input.** It now declares
`CODENZIA_PAT`, `SATIS_USER`, `SATIS_PASS` (all `required: false`), and callers
must pass `secrets: inherit`. That is a caller-visible behaviour change, hence
the **minor** version bump.

---

## 2. What changed

### `plugin-runtime/.github/workflows/plugin-tests.yml`

| Change | Why |
|---|---|
| `workflow_call.secrets` declares `CODENZIA_PAT` / `SATIS_USER` / `SATIS_PASS` | the actual bug — no way to authenticate |
| New `Configure Composer authentication` step builds `COMPOSER_AUTH` with `jq` | each block emitted **only when its secrets are non-empty** (see v1.2.1 note below) |
| `matrix` job **deleted**; include list built inline in `strategy.matrix` from `inputs.*` | a whole runner existed to `echo` a JSON string — 154 jobs / 154 billed min in July |
| `pint` job **deleted**; `pint --test` is now a step gated on `inputs.pint && matrix.pint` | 154 more jobs for ~6 s of work each |
| `pint: true` marker added to exactly one entry of every matrix variant | guarantees the style check runs exactly once per run, in every input combination — including `skip_filament_v4: true`, where no `12.* + F4` leg exists |
| Both-`skip_filament_*`-true guard moved into a first *step* of the test job | preserves the original error and exit 1 without a dedicated job |
| `tools: composer:v2, pint` on `setup-php` | pint is now needed on the test runner |

**Nothing about what the tests assert was changed, weakened, or skipped.** No
check was disabled and no blanket ignore was added.

### `v1.2.1` — a real bug found in `v1.2.0` before rollout

`v1.2.0` interpolated the secrets directly, so a consumer with no
`CODENZIA_PAT` got `{"github-oauth":{"github.com":""}}`. That is **worse than
omitting it** — Composer then sends empty credentials to github.com instead of
falling back to anonymous access. Five consumers are in exactly that state
(`filament-dam`, `filament-release-tracker`, `laravel-ai-assistant`,
`laravel-ai-translations`, `laravel-superadmin`). Fixed by assembling the JSON
conditionally with `jq`. **Consumers are pinned to `v1.2.1`; `v1.2.0` should not
be used.**

### Code fixes (not workflow changes)

Once CI could actually run, three genuine defects surfaced and were fixed in
code rather than silenced:

| Repo | Defect | Fix |
|---|---|---|
| `filament-panel-base-dev` | 4 Pint violations (`ReadsAnalyticsFilters`, `ThrottleAuth`, `ScaffoldValidationLangCommand`, `DetectNewDeviceLoginTest`) | `pint` — style only |
| `filament-panel-base-dev` | 7 × `PropertyNotFoundException: Property [$actions] not found` in `CommandPaletteSearchTest`. Under **Livewire 3** (the L12+F4 leg) reading a `#[Computed]` property on a component that was never booted throws; under Livewire 4 (the local dev lockfile) it does not — which is why it passed locally and had never once run in CI | `CommandPalette::getGroupedActionsProperty()` calls `$this->actions()` directly, and the tests call `->actions()`. `render()` is the only reader per request so the memoisation was buying nothing — behaviourally identical on Livewire 3 and 4. **Every assertion is unchanged.** |
| `browser-console-dev`, `filament-comments-dev`, `filament-system-tools-dev`, `laravel-ai-assistant` | 2 Pint violations each (incl. one genuinely unused closure `use` import in `ManageDirectMessagesPage`) | `pint` — style only |

### Secrets added

`SATIS_USER` / `SATIS_PASS` were added to the two repos that actually resolve an
in-house dependency from Satis: `filament-panel-base-dev` (`codenzia/laravel-sms`)
and `filament-dam` (`codenzia/filament-media`). The other consumers declare no
`codenzia/*` requirement, and the conditional `COMPOSER_AUTH` means their absent
secrets are simply omitted.

---

## 3. Validation on one consumer before rollout

`filament-panel-base-dev` was used as the validation consumer (22/22 failing in
July — the clearest signal). Three iterations, all on a PR branch so `main` was
never touched with an unproven workflow:

| # | Run | Result | Finding |
|---|---|---|---|
| 1 | [`30188086624`](https://github.com/Codenzia/filament-panel-base-dev/actions/runs/30188086624) | `failure` | **Composer auth fixed** — 483 passed / 7 failed. The matrix reached the test suite for the first time in a month. The 7 failures were the genuine Livewire-3 computed-property defect. |
| 2 | [`30188168417`](https://github.com/Codenzia/filament-panel-base-dev/actions/runs/30188168417) | **`success`** | after the `CommandPalette` fix. (First attempt hit `curl error 28 … packages.codenzia.com … Timeout`, a transient network failure; the re-run of that same job was green.) |
| 3 | [`30188309856`](https://github.com/Codenzia/filament-panel-base-dev/actions/runs/30188309856) | **`success`** | re-validation after the conditional-`COMPOSER_AUTH` change that became v1.2.1. |

```
run 30188309856  conclusion=success  jobs=[{"name":"tests / L12.* F4.* PHP8.3","conclusion":"success"}]
```

One job, where `v1.1.0` produced three (`matrix` + `tests` + `pint`).

**Only after run `30188309856` was green were the tags cut.**

---

## 4. Tags cut

- `v1.2.0` — annotated, `d33ee64^`. Fixes `COMPOSER_AUTH`, collapses the
  `matrix` and `pint` jobs. **Superseded — do not pin.**
- `v1.2.1` — annotated, `d33ee64`. Conditional `COMPOSER_AUTH` construction.
  **This is the tag every consumer is pinned to.**

Minor bump per the fleet convention in `CLAUDE.md`: requiring `secrets: inherit`
is a caller-visible behaviour change. `v1.2.1` is a patch on top: compatible fix,
no interface change.

---

## 5. Consumers bumped

All **16** `plugin-tests.yml` callers were moved `@v1.1.0 → @v1.2.1`, each also
gaining `secrets: inherit` and a `concurrency` group. Every one is green on its
default branch:

| Repo | Run | Result |
|---|---|---|
| `browser-console-dev` | `30188470556` | success |
| `filament-carousel-dev` | `30188376229` | success |
| `filament-comments-dev` | `30188471525` | success |
| `filament-dam` | `30188378629` | success |
| `filament-diagrammer-dev` | `30188379749` | success |
| `filament-gantt-lite-dev` | `30188380676` | success |
| `filament-media-dev` | `30188381658` | success |
| `filament-panel-base-dev` | `30188382803` | success |
| `filament-release-tracker` | `30188383684` | success |
| `filament-system-tools-dev` | `30188472326` | success |
| `filament-workflow-dev` | `30188385753` | success |
| `laravel-ai-assistant` | `30188473137` | success |
| `laravel-ai-translations` | `30188387548` | success |
| `laravel-feedback-dev` | `30188388616` | success |
| `laravel-superadmin` | `30188389561` | success |
| `project-essentials-dev` | `30188390635` | success |

The **5 `plugin-release.yml` callers were deliberately left at `@v1.1.0`** —
that workflow is byte-identical in `v1.2.1`, so bumping them would be churn with
no effect and would burn minutes re-verifying nothing.

---

## 6. Measured before / after

Measured from the GitHub jobs API, billed the way GitHub bills
(`ceil(job_seconds / 60)` per job, Linux 1×), comparing each repo's last
pre-fix run on `main` against its post-fix run:

| | Jobs per full fleet pass | Billed min per full fleet pass |
|---|---:|---:|
| **Before** (`@v1.1.0`) | 60 | 58 |
| **After** (`@v1.2.1`) | 28 | 28 |
| **Change** | **−53%** | **−52%** |

Extrapolated to July's measured volume for this workflow (584 jobs / 584 billed
minutes): **~273 jobs / ~273 billed minutes**, i.e. **~311 billed minutes/month
recovered** — consistent with the audit's ~300 estimate.

Worth stating plainly: the *after* number is for runs that **actually execute
the full test suite and pass**, while most *before* runs died in ~30 seconds.
The audit warned that fixing correctness would cost 150–250 min/month. It did
not, because removing two scaffolding jobs per run more than paid for the longer
green runs.

---

## 7. Still outstanding

Nothing in the 16 test consumers is red. Outside this fix's scope:

- **Transient Satis reachability.** One run failed with
  `curl error 28 … Failed to connect to packages.codenzia.com port 443 after
  10006 ms`. A re-run was clean, but `packages.codenzia.com` (Hostinger shared
  hosting) is now a single point of failure for 16 repos' CI. Worth a retry
  wrapper around `composer update`, or a `--prefer-dist` fallback.
- **Satis credentials are still per-repo.** Two repos have them; any future
  in-house dependency in another package will fail with the same 401 until
  `SATIS_USER` / `SATIS_PASS` are added there. Org secrets would solve this but
  are unavailable on the Free plan.
- **`plugin-release.yml` has the same latent gap** — it does not set
  `COMPOSER_AUTH` either. It currently does no `composer install`, so it is not
  broken today, but adding one would reproduce this bug.
- **Audit items 2–11 are untouched** — notably `dari-mobile` Gradle caching
  (~200 min/mo) and the `dari-platform` CI job merge (~180 min/mo), the next two
  largest wins.
- **`dari-platform`'s PHPStan `?->` error and `serveeta`'s `InMemoryProvisioner`
  class-name mismatch** (audit §3.4) are in repos that do not consume
  `plugin-tests.yml` and were left alone.
