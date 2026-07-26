# plugin-runtime

Reusable GitHub Actions workflows for the Codenzia Filament / Laravel package
suite. Mirrors the `deploy-runtime` pattern — one source of truth, every
plugin repo invokes the workflows via `uses:`.

Two reusable workflows live here:

| Workflow | Trigger in caller | Purpose |
|---|---|---|
| [`plugin-tests.yml`](.github/workflows/plugin-tests.yml) | `push` to `main` + `pull_request` | Matrix Pest tests (Laravel 12/13 × Filament 4/5 for Filament plugins; Laravel 12/13 for pure-Laravel plugins) + `pint --test`. Laravel 11 was dropped from the default matrix on 2026-05-20 — no Codenzia app or plugin still runs on it. |
| [`plugin-release.yml`](.github/workflows/plugin-release.yml) | `push` of a `v*` tag | Force-pushes the tagged commit + tag from the `-dev` repo to the public mirror, then creates a GitHub Release on the public repo. Packagist auto-detects via its webhook. |
| [`check-dependencies.yml`](.github/workflows/check-dependencies.yml) | `push` / `pull_request` (via `uses:`) | Runs the central in-house dependency-policy checker (§7 of the fleet dependency plan) in **Enforce** mode against the calling repo. Fails CI on unsafe `codenzia/*` constraints, non-stable app `minimum-stability`, committed local overlays, and tracked `auth.json`. |

## Caller examples

### Filament plugin (`filament-panel-base-dev/.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
concurrency:
  group: tests-${{ github.ref }}
  cancel-in-progress: true
jobs:
  tests:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-tests.yml@v1.2.0
    secrets: inherit
```

### Pure-Laravel plugin (`browser-console-dev/.github/workflows/tests.yml`)

```yaml
name: tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
concurrency:
  group: tests-${{ github.ref }}
  cancel-in-progress: true
jobs:
  tests:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-tests.yml@v1.2.0
    with:
      pure_laravel: true
    secrets: inherit
```

> `secrets: inherit` is **required** on `plugin-tests.yml` callers. Composer
> resolves in-house `codenzia/*` packages from the private Satis registry at
> `packages.codenzia.com`; without the credentials every install dies with
> `HTTP 401 … You must be using the interactive console to authenticate`.

### Release (`filament-panel-base-dev/.github/workflows/release.yml`)

```yaml
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-release.yml@main
    with:
      public_repo: Codenzia/filament-panel-base
    secrets: inherit
```

### Release for plugins without a `-dev` mirror (e.g. `laravel-superadmin`)

```yaml
name: release
on:
  push:
    tags: ['v*']
jobs:
  release:
    uses: Codenzia/plugin-runtime/.github/workflows/plugin-release.yml@main
    # public_repo omitted → workflow creates the release on the current repo
    secrets: inherit
```

## Secrets

All of these are **repo-level** secrets — org-level secrets don't propagate to
private repos on the GitHub Free plan.

- `CODENZIA_PAT` — classic personal access token with `repo` scope. Used to
  force-push to the public mirror, to create the GitHub Release on the public
  repo, and as Composer's `github-oauth` token for private package sources.
- `SATIS_USER` / `SATIS_PASS` — HTTP basic credentials for the private Satis
  registry `packages.codenzia.com`. Required by `plugin-tests.yml` on every
  package that depends on another `codenzia/*` package.

## Release flow end-to-end

1. Land changes on `main` of `Codenzia/<plugin>-dev`. Tests run automatically.
2. Bump version in `composer.json` (and update `CHANGELOG.md`).
3. Tag and push:
   ```bash
   git tag -a v1.2.0 -m "Release v1.2.0"
   git push origin v1.2.0
   ```
4. The release workflow fires:
   - Re-validates that the tag is semver-shaped (`v1.2.0`, `v1.2.0-beta.1`, etc.).
   - Pushes `HEAD` and the tag to `Codenzia/<plugin>` (the public mirror).
   - Creates a GitHub Release on the public repo, with notes extracted from
     the matching `CHANGELOG.md` section.
5. Packagist's webhook (configured once on Packagist when the public repo
   was submitted) detects the new tag and publishes it. End users can now
   `composer require codenzia/<plugin>:^1.2`.

## One-time per plugin

- **Submit to Packagist**: log in at packagist.org → Submit → paste the
  **public** repo URL. After submission, Packagist auto-syncs on every push.
- **Add `CODENZIA_PAT` secret** to the `-dev` repo: GitHub → Settings →
  Secrets and variables → Actions → New repository secret.
- **Drop the two caller workflow files** (`.github/workflows/tests.yml` and
  `.github/workflows/release.yml`) into the `-dev` repo.

## Dependency-policy enforcement (`check-dependencies.yml`)

The [`scripts/check-inhouse-dependencies.ps1`](scripts/check-inhouse-dependencies.ps1)
checker implements §7 of the approved Codenzia fleet dependency plan. It lives here
**centrally** — one source of truth for ~30 repos — and every app repo calls it through
the `check-dependencies.yml` reusable workflow, pinned by an **immutable tag** (never
`@main`, which would let the rules drift under consumers).

### What it rejects

Scanning every committed `composer.json` under `-Root`, it flags:

- unsafe `codenzia/*` constraints: `@dev`, `*@dev`, `dev-main`, `dev-master`,
  `0.x-dev` (and other `*-dev` branch aliases), bare `*`, unbounded ranges
  (`>=x` with no upper bound), dev/branch fallbacks after `||`, and commit-hash refs;
- application manifests (`type: "project"` or requiring `laravel/framework`) whose
  `minimum-stability` is not `stable`;
- a git-tracked `composer.local.json` (local overlays must stay gitignored);
- a committed `path`-type repository overlay inside a tracked `composer.json`;
- a git-tracked `auth.json` (Satis credentials must never be committed).

It ignores `vendor`, `node_modules`, `_archive`, `old-ignored`, `zipped files`,
`_pre-fold-backup-*`, `dist`, `.build`, and `studio/demo-fleet`. Tracked-ness is
resolved with `git ls-files`, so it works across nested repos.

### Local usage (Windows + Herd → run via PowerShell)

```powershell
# Fleet survey — report everything, never fail:
./scripts/check-inhouse-dependencies.ps1 -Root C:\mh2\Projects\Codenzia\GitHub -Mode Audit

# Single-repo gate — exit 1 on any violation:
./scripts/check-inhouse-dependencies.ps1 -Root . -Mode Enforce

# Tolerate a documented backlog while migrating wave-by-wave:
./scripts/check-inhouse-dependencies.ps1 -Root . -Mode Enforce -Baseline .dep-baseline.json

# Also write the machine-readable report to a file:
./scripts/check-inhouse-dependencies.ps1 -Root . -Mode Audit -JsonReport report.json
```

Output is both a human-readable table (with a rule-level summary) and a machine-readable
JSON block (`file`, `dependency`, `constraint`, `rule`, `baselined`). A `-Baseline` JSON
file is an array of tolerated-violation objects; any of `file` / `dependency` /
`constraint` / `rule` present in an entry must match (absent fields are wildcards). Remove
a repo's baseline entries once it is fully migrated.

### CI usage (required §7 step — pin by immutable tag)

Add a `dependencies` job to the app repo's CI, pinned to a released tag:

```yaml
jobs:
  dependencies:
    uses: Codenzia/plugin-runtime/.github/workflows/check-dependencies.yml@v1.0.0
    secrets: inherit
```

Pass `secrets: inherit` so the workflow can read this private repo (via `CODENZIA_PAT`)
to fetch the checker at the exact commit of the tag you pinned. Optional inputs: `root`
(default `.`), `baseline` (path to a tolerated-violations file), `runs_on`
(default `ubuntu-latest`).

**Always pin `@v1.0.0` (or a later immutable tag), never `@main`.** The tag guarantees the
policy a consumer enforces is frozen — the whole point of §7 is to stop the fleet depending
on mutable branches. If a `raw` local step is preferred instead of the reusable workflow:

```yaml
- name: Enforce stable Codenzia dependencies
  shell: pwsh
  run: ./scripts/check-inhouse-dependencies.ps1 -Root . -Mode Enforce
```

## Customization

Both reusable workflows accept inputs (PHP extensions, branch name, whether
to run Pint, etc.) — see the `inputs:` blocks at the top of each workflow
file for the full list. Defaults match the Codenzia plugin conventions
(PHP 8.3, Laravel 12/13, Filament 4/5, Pest, Pint).
